//
//  SampleHandler.swift
//  BroadcastExtension — the screen-share capture half of issue #43.
//
//  ReplayKit runs this in its own process when the system broadcast picker starts
//  our extension. It receives the whole device's screen as CMSampleBuffers and has
//  to get them to the app's peer connection, which lives in a *different* process.
//  The bridge is a unix-domain socket on a file inside the shared App Group: the
//  app (via flutter_webrtc's FlutterSocketConnectionFrameReader) listens, this
//  uploader connects and writes each frame in the CFHTTPMessage framing the reader
//  expects. Nothing here is app-specific — it is the canonical flutter_webrtc
//  broadcast handler, and the only knob is the App Group id below, which must match
//  Runner's RTCAppGroupIdentifier and the App Group on both targets.
//

import ReplayKit

class SampleHandler: RPBroadcastSampleHandler {

  // Must equal Runner/Info.plist RTCAppGroupIdentifier and the App Group
  // entitlement on both the app and this extension.
  private let appGroupIdentifier = "group.com.jonasgrunau.gatherCompanion.screenshare"

  private var clientConnection: SocketConnection?
  private var uploader: SampleUploader?

  private var frameCount = 0

  override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
    frameCount = 0
    guard let path = socketPath(for: appGroupIdentifier) else {
      finishBroadcastWithError(broadcastError("App Group not reachable"))
      return
    }
    let connection = SocketConnection(filePath: path)
    clientConnection = connection
    uploader = SampleUploader(connection: connection)

    // The app side only starts listening once it has asked for the broadcast, so
    // nudge it and keep retrying the connect for a beat rather than racing it.
    setupConnection()
    DarwinNotificationCenter.shared.postNotification(.broadcastStarted)
    openConnection()
  }

  override func broadcastFinished() {
    DarwinNotificationCenter.shared.postNotification(.broadcastStopped)
    clientConnection?.close()
    uploader = nil
  }

  override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                    with sampleBufferType: RPSampleBufferType) {
    // Video only, matching the app's video-only producer (tab audio is out of
    // scope for issue #43).
    guard sampleBufferType == .video else { return }
    uploader?.send(sample: sampleBuffer)
  }

  // MARK: - Connection

  private func setupConnection() {
    clientConnection?.didClose = { [weak self] error in
      if let error = error {
        self?.finishBroadcastWithError(error)
      } else {
        // The app closed the socket cleanly — it tore the share down on its end.
        let userInfo = [NSLocalizedDescriptionKey: "Screen sharing stopped"]
        self?.finishBroadcastWithError(
          NSError(domain: "BroadcastExtension", code: 0, userInfo: userInfo))
      }
    }
  }

  private func openConnection() {
    let queue = DispatchQueue(label: "broadcast.connectTimer")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(50))
    timer.setEventHandler { [weak self] in
      guard let self = self else { return }
      if self.clientConnection?.open() == true {
        timer.cancel()
      }
    }
    timer.resume()
  }

  private func socketPath(for groupIdentifier: String) -> String? {
    guard let url = FileManager.default
      .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
      return nil
    }
    // Must match the file the app side opens: flutter_webrtc uses "rtc_SSFD".
    return url.appendingPathComponent("rtc_SSFD").path
  }

  private func broadcastError(_ message: String) -> NSError {
    NSError(domain: "BroadcastExtension", code: -1,
            userInfo: [NSLocalizedDescriptionKey: message])
  }
}
