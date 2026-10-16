//
//  DarwinNotificationCenter.swift
//  BroadcastExtension
//
//  Cross-process notifications, used to tell the app a broadcast started or
//  stopped. Darwin notifications are the one signalling mechanism that reaches
//  across the app/extension process boundary without a shared container. Canonical
//  flutter_webrtc broadcast code.
//

import Foundation

enum DarwinNotification: String {
  case broadcastStarted = "iOS_BroadcastStarted"
  case broadcastStopped = "iOS_BroadcastStopped"
}

class DarwinNotificationCenter {
  static let shared = DarwinNotificationCenter()

  private let center = CFNotificationCenterGetDarwinNotifyCenter()

  func postNotification(_ name: DarwinNotification) {
    CFNotificationCenterPostNotification(
      center,
      CFNotificationName(rawValue: name.rawValue as CFString),
      nil, nil, true)
  }
}
