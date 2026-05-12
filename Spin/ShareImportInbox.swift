import Foundation
import SwiftUI

@MainActor
final class ShareImportInbox: ObservableObject {
    static let appGroupID = "group.com.tareqismail.ponder"
    static let pendingURLKey = "pendingShareURL"
    static let urlScheme = "spinreader"

    @Published var pendingURL: URL?

    func handleIncomingURL(_ url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme,
              url.host?.lowercased() == "import",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawTarget = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let target = URL(string: rawTarget),
              target.scheme?.lowercased().hasPrefix("http") == true
        else { return }
        pendingURL = target
    }

    func consumePendingFromAppGroup() {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID),
              let stored = defaults.string(forKey: Self.pendingURLKey),
              let url = URL(string: stored)
        else { return }
        defaults.removeObject(forKey: Self.pendingURLKey)
        pendingURL = url
    }

    func clear() {
        pendingURL = nil
    }
}
