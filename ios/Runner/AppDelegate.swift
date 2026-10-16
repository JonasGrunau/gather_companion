import AuthenticationServices
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // The Google Calendar OAuth channel. Registered off the same registry as the
    // plugins so it shares the implicit engine's messenger. See GoogleAuthChannel.
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "GatherOAuth") {
      GoogleAuthChannel.register(with: registrar.messenger())
    }
  }
}

/// The native half of `lib/src/google_calendar.dart`'s OAuth flow.
///
/// Wraps `ASWebAuthenticationSession` — part of iOS's own `AuthenticationServices`,
/// so it adds no CocoaPod and keeps this project SPM-only (see the pubspec pins and
/// the `google_sign_in` note in `google_calendar.dart`). The system session owns the
/// browser, the Safari cookie jar (so an already-signed-in Google user skips the
/// password) and the redirect capture; this class is only the `MethodChannel` seam
/// Dart reaches it through. Kept in this file rather than its own so it needs no
/// separate entry in the Xcode project's build sources.
final class GoogleAuthChannel: NSObject, ASWebAuthenticationPresentationContextProviding {
  private var session: ASWebAuthenticationSession?

  static func register(with messenger: FlutterBinaryMessenger) {
    let instance = GoogleAuthChannel()
    let channel = FlutterMethodChannel(name: "gather/oauth", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      instance.handle(call, result: result)
    }
    // Held by the channel's closure capture above; kept alive for the app's life.
    objc_setAssociatedObject(channel, &Self.retainKey, instance, .OBJC_ASSOCIATION_RETAIN)
  }

  private static var retainKey = 0

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "authenticate",
          let args = call.arguments as? [String: Any],
          let urlString = args["url"] as? String,
          let url = URL(string: urlString),
          let scheme = args["callbackScheme"] as? String
    else {
      result(FlutterError(code: "bad_args", message: "authenticate needs url + callbackScheme", details: nil))
      return
    }

    let session = ASWebAuthenticationSession(url: url, callbackURLScheme: scheme) { callbackURL, error in
      if let error = error as? ASWebAuthenticationSessionError,
         error.code == .canceledLogin {
        // A deliberate dismiss, not a failure — Dart maps this code to silence.
        result(FlutterError(code: "cancelled", message: "User cancelled", details: nil))
        return
      }
      if let error = error {
        result(FlutterError(code: "auth_failed", message: error.localizedDescription, details: nil))
        return
      }
      result(callbackURL?.absoluteString)
    }
    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    self.session = session
    session.start()
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    // The key window of the active foreground scene — where the sheet is anchored.
    let scene = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return scene?.windows.first { $0.isKeyWindow } ?? ASPresentationAnchor()
  }
}
