import SwiftUI

struct ContentView: View {
    @StateObject private var authManager = AuthManager()

    var body: some View {
        ZStack {
            OttoColor.canvas.ignoresSafeArea()
            if authManager.isLoading {
                ProgressView().tint(OttoColor.sage)
            } else if authManager.session != nil {
                MainTabView()
            } else {
                WelcomeView()
            }
        }
        .environmentObject(authManager)
    }
}

#Preview {
    ContentView()
}
