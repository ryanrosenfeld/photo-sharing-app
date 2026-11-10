import GoogleSignIn
import Supabase
import SwiftUI

@main
struct PhotoShareApp: App {
    init() {
        FaceIndexer.registerBackgroundTask()
        #if DEBUG
        // Line-buffer stdout so [AutoShare] logs survive when the harness kills the app (simctl --stdout=file).
        setvbuf(stdout, nil, _IOLBF, 0)
        #endif
        // Large titles in the brand serif, ink colour (the nav bar itself is the system's glass bar on iOS 26).
        let large = UINavigationBarAppearance()
        large.configureWithTransparentBackground()
        large.largeTitleTextAttributes = [
            .font: UIFont(name: "Georgia-Bold", size: 34) ?? .boldSystemFont(ofSize: 34),
            .foregroundColor: UIColor(OttoColor.ink),
        ]
        large.titleTextAttributes = [.foregroundColor: UIColor(OttoColor.ink)]
        UINavigationBar.appearance().standardAppearance = large
        UINavigationBar.appearance().scrollEdgeAppearance = large
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
