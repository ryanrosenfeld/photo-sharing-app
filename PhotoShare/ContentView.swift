import GoogleSignIn
import SwiftUI

struct ContentView: View {
    @StateObject private var authManager = AuthManager()
    @StateObject private var inviteRouter = InviteRouter()

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
        .environmentObject(inviteRouter)
        .onOpenURL { url in
            if inviteRouter.handle(url) { return }
            GIDSignIn.sharedInstance.handle(url)
            Task { try? await supabase.auth.session(from: url) }
        }
    }
}

#Preview {
    ContentView()
}
