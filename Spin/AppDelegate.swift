import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    nonisolated(unsafe) static var orientationLock = UIInterfaceOrientationMask.portrait

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureNavigationBarAppearance()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    private func configureNavigationBarAppearance() {
        let titleFont = UIFont(name: "DMSans-Bold", size: 17) ?? UIFont.systemFont(ofSize: 17, weight: .semibold)
        let largeTitleFont = UIFont(name: "DMSans-Bold", size: 34) ?? UIFont.systemFont(ofSize: 34, weight: .semibold)

        let appearance = UINavigationBarAppearance()
        appearance.configureWithDefaultBackground()
        appearance.titleTextAttributes = [.font: titleFont, .kern: -0.4]
        appearance.largeTitleTextAttributes = [.font: largeTitleFont, .kern: -0.5]

        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }
}
