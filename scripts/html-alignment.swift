import AppKit
import Foundation
import WebKit

/// Compares the two views marc has of an HTML file.
///
/// `HTMLParser` reads the source. The reader script in `HTMLPreview` walks the
/// rendered DOM. Reading marks only land on the right elements while the two
/// agree, block for block, in the same order. This tool renders the file in the
/// same engine the app uses, walks it with the same selector and filter, and
/// reports where the two disagree.
///
/// With `--write` it also refreshes the snapshots the stress fixtures embed, so
/// their in-page reports keep telling the truth after the files are edited.
@main
struct HTMLAlignment {
    /// The reader script's own selector and filter, kept identical on purpose.
    static let selector = "h1,h2,h3,h4,h5,h6,p,pre,blockquote,table,ul,ol,dl,figure,hr,img,canvas,svg,iframe,video,audio,form"

    static let domScript = """
    (function () {
      var SELECTOR = '\(selector)';
      function tracked(root) {
        return Array.prototype.slice.call(root.querySelectorAll(SELECTOR))
          .filter(function (e) { return !e.parentElement || !e.parentElement.closest(SELECTOR); });
      }
      function textOf(e) {
        return e.tagName.toLowerCase() === 'img' ? (e.getAttribute('alt') || '') : (e.textContent || '');
      }
      var out = { blocks: [], cases: {} };
      tracked(document.body).forEach(function (e) {
        out.blocks.push([e.tagName.toLowerCase(), textOf(e).replace(/\\s+/g, ' ').trim()]);
      });
      var cases = document.querySelectorAll('.case');
      for (var i = 0; i < cases.length; i++) {
        out.cases[cases[i].getAttribute('data-case')] = tracked(cases[i]).map(function (e) {
          return [e.tagName.toLowerCase(), textOf(e).replace(/\\s+/g, ' ').trim()];
        });
      }
      out.headings = document.querySelectorAll('h1,h2,h3,h4,h5,h6').length;
      return out;
    })();
    """

    static func main() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1 else {
            fputs("usage: html-alignment <file.html> [--write]\n", stderr)
            exit(2)
        }
        let url = URL(fileURLWithPath: arguments[1]).standardizedFileURL
        let write = arguments.contains("--write")

        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let runner = Runner(url: url, write: write)
        runner.start()
        application.run()
    }

    /// How many blocks the parser finds in one `.case` region on its own, and
    /// whether that region leaves the parser able to read what follows it.
    /// A region that swallows the sentinel has left the depth counter wrong.
    static func measureCases(in source: String) -> (counts: [String: [(String, String)]], swallowers: [String]) {
        var counts: [String: [(String, String)]] = [:]
        var swallowers: [String] = []
        for (name, body) in caseRegions(in: source) {
            let document = """
            <!doctype html><html><head><title>case</title></head><body>
            <div class="case">
            \(body)
            </div>
            <p>SENTINEL</p>
            </body></html>
            """
            let blocks = HTMLParser.parse(document).blocks
            // A region that swallows the sentinel has left the depth counter
            // wrong, and the sentinel ends up inside its last block.
            let sentinel = blocks.contains { $0.text == "SENTINEL" }
            var kept = sentinel ? blocks.filter { $0.text != "SENTINEL" } : blocks
            if !sentinel, let last = kept.last, last.text.hasSuffix(" SENTINEL") {
                kept[kept.count - 1] = HTMLBlock(
                    id: last.id, signature: last.signature, ordinal: last.ordinal, tag: last.tag,
                    text: String(last.text.dropLast(" SENTINEL".count)),
                    headingLevel: last.headingLevel, ancestorHeadingIDs: last.ancestorHeadingIDs
                )
            }
            counts[name] = kept.map { ($0.tag, $0.text) }
            if !sentinel { swallowers.append(name) }
        }
        return (counts, swallowers)
    }

    /// The body of every `<div class="case" data-case="…">…</div>` region.
    static func caseRegions(in source: String) -> [(String, String)] {
        var regions: [(String, String)] = []
        var search = source.startIndex
        let opening = "<div class=\"case\" data-case=\""
        while let start = source.range(of: opening, range: search..<source.endIndex) {
            guard let nameEnd = source.range(of: "\"", range: start.upperBound..<source.endIndex),
                  let bodyStart = source.range(of: ">", range: nameEnd.upperBound..<source.endIndex),
                  let bodyEnd = source.range(of: "\n</div>\n", range: bodyStart.upperBound..<source.endIndex)
            else { break }
            regions.append((
                String(source[start.upperBound..<nameEnd.lowerBound]),
                String(source[bodyStart.upperBound..<bodyEnd.lowerBound])
            ))
            search = bodyEnd.upperBound
        }
        return regions
    }

    /// Replaces the value that follows a `/* NAME */` marker in the fixture.
    ///
    /// The end of the value is the semicolon that ends the statement, which is
    /// not the first semicolon: the snapshot itself quotes text containing them.
    /// So the scan tracks strings and brackets and stops at the first semicolon
    /// outside both.
    static func substitute(_ marker: String, with value: String, in source: String) -> String {
        let token = "/* \(marker) */ "
        guard let start = source.range(of: token) else { return source }

        var depth = 0
        var inString = false
        var escaped = false
        var index = start.upperBound
        while index < source.endIndex {
            let character = source[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else {
                switch character {
                case "\"": inString = true
                case "[", "{", "(": depth += 1
                case "]", "}", ")": depth -= 1
                case ";" where depth == 0:
                    return source.replacingCharacters(in: start.upperBound..<index, with: value)
                default: break
                }
            }
            index = source.index(after: index)
        }
        return source
    }

    final class Runner: NSObject, WKNavigationDelegate {
        let url: URL
        let write: Bool
        let webView: WKWebView

        init(url: URL, write: Bool) {
            self.url = url
            self.write = write
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 900), configuration: configuration)
            super.init()
            webView.navigationDelegate = self
        }

        func start() {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Give the page's own scripts a moment to build whatever they build.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.compare() }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fputs("load failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }

        private func compare() {
            webView.evaluateJavaScript(HTMLAlignment.domScript) { value, error in
                if let error {
                    fputs("script failed: \(error.localizedDescription)\n", stderr)
                    exit(1)
                }
                guard let payload = value as? [String: Any],
                      let domBlocks = payload["blocks"] as? [[String]],
                      let domHeadings = payload["headings"] as? Int
                else {
                    fputs("unexpected result from the page\n", stderr)
                    exit(1)
                }
                let domCases = payload["cases"] as? [String: Any] ?? [:]
                self.report(domBlocks: domBlocks, domHeadings: domHeadings, domCases: domCases)
                exit(0)
            }
        }

        private func report(domBlocks: [[String]], domHeadings: Int, domCases: [String: Any]) {
            guard var source = try? String(contentsOf: url, encoding: .utf8) else {
                fputs("could not read \(url.path)\n", stderr)
                exit(1)
            }
            let parsed = HTMLParser.parse(source, baseURL: url)
            let sourceBlocks = parsed.blocks

            print(url.lastPathComponent)
            print("  shape        \(parsed.shape.rawValue)")
            print("  title        \(parsed.title ?? "(none)")")
            print("  source       \(sourceBlocks.count) blocks, \(parsed.headings.count) headings")
            print("  DOM          \(domBlocks.count) blocks, \(domHeadings) headings")
            print("  references   \(parsed.references.count)  external \(parsed.externalResources.count)")

            var divergence: String?
            var textDivergences = 0
            for index in 0..<max(sourceBlocks.count, domBlocks.count) {
                let sourceTag = index < sourceBlocks.count ? sourceBlocks[index].tag : "(missing)"
                let domTag = index < domBlocks.count ? domBlocks[index][0] : "(missing)"
                if sourceTag != domTag {
                    divergence = divergence ?? "  diverges     ordinal \(index): source \(sourceTag), DOM \(domTag)"
                    break
                }
                // Same element, different text: the block is identified by
                // something the reader cannot see.
                let sourceText = sourceBlocks[index].text
                if sourceText != domBlocks[index][1] {
                    textDivergences += 1
                    if divergence == nil {
                        divergence = "  diverges     ordinal \(index) has the right element and the wrong text\n"
                            + "               source \(String(sourceText.prefix(60)))\n"
                            + "               DOM    \(String(domBlocks[index][1].prefix(60)))"
                    }
                }
            }
            if let divergence {
                print(divergence)
                if textDivergences > 0 { print("  text         \(textDivergences) blocks differ in text alone") }
            } else if sourceBlocks.count == domBlocks.count {
                print("  aligned      every ordinal points at the same element, with the same text")
            }

            let measured = HTMLAlignment.measureCases(in: source)
            if !measured.counts.isEmpty {
                let diverging = measured.counts.filter { name, value in
                    guard let dom = domCases[name] as? [[String]], dom.count == value.count else { return true }
                    return zip(dom, value).contains { $0[0] != $1.0 || $0[1] != $1.1 }
                }
                print("  cases        \(measured.counts.count) measured, \(diverging.count) diverging"
                    + (diverging.isEmpty ? "" : " (\(diverging.keys.sorted().joined(separator: ", ")))"))
                if !measured.swallowers.isEmpty {
                    print("  swallowers   \(measured.swallowers.sorted().joined(separator: ", "))")
                }
            }

            guard write else { return }
            let snapshot = "[\n" + sourceBlocks.map {
                "  [\(quoted($0.tag)), \(quoted(String($0.text.prefix(40))))]"
            }.joined(separator: ",\n") + "\n]"
            source = HTMLAlignment.substitute("SNAPSHOT", with: snapshot, in: source)
            let cases = "{\n" + measured.counts.sorted { $0.key < $1.key }.map { name, blocks in
                "  \(quoted(name)): [" + blocks.map { "[\(quoted($0.0)), \(quoted($0.1))]" }
                    .joined(separator: ", ") + "]"
            }.joined(separator: ",\n") + "\n}"
            source = HTMLAlignment.substitute("CASE_SNAPSHOT", with: cases, in: source)
            source = HTMLAlignment.substitute("TOTAL_SNAPSHOT", with: "\(sourceBlocks.count)", in: source)
            source = HTMLAlignment.substitute("HEADING_SNAPSHOT", with: "\(parsed.headings.count)", in: source)
            try? source.write(to: url, atomically: true, encoding: .utf8)
            print("  written      snapshots refreshed in place")
        }

        /// A JSON string literal, with everything outside plain ASCII escaped so
        /// the fixture stays readable in any editor.
        private func quoted(_ text: String) -> String {
            var result = "\""
            for scalar in text.unicodeScalars {
                switch scalar {
                case "\"": result += "\\\""
                case "\\": result += "\\\\"
                default:
                    if scalar.value < 0x20 || scalar.value > 0x7e {
                        result += String(format: "\\u%04x", scalar.value)
                    } else {
                        result.unicodeScalars.append(scalar)
                    }
                }
            }
            return result + "\""
        }
    }
}
