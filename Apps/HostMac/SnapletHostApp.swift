import SwiftUI

@main
struct SnapletHostApp: App {
    var body: some Scene {
        WindowGroup {
            HostDashboardView()
        }
        .defaultSize(width: 1280, height: 820)
    }
}
