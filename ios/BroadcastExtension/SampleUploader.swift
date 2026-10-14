//
//  SampleUploader.swift
//  BroadcastExtension
//
//  Encodes each screen CMSampleBuffer into the CFHTTPMessage framing the app's
//  FlutterSocketConnectionFrameReader parses — header fields carry the width,
//  height and orientation, the body is the raw pixel buffer — and streams it over
//  the socket. Canonical flutter_webrtc broadcast code.
//

import Accelerate
import CoreImage
import Foundation
import ReplayKit

private enum Constants {
  static let bufferMaxLength = 10 * 1024
}

class SampleUploader {
  private var connection: SocketConnection

  private var dataToSend: Data?
  private var byteIndex = 0

  private let serialQueue: DispatchQueue
  private var isReady = false

  init(connection: SocketConnection) {
    self.connection = connection
    serialQueue = DispatchQueue(label: "broadcast.sampleUploader")
    setupConnection()
  }

  @discardableResult
  func send(sample buffer: CMSampleBuffer) -> Bool {
    guard isReady else { return false }
    isReady = false

    dataToSend = prepare(sample: buffer)
    byteIndex = 0

    guard dataToSend != nil else {
      // Encoding failed for this one frame. Stay ready so the next frame still
      // sends — a transient failure must not wedge the whole broadcast.
      isReady = true
      return false
    }

    serialQueue.async { [weak self] in
      self?.sendDataChunk()
    }
    return true
  }

  // MARK: - Private

  private func setupConnection() {
    connection.didOpen = { [weak self] in self?.isReady = true }
    connection.didClose = { [weak self] _ in self?.isReady = false }
    // A single screen frame is far larger than one stream write, so it goes out in
    // chunks: write until the stream reports no space, then wait. The output
    // stream's `hasSpaceAvailable` is what resumes the rest — without this wiring a
    // frame stalls after its first chunk and the message never completes (the
    // receiver shows a permanent black tile). Runs on the same serial queue as the
    // initial send so byteIndex/dataToSend are never touched from two threads.
    connection.streamHasSpaceAvailable = { [weak self] in
      self?.serialQueue.async { self?.sendDataChunk() }
    }
  }

  private func sendDataChunk() {
    guard let dataToSend = dataToSend else { return }

    // Write as many chunks as the stream will take right now. A short write (0)
    // means the stream is momentarily full; stop and let `hasSpaceAvailable` call
    // us back to finish the *same* frame rather than dropping it.
    while byteIndex < dataToSend.count {
      let bytesLeft = dataToSend.count - byteIndex
      let chunk = bytesLeft > Constants.bufferMaxLength ? Constants.bufferMaxLength : bytesLeft

      let written = dataToSend[byteIndex..<(byteIndex + chunk)].withUnsafeBytes {
        guard let ptr = $0.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
        return connection.writeToStream(buffer: ptr, maxLength: chunk)
      }

      if written > 0 {
        byteIndex += written
      } else {
        // Stream full — resume on the next hasSpaceAvailable.
        return
      }
    }

    // Whole frame delivered; accept the next one.
    self.dataToSend = nil
    byteIndex = 0
    isReady = true
  }

  private func prepare(sample buffer: CMSampleBuffer) -> Data? {
    guard let imageBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }

    let scaleFactor = 1.0
    let width = CVPixelBufferGetWidth(imageBuffer) / Int(scaleFactor)
    let height = CVPixelBufferGetHeight(imageBuffer) / Int(scaleFactor)
    let orientation = CMGetAttachment(buffer,
                                      key: RPVideoSampleOrientationKey as CFString,
                                      attachmentModeOut: nil)?.uintValue ?? 0

    let scaleTransform = CGAffineTransform(scaleX: CGFloat(1.0 / scaleFactor),
                                           y: CGFloat(1.0 / scaleFactor))
    let bufferData = jpegData(from: imageBuffer, scale: scaleTransform)
    guard let messageData = bufferData else { return nil }

    let httpResponse = CFHTTPMessageCreateResponse(kCFAllocatorDefault, 200, nil,
                                                   kCFHTTPVersion1_1).takeRetainedValue()
    CFHTTPMessageSetHeaderFieldValue(httpResponse, "Content-Length" as CFString,
                                     String(messageData.count) as CFString)
    CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Width" as CFString,
                                     String(width) as CFString)
    CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Height" as CFString,
                                     String(height) as CFString)
    CFHTTPMessageSetHeaderFieldValue(httpResponse, "Buffer-Orientation" as CFString,
                                     String(orientation) as CFString)
    CFHTTPMessageSetBody(httpResponse, messageData as CFData)

    return CFHTTPMessageCopySerializedMessage(httpResponse)?.takeRetainedValue() as Data?
  }

  private func jpegData(from buffer: CVPixelBuffer, scale scaleTransform: CGAffineTransform) -> Data? {
    let image = CIImage(cvPixelBuffer: buffer).transformed(by: scaleTransform)
    guard let colorSpace = image.colorSpace else { return nil }
    let context = CIContext(options: nil)
    let options: [CIImageRepresentationOption: Float] = [
      CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 1.0
    ]
    return context.jpegRepresentation(of: image, colorSpace: colorSpace, options: options)
  }
}
