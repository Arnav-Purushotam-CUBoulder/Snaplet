# Snaplet

Snaplet is a native Swift setup with:

- A macOS host dashboard that imports photos and videos into an external-drive media store.
- A SQLite index that tracks every imported file.
- An iPhone viewer with random photo/video feeds, favorites feeds, and a separate video album tab.
- MultipeerConnectivity transport between the Mac and iPhone.

## Architecture

### Mac host

- Imported photos and videos are copied into `/Volumes/Seagate Expansion Drive/Snaplet/HostData/Photos/` and `/Volumes/Seagate Expansion Drive/Snaplet/HostData/Videos/`.
- Custom and generated video thumbnails are stored in `/Volumes/Seagate Expansion Drive/Snaplet/HostData/Thumbnails/`.
- Metadata is written into `/Volumes/Seagate Expansion Drive/Snaplet/HostData/snaplet.sqlite`.
- The host will not silently fall back to internal storage. If `Seagate Expansion Drive` is not mounted, the host dashboard shows a clear error and does not start the library service.
- The Mac advertises a local MultipeerConnectivity service.
- Random feeds request one SQLite-selected asset at a time.
- The video album requests a fixed-order catalog with thumbnail URLs, favorite state, file size, and video duration. Missing legacy durations are backfilled when the catalog is requested so length sorting works on older indexed videos too.

### iPhone viewer

- The viewer discovers the Mac host and connects automatically.
- Photos, Favorite Photos, Videos, and Favorite Videos are random full-screen feeds.
- Video playback supports audio, pause/play, mute/unmute, swipe up/down navigation, and tap-to-hide controls for an immersive full-screen view.
- Video Album is a separate top-bar tab with thumbnails, all/favorites filtering, newest/shortest/longest sorting, multi-select, batch delete, and tap-to-open playback.
- Video thumbnails can be replaced from the iPhone photo picker and are persisted on the Mac host.
- Upload from iPhone supports both photos and videos.
- Horizontal swipes switch between top-bar tabs and briefly reveal the top bar before it fades away.
- The menu tracks library counts, favorite counts, per-session views, photos/videos viewed today, and time spent in the app today.

## Important transport note

This project uses `MultipeerConnectivity`, which is the most practical Apple-native option for Mac-to-iPhone direct sessions. Apple can still choose infrastructure Wi-Fi, peer-to-peer Wi-Fi, or Bluetooth as the underlying transport, so this is not a strict guarantee that your existing Wi-Fi network will never be used underneath the connection.

## Verification in this environment

- `swift build`
- `swift run SnapletSmokeTests`
- `xcrun swiftc -typecheck ... Apps/iOSViewer/*.swift`
- `./Scripts/build-host.sh`
- Physical iPhone build/install via `xcodebuild ... -destination 'platform=iOS,id=...'` and `xcrun devicectl device install app ...`
- iOS Simulator run on `iPhone 17 Pro (iOS 26.4)` succeeded
- End-to-end simulator validation confirmed:
  - the viewer connected to the Mac host over `MultipeerConnectivity`
  - the host served a random image from SQLite-backed storage
  - the viewer cached the transferred file
  - SHA-256 hashes matched between the host copy and simulator cache copy, confirming lossless transfer

## Host Build Rule

Only one `SnapletHost.app` should exist on a development machine at a time.

- Use `./Scripts/build-host.sh` for local macOS host builds.
- The canonical output path is `.build/xcode/host/Build/Products/Debug/SnapletHost.app`.
- The script prunes older `SnapletHost.app` bundles from repo-local build folders and Xcode `DerivedData` after a successful build.

## Generate the Xcode project

```bash
xcodegen generate
open Snaplet.xcodeproj
```

## What still needs Xcode

- Valid Apple Developer account credentials in Xcode for physical iPhone install/signing.
- Optional live validation of large video transfers and custom thumbnail replacement on a physical device.
