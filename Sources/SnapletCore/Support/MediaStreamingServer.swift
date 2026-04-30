import Darwin
import Foundation
import Network

public final class MediaStreamingServer: @unchecked Sendable {
    private struct RegisteredResource: Sendable {
        let fileURL: URL
        let contentType: String
        let byteSize: Int64
        var lastAccessedAt: Date
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
    }

    private let stateQueue = DispatchQueue(label: "snaplet.streaming.server.state")
    private let networkQueue = DispatchQueue(
        label: "snaplet.streaming.server.network",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let maxRegisteredResourceCount = 512
    private let resourceTTL: TimeInterval = 20 * 60

    private var listener: NWListener?
    private var baseURL: URL?
    private var resources: [String: RegisteredResource] = [:]

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        stateQueue.sync {
            guard listener == nil else { return }

            do {
                let listener = try NWListener(using: .tcp, on: .any)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    self.handleListenerStateUpdate(state, listener: listener)
                }
                self.listener = listener
                listener.start(queue: networkQueue)
            } catch {
                self.listener = nil
                self.baseURL = nil
            }
        }
    }

    public func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
            baseURL = nil
            resources.removeAll()
        }
    }

    public func registerResource(at fileURL: URL, byteSize: Int64) -> URL? {
        stateQueue.sync {
            pruneRegisteredResourcesLocked()

            guard let baseURL else {
                return nil
            }

            let token = UUID().uuidString
            resources[token] = RegisteredResource(
                fileURL: fileURL,
                contentType: MediaType.mimeType(for: fileURL),
                byteSize: byteSize,
                lastAccessedAt: Date()
            )
            return baseURL.appendingPathComponent(token, isDirectory: false)
        }
    }

    public func registerVideo(at fileURL: URL, byteSize: Int64) -> URL? {
        registerResource(at: fileURL, byteSize: byteSize)
    }

    private func handleListenerStateUpdate(_ state: NWListener.State, listener: NWListener) {
        stateQueue.async {
            switch state {
            case .ready:
                guard let port = listener.port else {
                    self.baseURL = nil
                    return
                }
                self.baseURL = Self.makeBaseURL(for: port)
            case .failed, .cancelled:
                self.baseURL = nil
                self.listener = nil
            default:
                break
            }
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: networkQueue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                return
            }

            var requestData = accumulated
            if let data {
                requestData.append(data)
            }

            if let headerRange = requestData.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = requestData[..<headerRange.lowerBound]
                guard let request = Self.parseRequest(Data(headerData)) else {
                    self.sendStatus(.badRequest, on: connection)
                    return
                }
                self.respond(to: request, on: connection)
                return
            }

            if isComplete || requestData.count >= 128 * 1024 {
                self.sendStatus(.badRequest, on: connection)
                return
            }

            self.receiveRequest(on: connection, accumulated: requestData)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        let normalizedMethod = request.method.uppercased()
        guard normalizedMethod == "GET" || normalizedMethod == "HEAD" else {
            sendStatus(.methodNotAllowed, on: connection, extraHeaders: ["Allow": "GET, HEAD"])
            return
        }

        let pathComponents = request.path
            .split(separator: "/")
            .map(String.init)
        guard pathComponents.count == 2, pathComponents[0] == "stream" else {
            sendStatus(.notFound, on: connection)
            return
        }

        let token = pathComponents[1]
        guard let resource = registeredResource(for: token) else {
            sendStatus(.notFound, on: connection)
            return
        }

        guard FileManager.default.fileExists(atPath: resource.fileURL.path) else {
            sendStatus(.notFound, on: connection)
            return
        }

        let fileSize = max(resource.byteSize, 0)
        guard let byteRange = Self.resolveByteRange(
            from: request.headers["range"],
            fileSize: fileSize
        ) else {
            sendStatus(
                .rangeNotSatisfiable,
                on: connection,
                extraHeaders: [
                    "Accept-Ranges": "bytes",
                    "Content-Range": "bytes */\(fileSize)"
                ]
            )
            return
        }

        let isPartialResponse = byteRange.lowerBound != 0 || byteRange.upperBound != fileSize
        let contentLength = byteRange.upperBound - byteRange.lowerBound
        var headers = [
            "Accept-Ranges": "bytes",
            "Cache-Control": "no-store",
            "Connection": "close",
            "Content-Length": "\(contentLength)",
            "Content-Type": resource.contentType
        ]

        if isPartialResponse {
            headers["Content-Range"] = "bytes \(byteRange.lowerBound)-\(byteRange.upperBound - 1)/\(fileSize)"
        }

        sendHeaders(
            status: isPartialResponse ? .partialContent : .ok,
            headers: headers,
            on: connection
        ) { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }

            guard normalizedMethod == "GET" else {
                connection.cancel()
                return
            }

            self.sendFileRange(
                at: resource.fileURL,
                byteRange: byteRange,
                on: connection
            )
        }
    }

    private func registeredResource(for token: String) -> RegisteredResource? {
        stateQueue.sync {
            guard var resource = resources[token] else {
                return nil
            }

            resource.lastAccessedAt = Date()
            resources[token] = resource
            return resource
        }
    }

    private func sendFileRange(at fileURL: URL, byteRange: Range<Int64>, on connection: NWConnection) {
        do {
            let fileHandle = try FileHandle(forReadingFrom: fileURL)
            try fileHandle.seek(toOffset: UInt64(byteRange.lowerBound))
            streamBytes(
                from: fileHandle,
                remainingByteCount: byteRange.upperBound - byteRange.lowerBound,
                on: connection
            )
        } catch {
            connection.cancel()
        }
    }

    private func streamBytes(
        from fileHandle: FileHandle,
        remainingByteCount: Int64,
        on connection: NWConnection
    ) {
        guard remainingByteCount > 0 else {
            try? fileHandle.close()
            connection.cancel()
            return
        }

        let nextChunkSize = min(Int(remainingByteCount), 256 * 1024)

        do {
            guard
                let chunk = try fileHandle.read(upToCount: nextChunkSize),
                chunk.isEmpty == false
            else {
                try? fileHandle.close()
                connection.cancel()
                return
            }

            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard self != nil else {
                    try? fileHandle.close()
                    connection.cancel()
                    return
                }

                if error != nil {
                    try? fileHandle.close()
                    connection.cancel()
                    return
                }

                self?.streamBytes(
                    from: fileHandle,
                    remainingByteCount: remainingByteCount - Int64(chunk.count),
                    on: connection
                )
            })
        } catch {
            try? fileHandle.close()
            connection.cancel()
        }
    }

    private func sendStatus(
        _ status: HTTPStatus,
        on connection: NWConnection,
        extraHeaders: [String: String] = [:]
    ) {
        var headers = [
            "Cache-Control": "no-store",
            "Connection": "close",
            "Content-Length": "0"
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }

        sendHeaders(status: status, headers: headers, on: connection) {
            connection.cancel()
        }
    }

    private func sendHeaders(
        status: HTTPStatus,
        headers: [String: String],
        on connection: NWConnection,
        completion: @escaping @Sendable () -> Void
    ) {
        let headerLines = headers
            .sorted { $0.key < $1.key }
            .map { "\($0): \($1)" }
            .joined(separator: "\r\n")
        let response = "HTTP/1.1 \(status.rawValue) \(status.reasonPhrase)\r\n\(headerLines)\r\n\r\n"
        let responseData = Data(response.utf8)

        connection.send(content: responseData, completion: .contentProcessed { error in
            if error != nil {
                connection.cancel()
                return
            }

            completion()
        })
    }

    private func pruneRegisteredResourcesLocked() {
        let expirationDate = Date().addingTimeInterval(-resourceTTL)
        resources = resources.filter { _, resource in
            resource.lastAccessedAt >= expirationDate
        }

        guard resources.count > maxRegisteredResourceCount else {
            return
        }

        let sortedTokens = resources
            .sorted { $0.value.lastAccessedAt < $1.value.lastAccessedAt }
            .map(\.key)
        let overflowCount = resources.count - maxRegisteredResourceCount

        for token in sortedTokens.prefix(overflowCount) {
            resources.removeValue(forKey: token)
        }
    }

    private static func parseRequest(_ data: Data) -> HTTPRequest? {
        guard let requestString = String(data: data, encoding: .utf8) else {
            return nil
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }

        let requestLineParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestLineParts.count >= 2 else {
            return nil
        }

        let method = String(requestLineParts[0])
        let path = String(requestLineParts[1])
        var headers: [String: String] = [:]

        for line in lines.dropFirst() where line.isEmpty == false {
            guard let separatorIndex = line.firstIndex(of: ":") else { continue }
            let headerName = line[..<separatorIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let headerValue = line[line.index(after: separatorIndex)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            headers[headerName] = headerValue
        }

        return HTTPRequest(method: method, path: path, headers: headers)
    }

    private static func resolveByteRange(from headerValue: String?, fileSize: Int64) -> Range<Int64>? {
        guard fileSize >= 0 else {
            return nil
        }

        guard let headerValue, headerValue.isEmpty == false else {
            return 0..<fileSize
        }

        guard headerValue.lowercased().hasPrefix("bytes=") else {
            return nil
        }

        let rawRange = headerValue.dropFirst("bytes=".count)
        let firstRange = rawRange.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: true).first
        guard let firstRange else {
            return nil
        }

        let components = firstRange.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2 else {
            return nil
        }

        let lowerComponent = String(components[0])
        let upperComponent = String(components[1])

        if lowerComponent.isEmpty {
            guard let suffixLength = Int64(upperComponent), suffixLength > 0 else {
                return nil
            }
            let clampedLength = min(suffixLength, fileSize)
            return (fileSize - clampedLength)..<fileSize
        }

        guard let lowerBound = Int64(lowerComponent), lowerBound >= 0, lowerBound < fileSize else {
            return nil
        }

        if upperComponent.isEmpty {
            return lowerBound..<fileSize
        }

        guard let upperBoundInclusive = Int64(upperComponent), upperBoundInclusive >= lowerBound else {
            return nil
        }

        let upperBoundExclusive = min(upperBoundInclusive + 1, fileSize)
        guard upperBoundExclusive > lowerBound else {
            return nil
        }

        return lowerBound..<upperBoundExclusive
    }

    private static func makeBaseURL(for port: NWEndpoint.Port) -> URL? {
        guard let host = preferredHostAddress() else {
            return nil
        }

        let portString = String(port.rawValue)
        let hostComponent = host.contains(":") ? "[\(host)]" : host
        return URL(string: "http://\(hostComponent):\(portString)/stream")
    }

    private static func preferredHostAddress() -> String? {
        var interfaceAddresses: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaceAddresses) == 0, let firstAddress = interfaceAddresses else {
            return nil
        }
        defer { freeifaddrs(interfaceAddresses) }

        struct Candidate {
            let score: Int
            let address: String
        }

        var candidates: [Candidate] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddress

        while let current = cursor {
            let interface = current.pointee
            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp, isRunning, !isLoopback, let addressPointer = interface.ifa_addr {
                let family = Int32(addressPointer.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let length = socklen_t(addressPointer.pointee.sa_len)

                    if getnameinfo(
                        addressPointer,
                        length,
                        &hostBuffer,
                        socklen_t(hostBuffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    ) == 0 {
                        let rawAddress = String(
                            decoding: hostBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                            as: UTF8.self
                        )
                        let normalizedAddress = rawAddress.split(separator: "%", maxSplits: 1).first.map(String.init) ?? rawAddress
                        let interfaceName = String(cString: interface.ifa_name)
                        let isWiFi = interfaceName == "en0"
                        let isIPv4 = family == AF_INET
                        let score = (isWiFi ? 100 : 0) + (isIPv4 ? 10 : 0)
                        candidates.append(Candidate(score: score, address: normalizedAddress))
                    }
                }
            }

            cursor = interface.ifa_next
        }

        return candidates
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.address < rhs.address
                }
                return lhs.score > rhs.score
            }
            .map(\.address)
            .first
    }
}

private enum HTTPStatus: Int {
    case ok = 200
    case partialContent = 206
    case badRequest = 400
    case notFound = 404
    case methodNotAllowed = 405
    case rangeNotSatisfiable = 416

    var reasonPhrase: String {
        switch self {
        case .ok:
            "OK"
        case .partialContent:
            "Partial Content"
        case .badRequest:
            "Bad Request"
        case .notFound:
            "Not Found"
        case .methodNotAllowed:
            "Method Not Allowed"
        case .rangeNotSatisfiable:
            "Range Not Satisfiable"
        }
    }
}
