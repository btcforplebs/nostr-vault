import UIKit
import SwiftUI

class SceneDelegate: UIResponder, UIWindowSceneDelegate {

    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = (scene as? UIWindowScene) else { return }

        // Start the Go relay
        StartRelayC(0)

        let window = UIWindow(windowScene: windowScene)
        
        // Use the same ContentView as the macOS app but adapted for iOS
        // Pass all the shared services via environment
        let configService = ConfigService.shared
        let relayManager = RelayProcessManager.shared
        let nostrService = NostrService.shared
        let statsService = StatsService.shared
        
        let contentView = ContentView()
            .environmentObject(configService)
            .environmentObject(relayManager)
            .environmentObject(nostrService)
            .environmentObject(statsService)
            .environmentObject(AppState.shared)
        
        window.rootViewController = UIHostingController(rootView: contentView)
        self.window = window
        window.makeKeyAndVisible()
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        StopRelayC()
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
    }

    func sceneWillResignActive(_ scene: UIScene) {
    }

    func sceneWillEnterForeground(_ scene: UIScene) {
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
    }
}