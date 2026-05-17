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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 10)

            WebContainer(model: model)
                .background(Color.black)
                .ignoresSafeArea(edges: [.horizontal, .bottom])
                .overlay(alignment: .bottom) {
                    toolbar
                        .padding(.horizontal, 12)
                        .padding(.bottom, 4)
                }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard !didPrefill else { return }
            didPrefill = true
            if let initial = initialURL {
                addressText = initial.absoluteString
                model.load(url: initial)
            } else {
                Task { await prefillFromClipboardIfAvailable() }
            }
        }
        .onChange(of: model.currentURL) { _, newURL in
            guard !addressFocused, let newURL else { return }
            let next = newURL.absoluteString
            guard next != addressText else { return }
            addressText = next
        }
    }

    private var header: some View {
        ZStack {
            Text("Save Article from Web")
                .font(.custom("DMSans-Bold", size: 17))
                .tracking(-0.4)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .center)

            HStack {
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 32, height: 32)
                }
                .darkFrosted(in: Circle())
            }
        }
    }

    private var toolbar: some View {
        let saveTarget = saveTargetURL()
        let canSave = saveTarget != nil && model.webView != nil

        return HStack(spacing: 10) {
            Button {
                model.goBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
            }
            .darkFrosted(in: Circle())
            .dimmedDisabled(!model.canGoBack)

            addressField

            Button {
                if let target = saveTarget, let webView = model.webView {
                    onImport(webView, target)
                }
            } label: {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 48, height: 48)
            }
            .darkFrosted(in: Circle())
            .dimmedDisabled(!canSave)
        }
    }

    private var addressField: some View {
        let canReload = model.currentURL != nil || model.isLoading

        return HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension.fill")
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 22, height: 22)

            ZStack {
                TextField("Search or enter address", text: $addressText)
                    .focused($addressFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .foregroundColor(.white)
                    .tint(.white)
                    .font(.system(size: 16, weight: .semibold))
                    .multilineTextAlignment(addressFocused ? .leading : .center)
                    .onSubmit(submitAddress)
                    .opacity(showHostOverlay ? 0 : 1)

                if showHostOverlay {
                    Text(displayDomain)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity)

            Button {
                if model.isLoading { model.stopLoading() } else { model.reload() }
            } label: {
                Image(systemName: model.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .dimmedDisabled(!canReload)
        }
        .padding(.horizontal, 16)
        .frame(height: 48)
        .frame(maxWidth: .infinity)
        .darkFrosted(in: Capsule())
        .contentShape(Capsule())
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

    private var displayDomain: String {
        model.currentURL?.displayHost ?? ""
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

    private func prefillFromClipboardIfAvailable() async {
        let hasURL = await withCheckedContinuation { continuation in
            UIPasteboard.general.detectPatterns(for: [.probableWebURL]) { result in
                switch result {
                case .success(let patterns):
                    continuation.resume(returning: patterns.contains(.probableWebURL))
                case .failure:
                    continuation.resume(returning: false)
                }
            }
        }
        guard hasURL, let url = clipboardURL() else { return }
        addressText = url.absoluteString
        model.load(url: url)
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
        webView.customUserAgent = WebUserAgent.safari
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let model: BrowserModel
        private var observations: [NSKeyValueObservation] = []

        init(model: BrowserModel) {
            self.model = model
        }

        func attach(to webView: WKWebView) {
            observations = [
                bind(webView, \.canGoBack)    { m, v in if m.canGoBack    != v { m.canGoBack    = v } },
                bind(webView, \.canGoForward) { m, v in if m.canGoForward != v { m.canGoForward = v } },
                bind(webView, \.isLoading)    { m, v in if m.isLoading    != v { m.isLoading    = v } },
                bind(webView, \.url)          { m, v in if m.currentURL   != v { m.currentURL   = v } },
            ]
        }

        private func bind<V: Sendable>(
            _ webView: WKWebView,
            _ source: KeyPath<WKWebView, V>,
            apply: @escaping @MainActor (BrowserModel, V) -> Void
        ) -> NSKeyValueObservation {
            let model = self.model
            return webView.observe(source, options: [.new, .initial]) { _, change in
                guard let value = change.newValue else { return }
                MainActor.assumeIsolated { apply(model, value) }
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

