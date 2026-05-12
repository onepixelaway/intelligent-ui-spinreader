import Foundation
import SwiftUI
import WebKit

@MainActor
final class BackgroundArticleImporter: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case importing(progress: Double)
        case success
        case failure
    }

    @Published var phase: Phase = .idle

    private var webView: WKWebView?
    private var progressObservation: NSKeyValueObservation?
    private var navigationContinuation: CheckedContinuation<Void, Never>?
    private var isAwaitingNavigation: Bool = false
    private var dismissTask: Task<Void, Never>?

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
            phase = .failure
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
