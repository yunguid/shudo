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
                if newPhase == .active {
                    Task { await AuthSessionManager.shared.refreshIfNeeded() }
                }
            }
        }
    }
}
