//
//  SocketConnection.swift
//  BroadcastExtension
//
//  The writer end of the app-group unix socket. The app side
//  (FlutterSocketConnection, in the vendored flutter_webrtc) binds and listens on
//  the same file; this connects to it and streams frames. Canonical flutter_webrtc
//  broadcast code — do not special-case it to this app.
//

import Foundation

class SocketConnection: NSObject, StreamDelegate {
  var didOpen: (() -> Void)?
  var didClose: ((Error?) -> Void)?

  private let filePath: String
  private var socketHandle: Int32 = -1
  private var address: sockaddr_un?

  private var inputStream: InputStream?
  private var outputStream: OutputStream?

  private var networkQueue: DispatchQueue?
  private var shouldKeepRunning = false

  init(filePath path: String) {
    filePath = path
    socketHandle = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    super.init()

    guard setupAddress() == true else { return }
  }

  func open() -> Bool {
    guard FileManager.default.fileExists(atPath: filePath) else { return false }
    guard socketHandle != -1 else { return false }
    guard connectSocket() == true else { return false }

    setupStreams()
    inputStream?.open()
    outputStream?.open()
    return true
  }

  func close() {
    shouldKeepRunning = false
    cleanup()
  }

  func writeToStream(buffer: UnsafePointer<UInt8>, maxLength length: Int) -> Int {
    outputStream?.write(buffer, maxLength: length) ?? 0
  }

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .openCompleted:
      didOpen?()
    case .hasSpaceAvailable:
      break
    case .errorOccurred:
      close()
      didClose?(aStream.streamError)
    case .endEncountered:
      close()
      didClose?(nil)
    default:
      break
    }
  }

  // MARK: - Private

  private func setupAddress() -> Bool {
    var addr = sockaddr_un()
    guard filePath.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
    addr.sun_family = sa_family_t(AF_UNIX)
    _ = withUnsafeMutablePointer(to: &addr.sun_path.0) { ptr in
      filePath.withCString { strncpy(ptr, $0, filePath.count) }
    }
    address = addr
    return true
  }

  private func connectSocket() -> Bool {
    guard var addr = address else { return false }
    let status = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.connect(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    return status == 0
  }

  private func setupStreams() {
    var readStream: Unmanaged<CFReadStream>?
    var writeStream: Unmanaged<CFWriteStream>?
    CFStreamCreatePairWithSocket(kCFAllocatorDefault, socketHandle,
                                 &readStream, &writeStream)
    inputStream = readStream?.takeRetainedValue()
    inputStream?.delegate = self
    inputStream?.setProperty(kCFBooleanTrue,
                             forKey: Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String))
    inputStream?.schedule(in: .current, forMode: .common)

    outputStream = writeStream?.takeRetainedValue()
    outputStream?.delegate = self
    outputStream?.setProperty(kCFBooleanTrue,
                              forKey: Stream.PropertyKey(rawValue: kCFStreamPropertyShouldCloseNativeSocket as String))
    outputStream?.schedule(in: .current, forMode: .common)
  }

  private func cleanup() {
    inputStream?.remove(from: .current, forMode: .common)
    outputStream?.remove(from: .current, forMode: .common)
    inputStream?.delegate = nil
    outputStream?.delegate = nil
    inputStream?.close()
    outputStream?.close()
    inputStream = nil
    outputStream = nil
    if socketHandle != -1 {
      Darwin.close(socketHandle)
      socketHandle = -1
    }
  }
}
