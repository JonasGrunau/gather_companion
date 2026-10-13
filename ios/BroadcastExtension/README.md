# Screen-share Broadcast Upload Extension (issue #43)

This folder holds the iOS half of sharing the phone's **whole screen** into a
Gather call. The Dart/Flutter side, the control, and the SFU producer are already
wired and tested; what remains is a one-time **Xcode step** to turn these source
files into a real app-extension target. It is left as a manual step on purpose:
adding an app-extension target rewrites `Runner.xcodeproj/project.pbxproj` in ways
that are unsafe to hand-edit and impossible to verify without a device build, and
this project already signs on-device manually.

## Why an extension at all

`getDisplayMedia` on iOS has two modes. Without a broadcast extension it uses
`RPScreenRecorder`, which captures only *this app's* view — useless for a companion
whose own view is the map. With one, ReplayKit's system broadcast captures the
**entire device** (any app, any document), which is the thing a teammate on their
desk cannot otherwise see. The Dart side already requests broadcast mode by passing
`video.deviceId = "broadcast"` (see `webrtc_media_engine.dart`).

The extension runs in its own process. It hands frames to the app's peer connection
over a unix socket on a file inside a shared **App Group**; the app side (vendored
`flutter_webrtc` `FlutterSocketConnectionFrameReader`) listens, these files
(`SampleHandler` → `SampleUploader` → `SocketConnection`) connect and write.

## Identifiers (must all match)

| Thing | Value |
|---|---|
| App Group | `group.com.jonasgrunau.gatherCompanion.screenshare` |
| Extension bundle id | `com.jonasgrunau.gatherCompanion.Broadcast` |
| App Info.plist `RTCScreenSharingExtension` | the extension bundle id above |
| App Info.plist `RTCAppGroupIdentifier` | the App Group above |
| Socket file | `rtc_SSFD` (hard-coded in the plugin; do not change) |

The app Info.plist keys and the App Group entitlement on Runner (both
`Runner.entitlements` and `RunnerRelease.entitlements`) are **already committed**.

## The one-time Xcode step

1. **File ▸ New ▸ Target… ▸ Broadcast Upload Extension.** Name it
   `BroadcastExtension`, bundle id `com.jonasgrunau.gatherCompanion.Broadcast`,
   language Swift. Do **not** include a UI extension. Delete the stub
   `SampleHandler.swift` Xcode generates.
2. **Add these files to the new target** (drag them in, target membership =
   BroadcastExtension only): `SampleHandler.swift`, `SampleUploader.swift`,
   `SocketConnection.swift`, `DarwinNotificationCenter.swift`. Set the target's
   Info.plist to this folder's `Info.plist` and its `CODE_SIGN_ENTITLEMENTS` to
   `BroadcastExtension.entitlements`.
3. **App Groups capability** on *both* Runner and BroadcastExtension, with the
   group id above. (Already in the entitlements files — this is the provisioning
   side.)
4. **Link WebRTC** into the extension: it needs `WebRTC` (same framework the app
   uses) for the `RTCCVPixelBuffer`/HTTP framing. Add it to the extension's
   "Frameworks and Libraries", or add the extension to the `flutter_webrtc` /
   `WebRTC` pod target in the `Podfile` (`use_frameworks!` is already on).
5. **Signing.** This repo signs manually (see `../ExportOptions.plist` and the
   device-build notes). The extension needs its own provisioning profile for
   `com.jonasgrunau.gatherCompanion.Broadcast` with the App Groups entitlement.

## Verifying on device

Start a call, tap **Share your screen** in the call header, pick *Gather Screen* in
the system sheet. A desktop Gather client in the same space should see the phone's
screen as a screenshare tile. Tapping **Stop sharing** — or the OS "Stop" control
in the status bar — tears it down; the Dart side (`LiveCall._noticeScreenEnded`)
already drops the producer when the capture ends from outside the app.
