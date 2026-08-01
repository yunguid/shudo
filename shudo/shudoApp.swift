//
//  shudoApp.swift
//  shudo
//
//  Created by Luke on 8/16/25.
//

import SwiftUI

@main
struct shudoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppTheme.storageKey) private var selectedTheme = AppTheme.defaultTheme.rawValue

    init() {
        CaptureDiagnostics.beginSession()
        DayNotificationScheduler.migrateLegacyPreference()
        // Meal photos are served from stable signed URLs; a right-sized URL
        // cache lets repeat visits render them without any network work.
        URLCache.shared = URLCache(
            memoryCapacity: 24 * 1024 * 1024,
            diskCapacity: 64 * 1024 * 1024
        )
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackground()
                RootView()
            }
            .tint(Design.Color.accentPrimary)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                AppRouter.shared.handle(url: url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    CaptureDiagnostics.record(.appBecameActive, state: "active")
                    Task { await AuthSessionManager.shared.refreshIfNeeded() }
                case .inactive:
                    CaptureDiagnostics.record(.appBecameInactive, state: "inactive")
                case .background:
                    CaptureDiagnostics.record(.appEnteredBackground, state: "background")
                @unknown default:
                    break
                }
            }
        }
    }
}
