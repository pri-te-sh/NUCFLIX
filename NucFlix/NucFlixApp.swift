import SwiftUI
import GoogleSignIn

@main
struct NucFlixApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState: AppState
    @State private var cloud: CloudAccount

    init() {
        // Firebase must be configured before the account store attaches its auth listener.
        CloudBootstrap.configure()
        _appState = State(initialValue: AppState())
        _cloud = State(initialValue: CloudAccount())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(cloud)
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
