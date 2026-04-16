# Snaplet

Snaplet is a native Swift setup with:

- A macOS host dashboard that imports images into an external-drive image store.
- A SQLite index that tracks every imported file.
- An iPhone viewer that requests a random indexed image every time you pull down.
- MultipeerConnectivity transport between the Mac and iPhone.

## Architecture

### Mac host

- Imported images are copied into `/Volumes/Seagate Expansion Drive/Snaplet/HostData/Images/`.
- Metadata is written into `/Volumes/Seagate Expansion Drive/Snaplet/HostData/snaplet.sqlite`.
- The host will not silently fall back to internal storage. If `Seagate Expansion Drive` is not mounted, the host dashboard shows a clear error and does not start the library service.
- The Mac advertises a local MultipeerConnectivity service.
- When the viewer requests the next image, the host runs `ORDER BY RANDOM() LIMIT 1` against SQLite and transfers that file back to the iPhone.

### iPhone viewer

- The viewer discovers the Mac host and connects automatically.
- On first connection, and on each downward swipe, it sends a `requestRandomImage` message.
- The transferred file is cached locally and rendered full-screen.

## Important transport note

This project uses `MultipeerConnectivity`, which is the most practical Apple-native option for Mac-to-iPhone direct sessions. Apple can still choose infrastructure Wi-Fi, peer-to-peer Wi-Fi, or Bluetooth as the underlying transport, so this is not a strict guarantee that your existing Wi-Fi network will never be used underneath the connection.

## Verification in this environment

- `swift build`
- `swift run SnapletSmokeTests`
- `xcrun swiftc -typecheck ... Apps/iOSViewer/*.swift`
- `xcodebuild -project Snaplet.xcodeproj -scheme SnapletHost -configuration Debug -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO`
- iOS Simulator run on `iPhone 17 Pro (iOS 26.4)` succeeded
- End-to-end simulator validation confirmed:
  - the viewer connected to the Mac host over `MultipeerConnectivity`
  - the host served a random image from SQLite-backed storage
  - the viewer cached the transferred file
  - SHA-256 hashes matched between the host copy and simulator cache copy, confirming lossless transfer

Physical iPhone installation is still blocked by Apple provisioning on this machine because Xcode could not log into the configured developer account to create a development profile.

## Generate the Xcode project

```bash
xcodegen generate
open Snaplet.xcodeproj
```

## What still needs Xcode

- Valid Apple Developer account credentials in Xcode for physical iPhone install/signing.
- Optional live validation of the iPhone photo-picker upload flow on a physical device.
