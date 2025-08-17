import SwiftUI

struct RootView: View {
    @ObservedObject private var session = AuthSessionManager.shared
    var body: some View {
        Group {
            if session.session != nil {
                TodayView()
            } else {
                AuthView()
            }
        }
    }
}


