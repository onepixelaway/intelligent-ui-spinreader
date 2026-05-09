import SwiftUI
import WebKit
import UIKit

@MainActor
final class BrowserModel: ObservableObject {
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isLoading: Bool = false
    @Published var currentURL: URL?

    weak var webView: WKWebView?

    func load(url: URL) {
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }
    func stopLoading() { webView?.stopLoading() }
}

struct BrowserView: View {
    let initialURL: URL?
    let onImport: (WKWebView, URL) -> Void

    @StateObject private var model = BrowserModel()
    @State private var addressText: String = ""
    @State private var didPrefill: Bool = false
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                WebContainer(model: model)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            toolbar
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let initial = initialURL {
                addressText = initial.absoluteString
                model.load(url: initial)
            } else if let pasted = clipboardURL() {
                addressText = pasted.absoluteString
            }
        }
        .onChange(of: model.currentURL) { _, newURL in
            guard !addressFocused, let newURL else { return }
            let next = newURL.absoluteString
            guard next != addressText else { return }
            addressText = next
        }
    }

    private var toolbar: some View {
        let saveTarget = saveTargetURL()
        let canSave = saveTarget != nil && model.webView != nil
        let canReload = model.currentURL != nil || model.isLoading

        return HStack(spacing: 14) {
            navButton(systemName: "chevron.left", enabled: model.canGoBack, action: model.goBack)
            navButton(systemName: "chevron.right", enabled: model.canGoForward, action: model.goForward)

            addressField

            Button {
                if model.isLoading { model.stopLoading() } else { model.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 32)
                    .contentTransition(.symbolEffect(.replace))
            }
            .foregroundColor(.white)
            .dimmedDisabled(!canReload)

            Button {
                if let target = saveTarget, let webView = model.webView {
                    onImport(webView, target)
                }
            } label: {
                Image(systemName: "text.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 32)
            }
            .foregroundColor(.white)
            .dimmedDisabled(!canSave)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            Color(white: 0.08)
                .overlay(
                    Rectangle()
                        .frame(height: 0.5)
                        .foregroundColor(.white.opacity(0.08)),
                    alignment: .top
                )
                .ignoresSafeArea(edges: .bottom)
        )
    }

    private func navButton(systemName: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .frame(width: 28, height: 32)
        }
        .disabled(!enabled)
        .foregroundColor(enabled ? .white : .white.opacity(0.25))
    }

    private var addressField: some View {
        ZStack(alignment: .leading) {
            TextField("Search or enter address", text: $addressText)
                .focused($addressFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .foregroundColor(.white)
                .tint(.white)
                .font(.system(size: 14))
                .onSubmit(submitAddress)
                .opacity(showHostOverlay ? 0 : 1)

            if showHostOverlay {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                    Text(model.currentURL?.host() ?? "")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(white: 0.18))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !addressFocused else { return }
            if let current = model.currentURL?.absoluteString, current != addressText {
                addressText = current
            }
            addressFocused = true
        }
    }

    private var showHostOverlay: Bool {
        !addressFocused && (model.currentURL?.host()?.isEmpty == false)
    }

    private func saveTargetURL() -> URL? {
        if let url = model.currentURL { return url }
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return URL(string: trimmed)
    }

    private func submitAddress() {
        let trimmed = addressText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let resolved = resolveURL(from: trimmed)
        addressText = resolved.absoluteString
        addressFocused = false
        model.load(url: resolved)
    }

    private func resolveURL(from raw: String) -> URL {
        if let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return url
        }
        if raw.contains(".") && !raw.contains(" "),
           let url = URL(string: "https://" + raw) {
            return url
        }
        let query = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: "https://www.google.com/search?q=\(query)")
            ?? URL(string: "https://www.google.com")!
    }

    private func clipboardURL() -> URL? {
        let pb = UIPasteboard.general
        let candidate: URL? = pb.hasURLs
            ? pb.url
            : pb.string.flatMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard let url = candidate, let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

private extension View {
    func dimmedDisabled(_ disabled: Bool) -> some View {
        self.disabled(disabled).opacity(disabled ? 0.3 : 1)
    }
}

private struct WebContainer: UIViewRepresentable {
    @ObservedObject var model: BrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        config.applicationNameForUserAgent = "Version/17.5 Mobile/15E148 Safari/604.1"

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.customUserAgent = Self.safariUserAgent
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator

        context.coordinator.attach(to: webView)
        model.webView = webView
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    static let safariUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) {
            self.model = model
        }

        func attach(to webView: WKWebView) {
            observations.append(observe(webView, \.canGoBack, \.canGoBack))
            observations.append(observe(webView, \.canGoForward, \.canGoForward))
            observations.append(observe(webView, \.isLoading, \.isLoading))
            observations.append(observe(webView, \.url, \.currentURL))
        }

        private func observe<V: Equatable>(
            _ webView: WKWebView,
            _ source: KeyPath<WKWebView, V>,
            _ target: ReferenceWritableKeyPath<BrowserModel, V>
        ) -> NSKeyValueObservation {
            webView.observe(source, options: [.new, .initial]) { [weak self] wv, _ in
                let value = wv[keyPath: source]
                Task { @MainActor in
                    guard let self, self.model[keyPath: target] != value else { return }
                    self.model[keyPath: target] = value
                }
            }
        }

        func detach() {
            observations.forEach { $0.invalidate() }
            observations.removeAll()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                webView.load(navigationAction.request)
            }
            return nil
        }
    }
}

