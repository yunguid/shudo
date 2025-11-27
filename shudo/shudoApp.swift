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
    
    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackground()
                RootView()
            }
            .tint(Design.Color.accentPrimary)
            .preferredColorScheme(.dark)
            .onOpenURL { _ in }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task { await AuthSessionManager.shared.refreshIfNeeded() }
                }
            }
        }
    }
}
