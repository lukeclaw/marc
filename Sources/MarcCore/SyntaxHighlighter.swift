import Foundation

public enum SyntaxTokenKind: String, Equatable, Sendable {
    case comment
    case string
    case number
    case keyword
    case type
    case function
    case property
    case annotation
    case literal
    case operatorSymbol
}

public struct SyntaxHighlightSpan: Equatable, Sendable {
    public let location: Int
    public let length: Int
    public let kind: SyntaxTokenKind
}

public struct SyntaxHighlightResult: Equatable, Sendable {
    public let languageName: String?
    public let spans: [SyntaxHighlightSpan]
}

public enum SyntaxHighlighter {
    public static func highlight(_ source: String, language: String?) -> SyntaxHighlightResult {
        let definition = LanguageDefinition.resolve(language) ?? LanguageDefinition.infer(source)
        let scanner = Scanner(source: source, definition: definition)
        return SyntaxHighlightResult(
            languageName: definition.displayName,
            spans: scanner.scan()
        )
    }
}

private struct Scanner {
    let source: NSString
    let definition: LanguageDefinition?
    let length: Int

    init(source: String, definition: LanguageDefinition?) {
        self.source = source as NSString
        self.definition = definition
        self.length = self.source.length
    }

    func scan() -> [SyntaxHighlightSpan] {
        guard length > 0 else { return [] }
        var spans: [SyntaxHighlightSpan] = []
        var index = 0

        while index < length {
            if let span = comment(at: index) {
                spans.append(span)
                index = span.location + span.length
                continue
            }
            if let span = string(at: index) {
                spans.append(span)
                index = span.location + span.length
                continue
            }
            if let span = annotation(at: index) {
                spans.append(span)
                index = span.location + span.length
                continue
            }
            if isNumberStart(at: index), let span = number(at: index) {
                spans.append(span)
                index = span.location + span.length
                continue
            }
            if isIdentifierStart(character(at: index)) {
                if let span = identifier(at: index) {
                    spans.append(span)
                }
                index = identifierEnd(from: index)
                continue
            }
            if isOperator(character(at: index)) {
                let end = operatorEnd(from: index)
                spans.append(
                    SyntaxHighlightSpan(
                        location: index,
                        length: end - index,
                        kind: .operatorSymbol
                    )
                )
                index = end
                continue
            }
            index += 1
        }

        return spans
    }

    private func comment(at index: Int) -> SyntaxHighlightSpan? {
        guard let definition else { return nil }
        for marker in definition.lineComments where hasPrefix(marker, at: index) {
            let end = lineEnd(from: index)
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .comment)
        }
        for pair in definition.blockComments where hasPrefix(pair.open, at: index) {
            let searchStart = index + pair.open.utf16.count
            let closeRange = source.range(
                of: pair.close,
                options: [],
                range: NSRange(location: searchStart, length: length - searchStart)
            )
            let end = closeRange.location == NSNotFound
                ? length
                : closeRange.location + closeRange.length
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .comment)
        }
        return nil
    }

    private func string(at index: Int) -> SyntaxHighlightSpan? {
        let quoteCharacter = character(at: index)
        guard quoteCharacter == "\"" || quoteCharacter == "'" || quoteCharacter == "`" else { return nil }

        let delimiter = String(quoteCharacter)
        let triple = hasPrefix(delimiter + delimiter + delimiter, at: index)
        let delimiterLength = triple ? 3 : 1
        var cursor = index + delimiterLength

        while cursor < length {
            if character(at: cursor) == "\\" {
                cursor = min(length, cursor + 2)
                continue
            }
            if triple, hasPrefix(delimiter + delimiter + delimiter, at: cursor) {
                cursor += 3
                break
            }
            if !triple, character(at: cursor) == quoteCharacter {
                cursor += 1
                break
            }
            cursor += 1
        }

        var kind: SyntaxTokenKind = .string
        if definition?.isDataLanguage == true {
            let next = nextNonWhitespace(after: cursor)
            if next < length, character(at: next) == ":" {
                kind = .property
            }
        }
        return SyntaxHighlightSpan(location: index, length: cursor - index, kind: kind)
    }

    private func annotation(at index: Int) -> SyntaxHighlightSpan? {
        guard character(at: index) == "@", index + 1 < length else { return nil }
        guard isIdentifierStart(character(at: index + 1)) else { return nil }
        let end = identifierEnd(from: index + 1)
        return SyntaxHighlightSpan(location: index, length: end - index, kind: .annotation)
    }

    private func number(at index: Int) -> SyntaxHighlightSpan? {
        var cursor = index
        if character(at: cursor) == "-" { cursor += 1 }
        guard cursor < length else { return nil }

        if cursor + 1 < length,
           character(at: cursor) == "0",
           ["x", "X", "b", "B", "o", "O"].contains(character(at: cursor + 1)) {
            cursor += 2
            while cursor < length, isNumberBody(character(at: cursor)) {
                cursor += 1
            }
        } else {
            while cursor < length, character(at: cursor).isNumber || character(at: cursor) == "_" {
                cursor += 1
            }
            if cursor < length, character(at: cursor) == "." {
                cursor += 1
                while cursor < length, character(at: cursor).isNumber || character(at: cursor) == "_" {
                    cursor += 1
                }
            }
            if cursor < length, character(at: cursor) == "e" || character(at: cursor) == "E" {
                cursor += 1
                if cursor < length, character(at: cursor) == "+" || character(at: cursor) == "-" {
                    cursor += 1
                }
                while cursor < length, character(at: cursor).isNumber || character(at: cursor) == "_" {
                    cursor += 1
                }
            }
            while cursor < length, "fFdDlLuU".contains(character(at: cursor)) {
                cursor += 1
            }
        }
        guard cursor > index else { return nil }
        return SyntaxHighlightSpan(location: index, length: cursor - index, kind: .number)
    }

    private func identifier(at index: Int) -> SyntaxHighlightSpan? {
        let end = identifierEnd(from: index)
        let token = source.substring(with: NSRange(location: index, length: end - index))
        let lookup = definition?.caseInsensitive == true ? token.lowercased() : token

        if definition?.literals.contains(lookup) == true {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .literal)
        }
        if definition?.keywords.contains(lookup) == true {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .keyword)
        }
        if definition?.types.contains(lookup) == true || looksLikeType(token, at: index) {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .type)
        }

        let next = nextNonWhitespace(after: end)
        if next < length, character(at: next) == "(" {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .function)
        }

        let previous = previousNonWhitespace(before: index)
        if previous >= 0, character(at: previous) == "." {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .property)
        }
        if definition?.isDataLanguage == true,
           next < length,
           character(at: next) == ":" || character(at: next) == "=" {
            return SyntaxHighlightSpan(location: index, length: end - index, kind: .property)
        }
        return nil
    }

    private func looksLikeType(_ token: String, at index: Int) -> Bool {
        guard definition?.capitalizedTypes == true, token.count > 1 else { return false }
        guard token.first?.isUppercase == true else { return false }
        let previous = previousNonWhitespace(before: index)
        if previous >= 0, character(at: previous) == "." { return false }
        return token.unicodeScalars.contains { CharacterSet.lowercaseLetters.contains($0) }
    }

    private func identifierEnd(from index: Int) -> Int {
        var cursor = index
        while cursor < length, isIdentifierBody(character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    private func operatorEnd(from index: Int) -> Int {
        var cursor = index
        while cursor < length, isOperator(character(at: cursor)) {
            cursor += 1
        }
        return cursor
    }

    private func lineEnd(from index: Int) -> Int {
        var cursor = index
        while cursor < length, character(at: cursor) != "\n" {
            cursor += 1
        }
        return cursor
    }

    private func nextNonWhitespace(after index: Int) -> Int {
        var cursor = index
        while cursor < length, character(at: cursor).isWhitespace {
            cursor += 1
        }
        return cursor
    }

    private func previousNonWhitespace(before index: Int) -> Int {
        var cursor = index - 1
        while cursor >= 0, character(at: cursor).isWhitespace {
            cursor -= 1
        }
        return cursor
    }

    private func isNumberStart(at index: Int) -> Bool {
        let current = character(at: index)
        if current.isNumber { return true }
        guard current == "-", index + 1 < length, character(at: index + 1).isNumber else {
            return false
        }
        let previous = previousNonWhitespace(before: index)
        return previous < 0 || isOperator(character(at: previous)) || "([{,:;=".contains(character(at: previous))
    }

    private func hasPrefix(_ prefix: String, at index: Int) -> Bool {
        let count = prefix.utf16.count
        guard index + count <= length else { return false }
        return source.substring(with: NSRange(location: index, length: count)) == prefix
    }

    private func character(at index: Int) -> Character {
        let scalar = source.character(at: index)
        return Character(UnicodeScalar(scalar) ?? " ")
    }

    private func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private func isIdentifierBody(_ character: Character) -> Bool {
        isIdentifierStart(character) || character.isNumber
    }

    private func isNumberBody(_ character: Character) -> Bool {
        character.isHexDigit || character == "_" || character == "."
    }

    private func isOperator(_ character: Character) -> Bool {
        "+-*/%=!<>?&|^~:".contains(character)
    }
}

private struct LanguageDefinition {
    let displayName: String
    let keywords: Set<String>
    let types: Set<String>
    let literals: Set<String>
    let lineComments: [String]
    let blockComments: [(open: String, close: String)]
    let caseInsensitive: Bool
    let capitalizedTypes: Bool
    let isDataLanguage: Bool

    static func resolve(_ rawLanguage: String?) -> LanguageDefinition? {
        guard let rawLanguage else { return nil }
        let language = rawLanguage
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .whitespaces)
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: "{}."))
            ?? ""
        if swiftAliases.contains(language) { return swift }
        if kotlinAliases.contains(language) { return kotlin }
        if javaAliases.contains(language) { return java }
        if javascriptAliases.contains(language) { return javascript }
        if typescriptAliases.contains(language) { return typescript }
        if pythonAliases.contains(language) { return python }
        if goAliases.contains(language) { return go }
        if rustAliases.contains(language) { return rust }
        if cAliases.contains(language) { return cFamily }
        if sqlAliases.contains(language) { return sql }
        if shellAliases.contains(language) { return shell }
        if jsonAliases.contains(language) { return json }
        if yamlAliases.contains(language) { return yaml }
        if markupAliases.contains(language) { return markup }
        if cssAliases.contains(language) { return css }
        return generic.withDisplayName(language.isEmpty ? "CODE" : language.uppercased())
    }

    static func infer(_ source: String) -> LanguageDefinition {
        let lowered = source.lowercased()
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)

        if (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
           let data = source.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            return json
        }
        if lowered.contains("select "), lowered.contains(" from ") {
            return sql
        }
        if lowered.contains("import foundation") || lowered.contains("func "), lowered.contains("let ") {
            return swift
        }
        if lowered.contains("package main") || lowered.contains("func main(") {
            return go
        }
        if lowered.contains("fn main(") || lowered.contains("let mut ") {
            return rust
        }
        if lowered.contains("fun main(") || lowered.contains("val "), lowered.contains("package ") {
            return kotlin
        }
        if lowered.contains("public class ") || lowered.contains("system.out.") {
            return java
        }
        if lowered.contains("def "), lowered.contains(":") {
            return python
        }
        if lowered.contains("interface ") || lowered.contains(": string") || lowered.contains(": number") {
            return typescript
        }
        if lowered.contains("const ") || lowered.contains("=>") {
            return javascript
        }
        if trimmed.hasPrefix("#!") || lowered.contains("set -e") {
            return shell
        }
        if trimmed.hasPrefix("<!doctype") || trimmed.hasPrefix("<html") || trimmed.hasPrefix("<?xml") {
            return markup
        }
        return generic
    }

    func withDisplayName(_ name: String) -> LanguageDefinition {
        LanguageDefinition(
            displayName: name,
            keywords: keywords,
            types: types,
            literals: literals,
            lineComments: lineComments,
            blockComments: blockComments,
            caseInsensitive: caseInsensitive,
            capitalizedTypes: capitalizedTypes,
            isDataLanguage: isDataLanguage
        )
    }

    private static let commonLiterals: Set<String> = ["true", "false", "null", "nil", "none", "undefined"]
    private static let swift = definition(
        "SWIFT",
        keywords: "actor any as associatedtype async await borrowing break case catch class consuming continue convenience copy default defer deinit didSet distributed do dynamic each else enum extension fallthrough fileprivate final for func get guard if import indirect init in infix internal isolated lazy let macro mutating nonisolated open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self some static struct subscript super switch throws throwing try typealias unowned var weak where while willSet",
        types: "Any AnyObject Array Bool Character Data Date Dictionary Double Error Float Int Optional Result Set String UInt URL UUID Void",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let kotlin = definition(
        "KOTLIN",
        keywords: "as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external false field file final finally for fun get if import in infix init inline inner interface internal is lateinit noinline null object open operator out override package param private property protected public receiver reified return sealed set setparam suspend tailrec this throw true try typealias typeof val var vararg when where while",
        types: "Any Boolean Byte Char Double Float Int List Long Map Nothing Pair Result Set Short String Unit",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let java = definition(
        "JAVA",
        keywords: "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient try var void volatile while yield",
        types: "BigDecimal BigInteger Boolean Byte Character Class Double Exception Float Integer List Long Map Object Optional Set Short String StringBuilder Throwable UUID",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let javascript = definition(
        "JAVASCRIPT",
        keywords: "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield",
        types: "Array BigInt Boolean Date Error Function Map Number Object Promise RegExp Set String Symbol",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let typescript = definition(
        "TYPESCRIPT",
        keywords: "abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new of private protected public readonly require return set static string super switch symbol this throw try type typeof undefined unique unknown var void while with yield",
        types: "Array BigInt Boolean Date Error Function Map Number Object Promise Record RegExp Set String Symbol",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let python = definition(
        "PYTHON",
        keywords: "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
        types: "Any Callable Dict Exception Iterable List Optional Protocol Set Tuple Type Union",
        lineComments: ["#"],
        blockComments: [],
        capitalizedTypes: true
    )

    private static let go = definition(
        "GO",
        keywords: "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
        types: "any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let rust = definition(
        "RUST",
        keywords: "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while",
        types: "Box Option Result Self String Vec bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let cFamily = definition(
        "C / C++",
        keywords: "alignas alignof asm auto break case catch class const constexpr continue default delete do else enum explicit export extern for friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast return signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual volatile while",
        types: "bool char double float int int16_t int32_t int64_t long size_t string uint16_t uint32_t uint64_t void wchar_t",
        lineComments: ["//"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static let sql = definition(
        "SQL",
        keywords: "all alter and any as asc begin between by case cast check column commit constraint create database default delete desc distinct drop else end exists false foreign from full grant group having in index inner insert intersect into is join left like limit not null on or order outer primary references right rollback row select set table then true union unique update values view when where with",
        types: "bigint binary boolean char date decimal double float int integer interval json numeric real smallint text timestamp varchar",
        lineComments: ["--"],
        blockComments: [("/*", "*/")],
        caseInsensitive: true
    )

    private static let shell = definition(
        "SHELL",
        keywords: "case do done elif else esac export fi for function if in local readonly return set shift then time trap unset until while",
        types: "",
        lineComments: ["#"],
        blockComments: []
    )

    private static let json = definition(
        "JSON",
        keywords: "",
        types: "",
        lineComments: [],
        blockComments: [],
        isDataLanguage: true
    )

    private static let yaml = definition(
        "YAML",
        keywords: "",
        types: "",
        lineComments: ["#"],
        blockComments: [],
        isDataLanguage: true
    )

    private static let markup = definition(
        "HTML / XML",
        keywords: "doctype html head body script style div span section article header footer main nav table tr td th a img form input button",
        types: "",
        lineComments: [],
        blockComments: [("<!--", "-->")],
        isDataLanguage: true
    )

    private static let css = definition(
        "CSS",
        keywords: "color background border display position width height margin padding font grid flex block inline absolute relative fixed inherit initial unset",
        types: "",
        lineComments: [],
        blockComments: [("/*", "*/")],
        isDataLanguage: true
    )

    private static let generic = definition(
        "CODE",
        keywords: "class enum function func import let new return struct type var",
        types: "",
        lineComments: ["//", "#"],
        blockComments: [("/*", "*/")],
        capitalizedTypes: true
    )

    private static func definition(
        _ displayName: String,
        keywords: String,
        types: String,
        lineComments: [String],
        blockComments: [(String, String)],
        caseInsensitive: Bool = false,
        capitalizedTypes: Bool = false,
        isDataLanguage: Bool = false
    ) -> LanguageDefinition {
        LanguageDefinition(
            displayName: displayName,
            keywords: words(keywords, lowercased: caseInsensitive),
            types: words(types, lowercased: caseInsensitive),
            literals: commonLiterals,
            lineComments: lineComments,
            blockComments: blockComments.map { (open: $0.0, close: $0.1) },
            caseInsensitive: caseInsensitive,
            capitalizedTypes: capitalizedTypes,
            isDataLanguage: isDataLanguage
        )
    }

    private static func words(_ source: String, lowercased: Bool) -> Set<String> {
        Set(source.split(separator: " ").map {
            lowercased ? $0.lowercased() : String($0)
        })
    }

    private static let swiftAliases: Set<String> = ["swift"]
    private static let kotlinAliases: Set<String> = ["kt", "kotlin", "kts"]
    private static let javaAliases: Set<String> = ["java"]
    private static let javascriptAliases: Set<String> = ["js", "javascript", "jsx", "node"]
    private static let typescriptAliases: Set<String> = ["ts", "tsx", "typescript"]
    private static let pythonAliases: Set<String> = ["py", "python", "python3"]
    private static let goAliases: Set<String> = ["go", "golang"]
    private static let rustAliases: Set<String> = ["rs", "rust"]
    private static let cAliases: Set<String> = ["c", "cc", "cpp", "c++", "h", "hpp", "objc", "objective-c"]
    private static let sqlAliases: Set<String> = ["sql", "mysql", "postgres", "postgresql", "trino"]
    private static let shellAliases: Set<String> = ["bash", "console", "fish", "shell", "sh", "zsh"]
    private static let jsonAliases: Set<String> = ["json", "json5", "jsonc"]
    private static let yamlAliases: Set<String> = ["yaml", "yml"]
    private static let markupAliases: Set<String> = ["html", "htm", "xml", "svg"]
    private static let cssAliases: Set<String> = ["css", "less", "scss", "sass"]
}
