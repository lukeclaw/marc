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

    /// Elements whose content is text rather than markup. A `<` inside one of
    /// them opens nothing, which is why a comparison in a script and a pasted
    /// tag in a `textarea` stay out of the block list.
    fileprivate static let rawTextTags: Set<String> = [
        "script", "style", "template", "noscript", "title", "textarea"
    ]

    /// Raw-text elements whose content the rendered page does not show. Their
    /// text is neither prose nor block content: a template's content lives in a
    /// fragment the reader script never walks, and a `noscript` is inert while
    /// scripts are on.
    private static let unrenderedTags: Set<String> = ["script", "style", "template", "noscript"]

    /// Elements with no content and no end tag.
    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr"
    ]

    /// Elements that suggest a page is an application rather than a document.
    private static let interactiveTags: Set<String> = [
        "canvas", "svg", "iframe", "form", "input", "button", "select", "textarea", "video", "audio"
    ]

    /// Elements whose subtree is not HTML, where a trailing slash really does
    /// close the element.
    private static let foreignTags: Set<String> = ["svg", "math"]

    /// The elements whose start tag closes an open paragraph.
    private static let blockLevelTags: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog",
        "dir", "div", "dl", "dd", "dt", "fieldset", "figcaption", "figure", "footer",
        "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "li",
        "main", "menu", "nav", "ol", "p", "pre", "search", "section", "summary",
        "table", "ul", "xmp"
    ]

    /// Which start tags close an element that is still open, which is how HTML
    /// lets one `<li>` follow another, or a paragraph end at the next heading,
    /// without anyone writing an end tag. Reading these the way a browser does
    /// is what keeps a block from swallowing the rest of the file.
    private static let closedByStartOf: [String: Set<String>] = [
        "p": blockLevelTags,
        "li": ["li"],
        "dt": ["dt", "dd"],
        "dd": ["dt", "dd"],
        "option": ["option", "optgroup"],
        "optgroup": ["optgroup"],
        "thead": ["tbody", "tfoot"],
        "tbody": ["tbody", "tfoot"],
        "tfoot": ["tbody", "thead"],
        "tr": ["tr", "tbody", "tfoot", "thead"],
        "td": ["td", "th", "tr", "tbody", "tfoot", "thead"],
        "th": ["td", "th", "tr", "tbody", "tfoot", "thead"],
        "rt": ["rt", "rp"],
        "rp": ["rt", "rp"]
    ]

    /// One element the parser is inside. Only the root of a foreign subtree
    /// counts as one, so that closing an element inside an `<svg>` does not
    /// report that the subtree has ended.
    private struct OpenElement {
        let name: String
        let isForeignRoot: Bool
    }

    /// A block being collected, and where its element sits on the open-element
    /// stack. The block ends when that element is popped, whoever pops it.
    private struct OpenBlock {
        let tag: String
        let stackIndex: Int
        let ordinal: Int
        var text: String
    }

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
        var scriptCharacters = 0
        var proseCharacters = 0
        var title: String?

        var openElements: [OpenElement] = []
        var openBlock: OpenBlock?
        var foreignDepth = 0
        /// The raw-text element whose content the next text token carries.
        var rawTextOwner: String?

        /// Records a block for `tag` with the text collected for it.
        func appendBlock(tag: String, text: String, ordinal: Int) {
            let text = normalized(text)
            let signature = MarkdownParser.stableIdentifier("\(tag):\(text)")
            proseCharacters += text.count

            let level = headingLevel(for: tag)
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
                let base = "\(tag)-\(signature)"
                let count = blockIDCounts[base, default: 0] + 1
                blockIDCounts[base] = count
                id = count == 1 ? base : "\(base)-\(count)"
            }

            blocks.append(
                HTMLBlock(
                    id: id,
                    signature: signature,
                    ordinal: ordinal,
                    tag: tag,
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

        func flushOpenBlock() {
            guard let block = openBlock else { return }
            openBlock = nil
            appendBlock(tag: block.tag, text: block.text, ordinal: block.ordinal)
        }

        /// Closes the innermost open element, and with it any block that began
        /// at or inside it.
        func popElement() {
            guard !openElements.isEmpty else { return }
            let removed = openElements.removeLast()
            if removed.isForeignRoot { foreignDepth -= 1 }
            if let block = openBlock, block.stackIndex >= openElements.count {
                flushOpenBlock()
            }
        }

        var tokenizer = Tokenizer(source)
        while let token = tokenizer.next() {
            switch token {
            case let .text(text):
                if let owner = rawTextOwner {
                    rawTextOwner = nil
                    if owner == "script" { scriptCharacters += text.count }
                    if unrenderedTags.contains(owner) { continue }
                    if owner == "title", openBlock == nil, foreignDepth == 0 {
                        title = (title ?? "") + text
                        continue
                    }
                }
                if openBlock != nil { openBlock?.text += text }

            case let .start(name, attributes, selfClosing):
                // A start tag can close elements that are still open, exactly as
                // it does in a browser. This runs first, so a block that ends
                // here is finished before the next one begins.
                if foreignDepth == 0 {
                    while let top = openElements.last,
                          let closers = closedByStartOf[top.name], closers.contains(name) {
                        popElement()
                    }
                }

                if name == "a" {
                    if let href = attributes["href"] {
                        addReference(href, baseURL: baseURL, into: &references, seen: &seenReferences)
                    }
                } else {
                    for attributeName in ["src", "href"] {
                        collectResource(
                            attributes[attributeName],
                            into: &externalResources,
                            seen: &seenResources
                        )
                    }
                }
                if interactiveTags.contains(name) { interactiveCount += 1 }

                let isForeignRoot = foreignTags.contains(name)
                let isForeign = foreignDepth > 0 || isForeignRoot
                // A trailing slash closes a foreign element. On an HTML element
                // it means nothing, which is why `<div/>` stays open.
                let closesItself = (voidTags.contains(name) && !isForeign) || (selfClosing && isForeign)

                if openBlock == nil && trackedTags.contains(name) {
                    if closesItself {
                        appendBlock(tag: name, text: attributes["alt"] ?? "", ordinal: blocks.count)
                    } else {
                        openBlock = OpenBlock(
                            tag: name,
                            stackIndex: openElements.count,
                            ordinal: blocks.count,
                            text: ""
                        )
                    }
                }

                if !closesItself {
                    openElements.append(OpenElement(name: name, isForeignRoot: isForeignRoot))
                    if isForeignRoot { foreignDepth += 1 }
                    // Kept in step with the tokenizer, which decides on the same
                    // terms whether the next token is content or markup.
                    if !selfClosing, rawTextTags.contains(name) { rawTextOwner = name }
                }

            case let .end(name):
                if let index = openElements.lastIndex(where: { $0.name == name }) {
                    while openElements.count > index { popElement() }
                } else if name == "p", foreignDepth == 0, openBlock == nil {
                    // A browser answers a stray `</p>` with an empty paragraph,
                    // so the rendered page has a block the source does not show.
                    appendBlock(tag: "p", text: "", ordinal: blocks.count)
                }
            }
        }

        while !openElements.isEmpty { popElement() }
        flushOpenBlock()

        let headingCount = headings.count
        // A page with real headings and prose reads like a document. Heavy
        // scripting with little text is an application.
        let shape: HTMLDocumentShape = (headingCount >= 2 && proseCharacters >= 400)
            || (headingCount >= 1 && proseCharacters >= 1200 && interactiveCount <= 4)
            ? .prose
            : (scriptCharacters > proseCharacters || interactiveCount > 4 ? .app : .prose)

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

    /// Decodes entity references in one pass.
    ///
    /// One pass is the point. Substituting each entity in turn over the whole
    /// string would hand the next substitution the text the last one produced,
    /// so `&amp;lt;` — which a page writes to show `&lt;` — would come out as a
    /// real `<` that the reader never saw.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        result.reserveCapacity(text.count)
        var index = text.startIndex

        while let ampersand = text[index...].firstIndex(of: "&") {
            result.append(contentsOf: text[index..<ampersand])
            let afterAmpersand = text.index(after: ampersand)
            // Nothing longer than the longest name can be a reference.
            let limit = text.index(afterAmpersand, offsetBy: 33, limitedBy: text.endIndex) ?? text.endIndex
            if let semicolon = text[afterAmpersand..<limit].firstIndex(of: ";"),
               let decoded = decodeReference(String(text[afterAmpersand..<semicolon])) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append("&")
                index = afterAmpersand
            }
        }

        result.append(contentsOf: text[index...])
        return result
    }

    /// One entity reference, given without its `&` and `;`.
    private static func decodeReference(_ reference: String) -> String? {
        guard !reference.isEmpty else { return nil }
        guard reference.hasPrefix("#") else { return namedEntities[reference] }

        let digits = reference.dropFirst()
        let value: UInt32?
        if digits.hasPrefix("x") || digits.hasPrefix("X") {
            value = UInt32(digits.dropFirst(), radix: 16)
        } else {
            value = UInt32(digits, radix: 10)
        }
        guard let value, let scalar = Unicode.Scalar(value) else { return nil }
        return String(Character(scalar))
    }

    /// The named references a page is likely to use. A name that is not here is
    /// left as it was written rather than guessed at.
    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "deg": "°", "sect": "§", "para": "¶",
        "middot": "·", "bull": "•", "dagger": "†", "Dagger": "‡", "hellip": "…",
        "ndash": "–", "mdash": "—", "minus": "−", "times": "×", "divide": "÷",
        "plusmn": "±", "frac12": "½", "frac14": "¼", "frac34": "¾", "permil": "‰",
        "prime": "′", "Prime": "″", "lsquo": "‘", "rsquo": "’", "sbquo": "‚",
        "ldquo": "“", "rdquo": "”", "bdquo": "„", "laquo": "«", "raquo": "»",
        "lsaquo": "‹", "rsaquo": "›", "larr": "←", "uarr": "↑", "rarr": "→",
        "darr": "↓", "harr": "↔", "crarr": "↵", "lArr": "⇐", "rArr": "⇒",
        "hArr": "⇔", "infin": "∞", "ne": "≠", "le": "≤", "ge": "≥", "asymp": "≈",
        "equiv": "≡", "sum": "∑", "prod": "∏", "radic": "√", "int": "∫",
        "part": "∂", "micro": "µ", "alpha": "α", "beta": "β", "gamma": "γ",
        "delta": "δ", "epsilon": "ε", "theta": "θ", "lambda": "λ", "mu": "μ",
        "pi": "π", "sigma": "σ", "tau": "τ", "phi": "φ", "omega": "ω",
        "Delta": "Δ", "Sigma": "Σ", "Omega": "Ω", "euro": "€", "pound": "£",
        "yen": "¥", "cent": "¢", "curren": "¤", "iexcl": "¡", "iquest": "¿",
        "aacute": "á", "eacute": "é", "iacute": "í", "oacute": "ó", "uacute": "ú",
        "agrave": "à", "egrave": "è", "igrave": "ì", "ograve": "ò", "ugrave": "ù",
        "acirc": "â", "ecirc": "ê", "icirc": "î", "ocirc": "ô", "ucirc": "û",
        "auml": "ä", "euml": "ë", "iuml": "ï", "ouml": "ö", "uuml": "ü",
        "atilde": "ã", "ntilde": "ñ", "otilde": "õ", "aring": "å", "aelig": "æ",
        "oslash": "ø", "ccedil": "ç", "szlig": "ß", "Aacute": "Á", "Eacute": "É",
        "Iacute": "Í", "Oacute": "Ó", "Uacute": "Ú", "Auml": "Ä", "Ouml": "Ö",
        "Uuml": "Ü", "Ntilde": "Ñ", "Ccedil": "Ç", "shy": "\u{00AD}",
        "ensp": "\u{2002}", "emsp": "\u{2003}", "thinsp": "\u{2009}",
        "zwnj": "\u{200C}", "zwj": "\u{200D}", "lrm": "\u{200E}", "rlm": "\u{200F}"
    ]
}

extension HTMLParser {
    /// One piece of an HTML source file.
    fileprivate enum Token {
        case text(String)
        case start(name: String, attributes: [String: String], selfClosing: Bool)
        case end(name: String)
    }

    /// Walks HTML source and hands back its tags and its text.
    ///
    /// This is not a conforming HTML tokenizer, but it agrees with one wherever
    /// the difference would move a block boundary or change a block's text: an
    /// attribute value may hold a `>` without ending its tag, a comment runs to
    /// `-->` rather than to the first `>`, a `<` that begins no tag is text, and
    /// the content of a script or a textarea is text rather than markup.
    fileprivate struct Tokenizer {
        private let source: String
        private var index: String.Index
        /// Set when the last tag opened an element whose content is text, so the
        /// next token is that content however much it looks like markup.
        private var rawTextTag: String?

        init(_ source: String) {
            self.source = source
            index = source.startIndex
        }

        mutating func next() -> Token? {
            while index < source.endIndex {
                if let tag = rawTextTag {
                    rawTextTag = nil
                    return .text(readRawText(closing: tag))
                }
                if source[index] == "<", beginsTag(at: index) {
                    if let token = readTag() { return token }
                    continue
                }
                let text = readText()
                if !text.isEmpty { return .text(text) }
            }
            return nil
        }

        /// Whether the `<` at `position` opens a tag, a comment, or a
        /// declaration. A `<` followed by anything else is an ordinary
        /// character, which is how prose gets away with `5 < 6`.
        private func beginsTag(at position: String.Index) -> Bool {
            let after = source.index(after: position)
            guard after < source.endIndex else { return false }
            let character = source[after]
            if character == "!" || character == "?" { return true }
            if character == "/" {
                let second = source.index(after: after)
                return second < source.endIndex && source[second].isLetter
            }
            return character.isLetter
        }

        private mutating func readText() -> String {
            var text = ""
            while index < source.endIndex {
                if source[index] == "<", beginsTag(at: index) { break }
                text.append(source[index])
                index = source.index(after: index)
            }
            return text
        }

        /// Reads one tag. Returns nothing for a comment or a declaration, which
        /// are consumed but have nothing to report.
        private mutating func readTag() -> Token? {
            index = source.index(after: index)
            guard index < source.endIndex else { return nil }

            if source[index] == "!" {
                if source[index...].hasPrefix("!--") {
                    skip(past: "-->")
                } else if source[index...].uppercased().hasPrefix("![CDATA[") {
                    skip(past: "]]>")
                } else {
                    skip(past: ">")
                }
                return nil
            }
            if source[index] == "?" {
                skip(past: ">")
                return nil
            }

            var isEnd = false
            if source[index] == "/" {
                isEnd = true
                index = source.index(after: index)
            }

            let name = readName()
            guard !name.isEmpty else {
                skip(past: ">")
                return nil
            }

            var attributes: [String: String] = [:]
            var selfClosing = false
            while index < source.endIndex {
                skipWhitespace()
                guard index < source.endIndex else { break }
                if source[index] == ">" {
                    index = source.index(after: index)
                    break
                }
                if source[index] == "/" {
                    index = source.index(after: index)
                    if index < source.endIndex, source[index] == ">" {
                        selfClosing = true
                        index = source.index(after: index)
                        break
                    }
                    continue
                }
                let attribute = readName()
                guard !attribute.isEmpty else {
                    index = source.index(after: index)
                    continue
                }
                skipWhitespace()
                var value = ""
                if index < source.endIndex, source[index] == "=" {
                    index = source.index(after: index)
                    skipWhitespace()
                    value = readAttributeValue()
                }
                if attributes[attribute] == nil { attributes[attribute] = value }
            }

            if isEnd { return .end(name: name) }
            if !selfClosing, HTMLParser.rawTextTags.contains(name) { rawTextTag = name }
            return .start(name: name, attributes: attributes, selfClosing: selfClosing)
        }

        /// A tag or attribute name, lowercased, as HTML is not case-sensitive
        /// about either.
        private mutating func readName() -> String {
            var name = ""
            while index < source.endIndex {
                let character = source[index]
                if character.isWhitespace || character == "=" || character == "/" || character == ">" {
                    break
                }
                name.append(character)
                index = source.index(after: index)
            }
            return name.lowercased()
        }

        private mutating func readAttributeValue() -> String {
            guard index < source.endIndex else { return "" }
            let quote = source[index]
            if quote == "\"" || quote == "'" {
                index = source.index(after: index)
                var value = ""
                while index < source.endIndex, source[index] != quote {
                    value.append(source[index])
                    index = source.index(after: index)
                }
                if index < source.endIndex { index = source.index(after: index) }
                return value
            }
            var value = ""
            while index < source.endIndex, !source[index].isWhitespace, source[index] != ">" {
                value.append(source[index])
                index = source.index(after: index)
            }
            return value
        }

        /// The content of a raw-text element, up to its own end tag.
        private mutating func readRawText(closing name: String) -> String {
            var search = index
            while let opening = source.range(of: "</", range: search..<source.endIndex) {
                let candidate = source[opening.upperBound...].prefix(name.count)
                if candidate.lowercased() == name {
                    let after = source.index(opening.upperBound, offsetBy: name.count, limitedBy: source.endIndex)
                        ?? source.endIndex
                    let ends = after == source.endIndex
                        || source[after].isWhitespace || source[after] == ">" || source[after] == "/"
                    if ends {
                        let text = String(source[index..<opening.lowerBound])
                        index = opening.lowerBound
                        return text
                    }
                }
                search = opening.upperBound
            }
            let text = String(source[index...])
            index = source.endIndex
            return text
        }

        private mutating func skipWhitespace() {
            while index < source.endIndex, source[index].isWhitespace {
                index = source.index(after: index)
            }
        }

        private mutating func skip(past terminator: String) {
            if let range = source.range(of: terminator, range: index..<source.endIndex) {
                index = range.upperBound
            } else {
                index = source.endIndex
            }
        }
    }
}
