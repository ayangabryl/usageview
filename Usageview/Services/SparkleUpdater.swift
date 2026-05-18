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

    /// Always enabled in the DMG build — Sparkle itself gates whether a check can run.
    var canCheckForUpdates: Bool = true
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
        // Keep canCheckForUpdates in sync via KVO.
        // Use Task { @MainActor in } to avoid @Observable / DispatchQueue conflicts.
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
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
