import AppKit
import MarcCore
import SwiftUI
import WebKit

/// Renders an HTML document in a web view that marc keeps on a short leash.
///
/// The page is loaded from disk with read access limited to its own folder, in
/// a data store that does not survive the tab, with every `http` and `https`
/// load blocked until the reader allows it for this file. The page's own
/// scripts run, because a local chart or demo is the reason to open it at all,
/// and with no network and no access outside its folder they have nowhere to
/// send anything.
///
/// A small injected reader walks the page for the same structural elements the
/// parser found in its source, in the same order, and reports where they sit on
/// screen. That is what lets outline navigation and reading progress work on an
/// HTML page without marc taking over its rendering.
struct HTMLPreview: NSViewRepresentable {
    @ObservedObject var document: MarkdownDocument
    @Binding var navigationTarget: String?
    let openLink: (URL) -> Void
    let openExternal: (URL) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, openLink: openLink, openExternal: openExternal)
    }

    func makeNSView(context: Context) -> WKWebView {
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: Coordinator.messageName)
        controller.addUserScript(
            WKUserScript(source: Self.readerScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )

        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = document.htmlAllowsScripts
        configuration.suppressesIncrementalRendering = false

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = true
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView
        context.coordinator.applyNetworkPolicy(allowed: document.htmlAllowsNetwork)
        context.coordinator.load(reason: .initial)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.openLink = openLink
        context.coordinator.openExternal = openExternal
        webView.pageZoom = document.preferences.theme.bodySize / MarkdownTheme.paper.bodySize

        if context.coordinator.appliedScriptPolicy != document.htmlAllowsScripts
            || context.coordinator.appliedNetworkPolicy != document.htmlAllowsNetwork {
            context.coordinator.applyNetworkPolicy(allowed: document.htmlAllowsNetwork)
            context.coordinator.load(reason: .policyChanged)
        } else if context.coordinator.loadedContent != document.savedContent {
            context.coordinator.load(reason: .contentChanged)
        }

        if let target = navigationTarget,
           let ordinal = document.parsedHTML?.blocks.first(where: { $0.id == target })?.ordinal {
            context.coordinator.scroll(to: ordinal)
            if document.headings.contains(where: { $0.id == target }) {
                document.preferences.lastScrollHeadingID = target
            }
            Task { @MainActor in navigationTarget = nil }
        }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: Coordinator.messageName)
        coordinator.readingTask?.cancel()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        static let messageName = "marcReader"

        enum LoadReason {
            case initial
            case contentChanged
            case policyChanged
        }

        var document: MarkdownDocument
        var openLink: (URL) -> Void
        var openExternal: (URL) -> Void
        weak var webView: WKWebView?

        private(set) var loadedContent: String?
        private(set) var appliedScriptPolicy: Bool?
        private(set) var appliedNetworkPolicy: Bool?
        private var tracker = ReadingScrollTracker()
        private var candidateID: String?
        var readingTask: Task<Void, Never>?

        init(
            document: MarkdownDocument,
            openLink: @escaping (URL) -> Void,
            openExternal: @escaping (URL) -> Void
        ) {
            self.document = document
            self.openLink = openLink
            self.openExternal = openExternal
        }

        func load(reason: LoadReason) {
            guard let webView else { return }
            appliedScriptPolicy = document.htmlAllowsScripts
            appliedNetworkPolicy = document.htmlAllowsNetwork
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript =
                document.htmlAllowsScripts
            loadedContent = document.savedContent
            tracker.reset()
            candidateID = nil
            // Read access is limited to the file's own folder so a page can pull
            // in its sibling stylesheet or image and nothing else on the disk.
            webView.loadFileURL(
                document.url,
                allowingReadAccessTo: document.url.deletingLastPathComponent()
            )
        }

        /// Installs or removes the rule list that blocks every `http` and
        /// `https` load. Local resources are untouched either way.
        func applyNetworkPolicy(allowed: Bool) {
            guard let webView else { return }
            let controller = webView.configuration.userContentController
            guard !allowed else {
                controller.removeAllContentRuleLists()
                return
            }
            WKContentRuleListStore.default()?.compileContentRuleList(
                forIdentifier: "marc-block-remote",
                encodedContentRuleList: Self.blockRemoteRules
            ) { list, _ in
                guard let list else { return }
                Task { @MainActor in
                    controller.removeAllContentRuleLists()
                    controller.add(list)
                }
            }
        }

        func scroll(to ordinal: Int) {
            webView?.evaluateJavaScript("window.__marcScrollTo && window.__marcScrollTo(\(ordinal))")
        }

        // MARK: Navigation

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }

            if navigationAction.navigationType == .linkActivated {
                if url.isFileURL, DocumentFormat.of(url) != nil {
                    openLink(url)
                } else if url.scheme == "http" || url.scheme == "https" {
                    openExternal(url)
                }
                decisionHandler(.cancel)
                return
            }

            // Anything other than displaying this file is refused: the page does
            // not get to navigate itself somewhere else.
            let isThisFile = url.isFileURL
                && url.standardizedFileURL.path == document.url.standardizedFileURL.path
            decisionHandler(isThisFile || url.scheme == "about" ? .allow : .cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url, url.scheme == "http" || url.scheme == "https" {
                openExternal(url)
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            completionHandler()
        }

        // MARK: Reading bridge

        nonisolated func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let payload = message.body as? [String: Any],
                  let viewport = payload["viewport"] as? Double,
                  let rects = payload["rects"] as? [[Double]] else { return }
            Task { @MainActor in
                self.handleFrames(rects: rects, viewportHeight: CGFloat(viewport))
            }
        }

        private func handleFrames(rects: [[Double]], viewportHeight: CGFloat) {
            guard document.tracksReadingProgress,
                  let blocks = document.parsedHTML?.blocks else { return }

            var frames: [String: ReadingScrollTracker.Frame] = [:]
            for rect in rects where rect.count == 3 {
                let ordinal = Int(rect[0])
                guard ordinal >= 0, ordinal < blocks.count else { continue }
                frames[blocks[ordinal].id] = ReadingScrollTracker.Frame(
                    minY: CGFloat(rect[1]),
                    maxY: CGFloat(rect[2])
                )
            }

            let update = tracker.advance(
                blockIDs: blocks.map(\.id),
                frames: frames,
                viewportHeight: viewportHeight
            )
            if !update.read.isEmpty {
                document.markBlocksRead(update.read)
            }

            guard update.atReadingLine != candidateID else { return }
            readingTask?.cancel()
            candidateID = update.atReadingLine
            guard let candidate = update.atReadingLine else { return }
            readingTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(650))
                guard !Task.isCancelled, self.candidateID == candidate else { return }
                self.document.markBlockRead(candidate)
            }
        }

        private static let blockRemoteRules = """
        [{
          "trigger": {
            "url-filter": "^https?://",
            "resource-type": ["document", "image", "style-sheet", "script", "font",
                              "raw", "svg-document", "media", "popup"]
          },
          "action": { "type": "block" }
        }]
        """
    }

    /// Walks the same structural elements the source parser found, in the same
    /// order, and reports where each one sits in the viewport.
    private static let readerScript = """
    (function () {
      var SELECTOR = 'h1,h2,h3,h4,h5,h6,p,pre,blockquote,table,ul,ol,dl,figure,hr,img,canvas,svg,iframe,video,audio,form';
      function blocks() {
        if (!document.body) { return []; }
        var all = Array.prototype.slice.call(document.body.querySelectorAll(SELECTOR));
        return all.filter(function (element) {
          return !element.parentElement || !element.parentElement.closest(SELECTOR);
        });
      }
      var pending = false;
      function report() {
        if (pending) { return; }
        pending = true;
        window.requestAnimationFrame(function () {
          pending = false;
          var list = blocks();
          var rects = [];
          for (var index = 0; index < list.length; index++) {
            var rect = list[index].getBoundingClientRect();
            if (rect.bottom < -3000 || rect.top > window.innerHeight + 3000) { continue; }
            rects.push([index, rect.top, rect.bottom]);
          }
          window.webkit.messageHandlers.marcReader.postMessage({
            viewport: window.innerHeight,
            rects: rects
          });
        });
      }
      window.__marcScrollTo = function (ordinal) {
        var list = blocks();
        if (ordinal >= 0 && ordinal < list.length) {
          list[ordinal].scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      };
      window.addEventListener('scroll', report, { passive: true });
      window.addEventListener('resize', report, { passive: true });
      window.addEventListener('load', report);
      report();
      window.setTimeout(report, 400);
    })();
    """
}
