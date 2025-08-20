//
//  shudoApp.swift
//  shudo
//
//  Created by Luke on 8/16/25.
//

import SwiftUI

@main
struct shudoApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackground()
                RootView()
            }
            .tint(Design.Color.accentPrimary)
            .preferredColorScheme(.dark)
            .onOpenURL { _ in }
        }
    }
}
