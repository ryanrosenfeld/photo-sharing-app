import GoogleSignIn
import Supabase
import SwiftUI

@main
struct PhotoShareApp: App {
    init() {
        #if DEBUG
        // Line-buffer stdout so [AutoShare] logs survive when the harness kills the app (simctl --stdout=file).
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
    }

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
