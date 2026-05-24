import SwiftUI
import AppKit

@main
struct UsageviewApp: App {
    @State private var store = AccountStore()
    @State private var refreshTimer: Timer?
    @State private var didInitialRefresh = false
    #if !MAS
    @State private var sparkle = SparkleUpdater()
    #else
    private let sparkle = SparkleUpdater()
    #endif

    init() {
        NSApplication.shared.setActivationPolicy(.accessory)
        KeychainPromptCoordinator.install()
        KeychainMigration.migrateIfNeeded()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(store: store)
                .task {
                    if !didInitialRefresh {
                        didInitialRefresh = true
                        await store.refreshAll(showLoading: false)
                    }
                    startAutoRefreshIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    startAutoRefreshIfNeeded()
                }
        } label: {
            let _ = store.dataVersion  // Force re-render when data changes
            Image(nsImage: store.menuBarIcon)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(store: store, sparkle: sparkle)
                .frame(minWidth: 440, idealWidth: 440, minHeight: 480, idealHeight: 520)
        }
    }

    private func startAutoRefreshIfNeeded() {
        refreshTimer?.invalidate()
        refreshTimer = nil

        let minutes = UserDefaults.standard.integer(forKey: "autoRefreshMinutes")
        guard minutes > 0 else { return }

        refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: true) { _ in
            Task { @MainActor in
                await store.refreshAll(showLoading: false)
            }
        }
    }
}
