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
        StreamPresence.shared.install()
        _appState = State(initialValue: AppState())
        _cloud = State(initialValue: CloudAccount())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .environment(cloud)
                .onOpenURL { url in
                    // nucflix://pair?code=K7Q2M9XD — the QR code a Fire TV shows while it waits to be paired.
                    if url.scheme == "nucflix", url.host == "pair" {
                        let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                            .queryItems?.first { $0.name == "code" }?.value ?? ""
                        cloud.scannedPairCode = code.isEmpty ? nil : code
                        return
                    }
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
