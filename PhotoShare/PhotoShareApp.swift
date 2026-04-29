import GoogleSignIn
import Supabase
import SwiftUI

@main
struct PhotoShareApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                    Task {
                        try? await supabase.auth.session(from: url)
                    }
                }
        }
    }
}
