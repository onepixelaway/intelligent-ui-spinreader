import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private let appGroupID = "group.com.tareqismail.ponder"
    private let pendingURLKey = "pendingShareURL"
    private let urlScheme = "spinreader"

    private let spinner = UIActivityIndicatorView(style: .medium)

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        Task { await processShare() }
    }

    private func setupUI() {
        view.backgroundColor = UIColor(white: 0.07, alpha: 1.0)

        let container = UIStackView()
        container.axis = .vertical
        container.alignment = .center
        container.spacing = 18
        container.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(container)

        let iconBackground = UIView()
        iconBackground.backgroundColor = .white
        iconBackground.layer.cornerRadius = 16
        iconBackground.layer.cornerCurve = .continuous
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "book.fill"))
        icon.tintColor = .black
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false
        iconBackground.addSubview(icon)

        let title = UILabel()
        title.text = "Saving to Spin Reader…"
        title.textColor = .white
        title.font = .systemFont(ofSize: 16, weight: .medium)

        spinner.color = UIColor(white: 1.0, alpha: 0.7)
        spinner.startAnimating()

        container.addArrangedSubview(iconBackground)
        container.addArrangedSubview(title)
        container.addArrangedSubview(spinner)

        NSLayoutConstraint.activate([
            container.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            container.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 72),
            iconBackground.heightAnchor.constraint(equalToConstant: 72),
            icon.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 36),
            icon.heightAnchor.constraint(equalToConstant: 36),
        ])
    }

    private func processShare() async {
        let sharedURL = await extractSharedURL()
        if let sharedURL {
            persist(sharedURL: sharedURL)
            openMainApp(with: sharedURL)
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        await MainActor.run {
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        }
    }

    private func extractSharedURL() async -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else { return nil }
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = await loadURL(from: provider) {
                    return url
                }
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let url = await loadURLFromText(provider: provider) {
                    return url
                }
            }
        }
        return nil
    }

    private func loadURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                let url = (item as? URL)
                    ?? (item as? NSURL).map { $0 as URL }
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
                continuation.resume(returning: url)
            }
        }
    }

    private func loadURLFromText(provider: NSItemProvider) async -> URL? {
        let text: String? = await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                let value = (item as? String)
                    ?? (item as? NSString).map { $0 as String }
                    ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                continuation.resume(returning: value)
            }
        }
        guard let text else { return nil }
        return firstURL(in: text)
    }

    private func firstURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(text.startIndex..., in: text)
        return detector?.firstMatch(in: text, options: [], range: range)?.url
    }

    private func persist(sharedURL: URL) {
        guard let defaults = UserDefaults(suiteName: appGroupID) else { return }
        defaults.set(sharedURL.absoluteString, forKey: pendingURLKey)
    }

    private func openMainApp(with sharedURL: URL) {
        var components = URLComponents()
        components.scheme = urlScheme
        components.host = "import"
        components.queryItems = [URLQueryItem(name: "url", value: sharedURL.absoluteString)]
        guard let openURL = components.url else { return }

        let selector = sel_registerName("openURL:")
        var responder: UIResponder? = self
        while let current = responder {
            if current.responds(to: selector) {
                _ = current.perform(selector, with: openURL)
                return
            }
            responder = current.next
        }
    }
}
