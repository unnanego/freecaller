import SwiftUI
import WatchKit

@main
struct FreecallerWatchApp: App {
  @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate

  var body: some Scene {
    WindowGroup {
      RootView()
        .environmentObject(AppSession.shared)
        .environmentObject(CallController.shared)
    }
  }
}

/// Start-up that must happen even when no UI does: a VoIP push launches the
/// app in the background, and PushKit has to be armed (and CallKit ready to
/// report the call) before the push is delivered.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
  func applicationDidFinishLaunching() {
    MainActor.assumeIsolated {
      AppSession.shared.start()
      CallController.shared.start()
    }
  }

  func applicationDidBecomeActive() {
    MainActor.assumeIsolated {
      Task { await AppSession.shared.refreshFromServer() }
    }
  }
}
