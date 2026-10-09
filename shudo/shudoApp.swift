//
//  shudoApp.swift
//  shudo
//
//  Created by Luke on 8/16/25.
//

import SwiftUI

@main
struct shudoApp: App {
    @UIApplicationDelegateAdaptor(ShudoAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        CaptureDiagnostics.beginSession()
        DayNotificationScheduler.migrateLegacyPreference()
        // Warm the on-device speech model (locale reservation + first-run
        // download) before any mic tap. `.current` is SpeechAssetPreparer.shared
        // in production and the scripted assets under DEBUG UI-test launch args.
        VoiceEnvironment.current.assets.prepare()
        Design.Typeface.installAppearance()
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
            .font(Design.Typeface.text(.body))
            .tint(Design.Color.accentPrimary)
            .preferredColorScheme(.dark)
            .onOpenURL { url in
                AppRouter.shared.handle(url: url)
            }
            .onChange(of: scenePhase) { _, newPhase in
                switch newPhase {
                case .active:
                    CaptureDiagnostics.record(.appBecameActive, state: "active")
                    Task {
                        await AuthSessionManager.shared.refreshIfNeeded()
                        await CoachSync.shared.handleForeground()
                    }
                case .inactive:
                    CaptureDiagnostics.record(.appBecameInactive, state: "inactive")
                case .background:
                    CaptureDiagnostics.record(.appEnteredBackground, state: "background")
                    CoachSync.scheduleAppRefresh()
                @unknown default:
                    break
                }
            }
        }
        .backgroundTask(.appRefresh(CoachSync.backgroundRefreshIdentifier)) {
            await CoachSync.shared.handleBackgroundRefresh()
        }
    }
}
