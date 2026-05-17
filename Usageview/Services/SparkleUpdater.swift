import Foundation
import SwiftUI

#if !MAS
import Sparkle

/// Wraps Sparkle's `SPUStandardUpdaterController` so
/// SwiftUI views can trigger "Check for Updates" with a simple binding.
@Observable
@MainActor
final class SparkleUpdater: NSObject {
    private let controller: SPUStandardUpdaterController
    private var observation: NSKeyValueObservation?

    var canCheckForUpdates: Bool = false
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    override init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()
        // KVO-observe canCheckForUpdates — Sparkle flips it to true after startup
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            DispatchQueue.main.async {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}
#else
/// No-op stub used for Mac App Store builds (Sparkle not permitted on MAS).
@Observable
@MainActor
final class SparkleUpdater {
    var canCheckForUpdates: Bool = false
    var automaticallyChecksForUpdates: Bool = false
    init() {}
    func checkForUpdates() {}
}
#endif
