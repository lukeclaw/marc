import Foundation

public struct MarkdownHeading: Identifiable, Equatable {
    public let id: String
    public let level: Int
    public let title: String
}

public struct MarkdownReference: Identifiable, Equatable {
    public let id: String
    public let label: String
    public let destination: String
    public let resolvedURL: URL?

    public var exists: Bool {
        guard let resolvedURL else { return false }
        return FileManager.default.fileExists(atPath: resolvedURL.path)
    }
}

public struct MarkdownListItem: Equatable {
    public enum Marker: Equatable {
        case bullet
        case ordered(Int)
        case task(Bool)
    }

    public let level: Int
    public var marker: Marker
    public var text: String
}

public enum MarkdownTableAlignment: Equatable {
    case leading
    case center
    case trailing
}

public struct MarkdownTable: Equatable {
    public let headers: [String]
    public let alignments: [MarkdownTableAlignment]
    public let rows: [[String]]
}

public struct MarkdownBlock: Identifiable, Equatable {
    public enum Kind: Equatable {
        case heading(level: Int, title: String)
        case paragraph(String)
        case list([MarkdownListItem])
        case table(MarkdownTable)
        case blockquote(String)
        case code(language: String?, content: String)
        case horizontalRule
    }

    public let id: String
    public let signature: String
    public let kind: Kind
    public let ancestorHeadingIDs: [String]
}

public struct ParsedMarkdown {
    public let blocks: [MarkdownBlock]
    public let headings: [MarkdownHeading]
    public let references: [MarkdownReference]
}

public enum MarkdownParser {
    public static func parse(_ source: String, baseURL: URL? = nil) -> ParsedMarkdown {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var headings: [MarkdownHeading] = []
        var headingStack: [(level: Int, id: String)] = []
        var slugCounts: [String: Int] = [:]
        var tableIDCounts: [String: Int] = [:]
        var blockIDCounts: [String: Int] = [:]
        var index = 0

        func ancestors() -> [String] { headingStack.map(\.id) }

        func append(_ kind: MarkdownBlock.Kind, id: String? = nil) {
            let signature = stableIdentifier(canonicalBlockContent(kind))
            let blockID: String
            if let id {
                blockID = id
            } else {
                let baseID = "\(blockType(kind))-\(signature)"
                let count = blockIDCounts[baseID, default: 0] + 1
                blockIDCounts[baseID] = count
                blockID = count == 1 ? baseID : "\(baseID)-\(count)"
            }
            blocks.append(
                MarkdownBlock(
                    id: blockID,
                    signature: signature,
                    kind: kind,
                    ancestorHeadingIDs: ancestors()
                )
            )
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                index += 1
                continue
            }

            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                let language = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var codeLines: [String] = []
                index += 1
                while index < lines.count && !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(fence) {
                    codeLines.append(lines[index])
                    index += 1
                }
                if index < lines.count { index += 1 }
                append(.code(language: language.isEmpty ? nil : language, content: codeLines.joined(separator: "\n")))
                continue
            }

            if let heading = parseHeading(trimmed) {
                while let last = headingStack.last, last.level >= heading.level {
                    headingStack.removeLast()
                }
                let baseSlug = slug(heading.title)
                let count = slugCounts[baseSlug, default: 0]
                slugCounts[baseSlug] = count + 1
                let id = count == 0 ? baseSlug : "\(baseSlug)-\(count + 1)"
                let kind = MarkdownBlock.Kind.heading(level: heading.level, title: heading.title)
                let block = MarkdownBlock(
                    id: id,
                    signature: stableIdentifier(canonicalBlockContent(kind)),
                    kind: kind,
                    ancestorHeadingIDs: ancestors()
                )
                blocks.append(block)
                headings.append(MarkdownHeading(id: id, level: heading.level, title: heading.title))
                headingStack.append((heading.level, id))
                index += 1
                continue
            }

            if index + 1 < lines.count,
               let tableHeader = parseTableHeader(lines[index], separator: lines[index + 1]) {
                let baseTableID = "table-\(stableIdentifier(tableHeader.headers.joined(separator: "|")))"
                let tableCount = tableIDCounts[baseTableID, default: 0] + 1
                tableIDCounts[baseTableID] = tableCount
                let tableID = tableCount == 1 ? baseTableID : "\(baseTableID)-\(tableCount)"
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let candidate = lines[index]
                    guard !candidate.trimmingCharacters(in: .whitespaces).isEmpty,
                          candidate.contains("|") else { break }
                    rows.append(normalizedTableRow(candidate, columnCount: tableHeader.headers.count))
                    index += 1
                }
                append(
                    .table(
                        MarkdownTable(
                            headers: tableHeader.headers,
                            alignments: tableHeader.alignments,
                            rows: rows
                        )
                    ),
                    id: tableID
                )
                continue
            }

            if isHorizontalRule(trimmed) {
                append(.horizontalRule)
                index += 1
                continue
            }

            if trimmed.hasPrefix(">") {
                var quoteLines: [String] = []
                while index < lines.count {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    guard candidate.hasPrefix(">") else { break }
                    quoteLines.append(candidate.dropFirst().trimmingCharacters(in: .whitespaces))
                    index += 1
                }
                append(.blockquote(quoteLines.joined(separator: "\n")))
                continue
            }

            if parseListItem(line) != nil {
                var items: [MarkdownListItem] = []
                var orderedCounters: [Int: Int] = [:]

                while index < lines.count {
                    if var item = parseListItem(lines[index]) {
                        orderedCounters = orderedCounters.filter { $0.key <= item.level }
                        switch item.marker {
                        case let .ordered(sourceNumber):
                            let number = orderedCounters[item.level].map { $0 + 1 } ?? sourceNumber
                            orderedCounters[item.level] = number
                            item.marker = .ordered(number)
                        case .bullet, .task:
                            orderedCounters[item.level] = nil
                        }
                        items.append(item)
                        index += 1
                        continue
                    }

                    let continuation = lines[index]
                    let continuationText = continuation.trimmingCharacters(in: .whitespaces)
                    if continuationText.isEmpty {
                        if index + 1 < lines.count, parseListItem(lines[index + 1]) != nil {
                            index += 1
                            continue
                        }
                        break
                    }

                    guard
                        !items.isEmpty,
                        indentationWidth(of: continuation) > items[items.count - 1].level * 3,
                        !beginsBlock(continuationText)
                    else { break }
                    items[items.count - 1].text += "\n\(continuationText)"
                    index += 1
                }

                append(.list(items))
                continue
            }

            var paragraph: [String] = [trimmed]
            index += 1
            while index < lines.count {
                let next = lines[index].trimmingCharacters(in: .whitespaces)
                if next.isEmpty {
                    index += 1
                    break
                }
                if beginsBlock(next) { break }
                paragraph.append(next)
                index += 1
            }
            append(.paragraph(paragraph.joined(separator: "\n")))
        }

        return ParsedMarkdown(
            blocks: blocks,
            headings: headings,
            references: references(in: normalized, baseURL: baseURL)
        )
    }

    private static func parseHeading(_ line: String) -> (level: Int, title: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let title = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return (hashes, title)
    }

    private static func slug(_ title: String) -> String {
        let lowered = title.lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
        }
        let compact = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return compact.isEmpty ? "section" : compact
    }

    private static func stableIdentifier(_ source: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in source.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func blockType(_ kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case .heading: "heading"
        case .paragraph: "paragraph"
        case .list: "list"
        case .table: "table"
        case .blockquote: "quote"
        case .code: "code"
        case .horizontalRule: "rule"
        }
    }

    private static func canonicalBlockContent(_ kind: MarkdownBlock.Kind) -> String {
        switch kind {
        case let .heading(level, title):
            return "h\(level):\(normalizedProse(title))"
        case let .paragraph(text):
            return normalizedProse(text)
        case let .list(items):
            return items.map { item in
                let marker: String
                switch item.marker {
                case .bullet: marker = "bullet"
                case let .ordered(number): marker = "ordered:\(number)"
                case let .task(checked): marker = "task:\(checked)"
                }
                return "\(item.level):\(marker):\(normalizedProse(item.text))"
            }.joined(separator: "\n")
        case let .table(table):
            return ([table.headers] + table.rows)
                .map { $0.map(normalizedProse).joined(separator: "|") }
                .joined(separator: "\n")
        case let .blockquote(text):
            return normalizedProse(text)
        case let .code(language, content):
            return "\(language ?? "")\n\(content)"
        case .horizontalRule:
            return "horizontal-rule"
        }
    }

    private static func normalizedProse(_ source: String) -> String {
        source.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func isHorizontalRule(_ line: String) -> Bool {
        let compact = line.replacingOccurrences(of: " ", with: "")
        return compact.count >= 3 &&
            (Set(compact) == Set(["-"]) || Set(compact) == Set(["*"]) || Set(compact) == Set(["_"]))
    }

    private static func parseListItem(_ line: String) -> MarkdownListItem? {
        let indentation = indentationWidth(of: line)
        let content = line.drop { $0 == " " || $0 == "\t" }
        let level = indentation / 3

        for prefix in ["- [ ] ", "* [ ] ", "+ [ ] ", "- [x] ", "- [X] ", "* [x] ", "* [X] ", "+ [x] ", "+ [X] "]
        where content.hasPrefix(prefix) {
            return MarkdownListItem(
                level: level,
                marker: .task(prefix.lowercased().contains("[x]")),
                text: String(content.dropFirst(prefix.count))
            )
        }

        for prefix in ["- ", "* ", "+ "] where content.hasPrefix(prefix) {
            return MarkdownListItem(
                level: level,
                marker: .bullet,
                text: String(content.dropFirst(prefix.count))
            )
        }

        guard let dot = content.firstIndex(of: ".") else { return nil }
        let numberText = content[..<dot]
        guard let number = Int(numberText), number > 0 else { return nil }
        let afterDot = content.index(after: dot)
        guard afterDot < content.endIndex, content[afterDot] == " " else { return nil }
        return MarkdownListItem(
            level: level,
            marker: .ordered(number),
            text: String(content[content.index(after: afterDot)...])
        )
    }

    private static func indentationWidth(of line: String) -> Int {
        line.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
    }

    private static func beginsBlock(_ line: String) -> Bool {
        parseHeading(line) != nil ||
            line.hasPrefix("```") ||
            line.hasPrefix("~~~") ||
            line.hasPrefix(">") ||
            parseListItem(line) != nil ||
            isHorizontalRule(line)
    }

    private static func parseTableHeader(
        _ headerLine: String,
        separator separatorLine: String
    ) -> (headers: [String], alignments: [MarkdownTableAlignment])? {
        guard headerLine.contains("|"), separatorLine.contains("|") else { return nil }
        let headers = splitTableRow(headerLine)
        let separators = splitTableRow(separatorLine)
        guard !headers.isEmpty, headers.count == separators.count else { return nil }

        var alignments: [MarkdownTableAlignment] = []
        for separator in separators {
            let cell = separator.trimmingCharacters(in: .whitespaces)
            let startsWithColon = cell.hasPrefix(":")
            let endsWithColon = cell.hasSuffix(":")
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard dashes.count >= 3, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            if startsWithColon && endsWithColon {
                alignments.append(.center)
            } else if endsWithColon {
                alignments.append(.trailing)
            } else {
                alignments.append(.leading)
            }
        }
        return (headers, alignments)
    }

    private static func normalizedTableRow(_ line: String, columnCount: Int) -> [String] {
        var cells = splitTableRow(line)
        if cells.count < columnCount {
            cells.append(contentsOf: repeatElement("", count: columnCount - cells.count))
        }
        return Array(cells.prefix(columnCount))
    }

    private static func splitTableRow(_ line: String) -> [String] {
        var content = line.trimmingCharacters(in: .whitespaces)
        if content.hasPrefix("|") { content.removeFirst() }
        if content.hasSuffix("|") { content.removeLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in content {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    private static func references(in source: String, baseURL: URL?) -> [MarkdownReference] {
        var results: [MarkdownReference] = []
        var seen: Set<String> = []

        let inlinePattern = #"\[([^\]]+)\]\(([^)\s]+(?:\.md|\.markdown)(?:#[^)]*)?)\)"#
        if let regex = try? NSRegularExpression(pattern: inlinePattern, options: [.caseInsensitive]) {
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard
                    let labelRange = Range(match.range(at: 1), in: source),
                    let destinationRange = Range(match.range(at: 2), in: source)
                else { continue }
                addReference(
                    label: String(source[labelRange]),
                    destination: String(source[destinationRange]),
                    baseURL: baseURL,
                    results: &results,
                    seen: &seen
                )
            }
        }

        let wikiPattern = #"\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]"#
        if let regex = try? NSRegularExpression(pattern: wikiPattern) {
            let range = NSRange(source.startIndex..., in: source)
            for match in regex.matches(in: source, range: range) {
                guard let targetRange = Range(match.range(at: 1), in: source) else { continue }
                let target = String(source[targetRange]).trimmingCharacters(in: .whitespaces)
                let label: String
                if match.range(at: 2).location != NSNotFound,
                   let labelRange = Range(match.range(at: 2), in: source) {
                    label = String(source[labelRange])
                } else {
                    label = target
                }
                let destination = target.lowercased().hasSuffix(".md") ? target : "\(target).md"
                addReference(
                    label: label,
                    destination: destination,
                    baseURL: baseURL,
                    results: &results,
                    seen: &seen
                )
            }
        }

        return results
    }

    private static func addReference(
        label: String,
        destination: String,
        baseURL: URL?,
        results: inout [MarkdownReference],
        seen: inout Set<String>
    ) {
        let path = destination.removingPercentEncoding?
            .components(separatedBy: "#").first ?? destination
        guard !path.isEmpty, seen.insert(path).inserted else { return }
        let resolvedURL = baseURL?
            .deletingLastPathComponent()
            .appendingPathComponent(path)
            .standardizedFileURL
        results.append(
            MarkdownReference(
                id: path,
                label: label,
                destination: destination,
                resolvedURL: resolvedURL
            )
        )
    }
}
