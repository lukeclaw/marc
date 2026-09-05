import Foundation

/// What an HTML file is shaped like, which decides how much of marc's reading
/// apparatus applies to it.
public enum HTMLDocumentShape: String, Equatable {
    /// A report, write-up, or other page meant to be read top to bottom.
    /// Outline, reading progress, and attention analysis all apply.
    case prose
    /// A dashboard, simulation, or tool. Reading progress is meaningless here,
    /// so it is switched off rather than shown as permanently unread.
    case app
}

/// One structural element of an HTML page.
///
/// `ordinal` is the element's position in document order among the elements
/// marc tracks. The reader bridge walks the live DOM in the same order, so a
/// rect reported for ordinal 7 belongs to this block without needing the page
/// to be rewritten with marc's own identifiers.
public struct HTMLBlock: Identifiable, Equatable, ReadingTrackableBlock {
    public let id: String
    public let signature: String
    public let ordinal: Int
    public let tag: String
    public let text: String
    public let headingLevel: Int?
    public let ancestorHeadingIDs: [String]

    public var sectionID: String? { ancestorHeadingIDs.last }
    public var isReadingTrackable: Bool { tag != "hr" }

    public var readingIdentity: ReadingBlockIdentity {
        ReadingBlockIdentity(id: id, signature: signature, kind: tag, section: sectionID)
    }
}

public struct ParsedHTML: Equatable {
    public let blocks: [HTMLBlock]
    public let headings: [MarkdownHeading]
    public let references: [MarkdownReference]
    public let shape: HTMLDocumentShape
    public let title: String?
    /// Absolute `http`/`https` resources the page asks for. Surfaced so the
    /// reader can decide whether this page is allowed to reach the network.
    public let externalResources: [String]
}

public enum HTMLParser {
    /// Elements that carry reading state and take part in scroll tracking.
    private static let trackedTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6",
        "p", "pre", "blockquote", "table", "ul", "ol", "dl",
        "figure", "hr", "img", "canvas", "svg", "iframe",
        "video", "audio", "form"
    ]

    /// Elements whose contents are not prose and are never descended into.
    private static let opaqueTags: Set<String> = ["script", "style", "template", "noscript"]

    /// Elements that suggest a page is an application rather than a document.
    private static let interactiveTags: Set<String> = [
        "canvas", "svg", "iframe", "form", "input", "button", "select", "textarea", "video", "audio"
    ]

    public static func parse(_ source: String, baseURL: URL? = nil) -> ParsedHTML {
        var blocks: [HTMLBlock] = []
        var headings: [MarkdownHeading] = []
        var references: [MarkdownReference] = []
        var seenReferences: Set<String> = []
        var externalResources: [String] = []
        var seenResources: Set<String> = []
        var slugCounts: [String: Int] = [:]
        var blockIDCounts: [String: Int] = [:]
        var headingStack: [(level: Int, id: String)] = []

        var interactiveCount = 0
        var scriptBytes = 0
        var proseCharacters = 0
        var title: String?

        // Depth of the tracked element currently being collected, if any. While
        // inside one, nested structural elements are part of that block rather
        // than blocks of their own.
        var openBlock: (tag: String, depth: Int, text: String, ordinal: Int)?
        var opaqueTag: String?
        var opaqueStart: String.Index?
        var titleDepth: Int?
        var depth = 0

        var cursor = source.startIndex
        var pendingText = ""

        func flushBlock(_ block: inout (tag: String, depth: Int, text: String, ordinal: Int)?) {
            guard let open = block else { return }
            block = nil
            let text = normalized(open.text)
            let signature = MarkdownParser.stableIdentifier("\(open.tag):\(text)")
            proseCharacters += text.count

            let level = headingLevel(for: open.tag)
            let id: String
            if let level {
                while let last = headingStack.last, last.level >= level {
                    headingStack.removeLast()
                }
                let base = MarkdownParser.slug(text)
                let count = slugCounts[base, default: 0]
                slugCounts[base] = count + 1
                id = count == 0 ? base : "\(base)-\(count + 1)"
            } else {
                let base = "\(open.tag)-\(signature)"
                let count = blockIDCounts[base, default: 0] + 1
                blockIDCounts[base] = count
                id = count == 1 ? base : "\(base)-\(count)"
            }

            blocks.append(
                HTMLBlock(
                    id: id,
                    signature: signature,
                    ordinal: open.ordinal,
                    tag: open.tag,
                    text: text,
                    headingLevel: level,
                    ancestorHeadingIDs: headingStack.map(\.id)
                )
            )

            if let level {
                headings.append(MarkdownHeading(id: id, level: level, title: text))
                headingStack.append((level, id))
            }
        }

        while let open = source[cursor...].firstIndex(of: "<") {
            pendingText = String(source[cursor..<open])
            if openBlock != nil {
                openBlock?.text += pendingText
            } else if titleDepth != nil {
                title = (title ?? "") + pendingText
            }

            guard let close = source[open...].firstIndex(of: ">") else { break }
            let raw = String(source[source.index(after: open)..<close])
            cursor = source.index(after: close)

            if raw.hasPrefix("!") { continue }

            let isClosing = raw.hasPrefix("/")
            let body = isClosing ? String(raw.dropFirst()) : raw
            let name = tagName(body)
            guard !name.isEmpty else { continue }

            if let opaque = opaqueTag {
                if isClosing && name == opaque {
                    if opaque == "script", let start = opaqueStart {
                        scriptBytes += source.distance(from: start, to: open)
                    }
                    opaqueTag = nil
                    opaqueStart = nil
                }
                continue
            }

            if !isClosing && opaqueTags.contains(name) && !isSelfClosing(body) {
                if name == "script" {
                    opaqueStart = cursor
                    collectResource(
                        attribute(body, "src"),
                        into: &externalResources,
                        seen: &seenResources
                    )
                }
                opaqueTag = name
                continue
            }

            if isClosing {
                depth = max(0, depth - 1)
                if name == "title" { titleDepth = nil }
                if let open = openBlock, open.tag == name, depth <= open.depth {
                    flushBlock(&openBlock)
                }
                continue
            }

            let selfClosing = isSelfClosing(body) || isVoid(name)

            if name == "a", let href = attribute(body, "href") {
                addReference(href, baseURL: baseURL, into: &references, seen: &seenReferences)
            }
            for attributeName in ["src", "href"] where name != "a" {
                collectResource(
                    attribute(body, attributeName),
                    into: &externalResources,
                    seen: &seenResources
                )
            }
            if interactiveTags.contains(name) { interactiveCount += 1 }
            if name == "title" && !selfClosing { titleDepth = depth }

            if openBlock == nil && trackedTags.contains(name) {
                let ordinal = blocks.count
                if selfClosing {
                    var standalone: (tag: String, depth: Int, text: String, ordinal: Int)? = (
                        name,
                        depth,
                        attribute(body, "alt") ?? "",
                        ordinal
                    )
                    flushBlock(&standalone)
                } else {
                    openBlock = (name, depth, "", ordinal)
                }
            }

            if !selfClosing { depth += 1 }
        }

        if cursor < source.endIndex, openBlock != nil {
            openBlock?.text += String(source[cursor...])
        }
        flushBlock(&openBlock)

        let headingCount = headings.count
        // A page with real headings and prose reads like a document. Heavy
        // scripting with little text is an application.
        let shape: HTMLDocumentShape = (headingCount >= 2 && proseCharacters >= 400)
            || (headingCount >= 1 && proseCharacters >= 1200 && interactiveCount <= 4)
            ? .prose
            : (scriptBytes > proseCharacters || interactiveCount > 4 ? .app : .prose)

        return ParsedHTML(
            blocks: blocks,
            headings: headings,
            references: references,
            shape: shape,
            title: title.map(normalized).flatMap { $0.isEmpty ? nil : $0 },
            externalResources: externalResources
        )
    }

    private static func headingLevel(for tag: String) -> Int? {
        guard tag.count == 2, tag.hasPrefix("h"), let level = Int(tag.dropFirst()), (1...6).contains(level) else {
            return nil
        }
        return level
    }

    private static func tagName(_ body: String) -> String {
        String(
            body
                .drop { $0 == "/" }
                .prefix { !$0.isWhitespace && $0 != "/" && $0 != ">" }
        ).lowercased()
    }

    private static func isSelfClosing(_ body: String) -> Bool {
        body.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/")
    }

    private static func isVoid(_ name: String) -> Bool {
        ["area", "base", "br", "col", "embed", "hr", "img", "input",
         "link", "meta", "source", "track", "wbr"].contains(name)
    }

    private static func attribute(_ body: String, _ name: String) -> String? {
        let lowered = body.lowercased()
        var search = lowered.startIndex
        while let range = lowered.range(of: name, range: search..<lowered.endIndex) {
            search = range.upperBound
            // Must be a whole attribute name followed by "=".
            let before = range.lowerBound == lowered.startIndex
                ? " "
                : lowered[lowered.index(before: range.lowerBound)]
            guard before.isWhitespace else { continue }
            var index = range.upperBound
            while index < lowered.endIndex, lowered[index].isWhitespace { index = lowered.index(after: index) }
            guard index < lowered.endIndex, lowered[index] == "=" else { continue }
            index = lowered.index(after: index)
            while index < lowered.endIndex, lowered[index].isWhitespace { index = lowered.index(after: index) }
            guard index < lowered.endIndex else { return nil }

            let quote = body[index]
            if quote == "\"" || quote == "'" {
                let start = body.index(after: index)
                guard let end = body[start...].firstIndex(of: quote) else { return nil }
                return String(body[start..<end])
            }
            let value = body[index...].prefix { !$0.isWhitespace && $0 != ">" }
            return value.isEmpty ? nil : String(value)
        }
        return nil
    }

    private static func collectResource(
        _ value: String?,
        into results: inout [String],
        seen: inout Set<String>
    ) {
        guard let value else { return }
        let lowered = value.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("//") else {
            return
        }
        guard seen.insert(value).inserted else { return }
        results.append(value)
    }

    private static func addReference(
        _ href: String,
        baseURL: URL?,
        into results: inout [MarkdownReference],
        seen: inout Set<String>
    ) {
        let path = href.components(separatedBy: "#").first ?? href
        guard !path.isEmpty, !path.hasPrefix("#") else { return }
        let lowered = path.lowercased()
        guard !lowered.contains("://"), !lowered.hasPrefix("//"), !lowered.hasPrefix("mailto:") else { return }
        let decoded = path.removingPercentEncoding ?? path
        guard DocumentFormat.of(extension: (decoded as NSString).pathExtension) != nil else { return }
        guard seen.insert(decoded).inserted else { return }
        results.append(
            MarkdownReference(
                id: decoded,
                label: (decoded as NSString).lastPathComponent,
                destination: href,
                resolvedURL: baseURL?
                    .deletingLastPathComponent()
                    .appendingPathComponent(decoded)
                    .standardizedFileURL
            )
        )
    }

    private static func normalized(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in decodeEntities(text) {
            if character.isWhitespace {
                if !lastWasSpace && !result.isEmpty { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " ")
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement)
        }
        return result
    }
}
