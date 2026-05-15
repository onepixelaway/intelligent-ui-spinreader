import Foundation
import SwiftUI
import UIKit
import WebKit

/// Copy-friendly diagnostics when Share Sheet → app import fails (for bug reports).
struct ShareImportDiagnostic: Equatable {
    let sourceURL: URL
    let loadedPageURL: URL?
    let underlyingErrorDescription: String
    let errorTypeName: String
    let nsErrorDomain: String
    let nsErrorCode: Int

    init(sourceURL: URL, loadedPageURL: URL?, error: Error) {
        self.sourceURL = sourceURL
        self.loadedPageURL = loadedPageURL
        self.underlyingErrorDescription = error.localizedDescription
        self.errorTypeName = String(describing: Swift.type(of: error))
        let ns = error as NSError
        self.nsErrorDomain = ns.domain
        self.nsErrorCode = ns.code
    }
}

extension ShareImportDiagnostic {
    /// Short text for alert body.
    var userVisibleSummary: String {
        var lines = [underlyingErrorDescription]
        lines.append("")
        lines.append("Tap Copy diagnostic report to copy details you can paste into a bug report.")
        return lines.joined(separator: "\n")
    }

    /// Multi-line blob for Messages / Cursor / GitHub issue.
    var clipboardReport: String {
        let bundle = Bundle.main
        let short =
            bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "(unknown)"
        let build =
            bundle.infoDictionary?["CFBundleVersion"] as? String ?? "(unknown)"

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]

        var lines: [String] = [
            "Spin Reader share/import diagnostic",
            "Generated (local time): \(fmt.string(from: Date()))",
            "\(ShareImportDiagnostic.appVersionLine(short: short, build: build))",
            "OS: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "",
            "Source URL: \(sourceURL.absoluteString)",
            "WKWebView URL after load attempt: \(loadedPageURL?.absoluteString ?? "(nil)")",
            "",
            "Error type: \(errorTypeName)",
            "localizedDescription: \(underlyingErrorDescription)",
        ]

        lines.append("NSError domain: \(nsErrorDomain)")
        lines.append("NSError code: \(nsErrorCode)")

        lines.append("")
        lines.append("(End of diagnostic; paste everything above)")
        return lines.joined(separator: "\n")
    }

    private static func appVersionLine(short: String, build: String) -> String {
        "App: \(short) build \(build)"
    }
}

@MainActor
final class BackgroundArticleImporter: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing(progress: Double)
        case success
        case failure(ShareImportDiagnostic)
    }

    @Published var phase: Phase = .idle

    private var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private var isAwaitingNavigation: Bool = false
    private var dismissTask: Task<Void, Never>?

    static func loadArticle(from url: URL) async throws -> WebArticle {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            configuration: config
        )
        let navigator = ArticleImportNavigator(webView: webView)
        webView.customUserAgent = WebUserAgent.safari
        webView.navigationDelegate = navigator
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
            navigator.invalidate()
        }

        navigator.load(url)
        await navigator.waitForNavigation(timeout: 5.0)
        return try await extractArticle(from: webView, sourceURL: url)
    }

    func importArticle(from url: URL, into store: WebArticleStore) async {
        dismissTask?.cancel()
        dismissTask = nil

        phase = .importing(progress: 0.05)

        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 375, height: 812),
            configuration: config
        )
        webView.customUserAgent = WebUserAgent.safari
        webView.navigationDelegate = self
        self.webView = webView

        progressObservation = webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
            guard let raw = change.newValue else { return }
            MainActor.assumeIsolated {
                self?.updateProgress(raw: raw)
            }
        }

        isAwaitingNavigation = true
        webView.load(URLRequest(url: url))

        await waitForNavigation(timeout: 5.0)
        progressObservation?.invalidate()
        progressObservation = nil

        await setProgress(0.85)

        do {
            let article = try await extractArticle(from: webView, sourceURL: url)
            await setProgress(0.95)
            try await store.save(article)
            phase = .success
        } catch {
            let diagnostic = ShareImportDiagnostic(
                sourceURL: url,
                loadedPageURL: webView.url,
                error: error
            )
            phase = .failure(diagnostic)
        }

        cleanup()

        let finalPhase = phase
        dismissTask = Task { [weak self] in
            let delay: UInt64 = (finalPhase == .success) ? 1_600_000_000 : 2_400_000_000
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.phase == finalPhase { self.phase = .idle }
            }
        }
    }

    private func updateProgress(raw: Double) {
        guard case .importing(let current) = phase else { return }
        let mapped = 0.05 + min(max(raw, 0), 1) * 0.7
        guard abs(mapped - current) >= 0.02 else { return }
        phase = .importing(progress: mapped)
    }

    private func setProgress(_ value: Double) async {
        guard case .importing(let current) = phase, current != value else { return }
        phase = .importing(progress: value)
    }

    private func waitForNavigation(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            navigationContinuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { self?.resumeNavigation() }
            }
        }
    }

    private func resumeNavigation() {
        guard isAwaitingNavigation else { return }
        isAwaitingNavigation = false
        let cont = navigationContinuation
        navigationContinuation = nil
        cont?.resume()
    }

    private func cleanup() {
        webView?.stopLoading()
        webView?.navigationDelegate = nil
        webView = nil
        progressObservation?.invalidate()
        progressObservation = nil
    }
}

@MainActor
private final class ArticleImportNavigator: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private var continuation: CheckedContinuation<Void, Never>?
    private var isAwaitingNavigation = false

    init(webView: WKWebView) {
        self.webView = webView
    }

    func load(_ url: URL) {
        isAwaitingNavigation = true
        webView.load(URLRequest(url: url))
    }

    func waitForNavigation(timeout: TimeInterval) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            continuation = cont
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await MainActor.run { self?.resumeNavigation() }
            }
        }
    }

    func invalidate() {
        resumeNavigation()
    }

    private func resumeNavigation() {
        guard isAwaitingNavigation else { return }
        isAwaitingNavigation = false
        let cont = continuation
        continuation = nil
        cont?.resume()
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }
}

extension BackgroundArticleImporter: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak self] in self?.resumeNavigation() }
    }
}
