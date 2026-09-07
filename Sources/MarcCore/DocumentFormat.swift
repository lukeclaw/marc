import Foundation

/// The kinds of file marc opens as a document.
///
/// Both are first-class: each gets tabs, an outline, reading progress, per-file
/// presentation, link-graph membership, and external-change handling. They
/// differ only in how their structure is derived and how they are rendered.
public enum DocumentFormat: String, CaseIterable, Codable {
    case markdown
    case html

    public static let markdownExtensions = ["md", "markdown", "mdown", "mkd"]
    public static let htmlExtensions = ["html", "htm", "xhtml"]

    public var fileExtensions: [String] {
        switch self {
        case .markdown: Self.markdownExtensions
        case .html: Self.htmlExtensions
        }
    }

    public var displayName: String {
        switch self {
        case .markdown: "Markdown"
        case .html: "HTML"
        }
    }

    public var defaultExtension: String {
        switch self {
        case .markdown: "md"
        case .html: "html"
        }
    }

    public static func of(extension fileExtension: String) -> DocumentFormat? {
        let lowered = fileExtension.lowercased()
        if markdownExtensions.contains(lowered) { return .markdown }
        if htmlExtensions.contains(lowered) { return .html }
        return nil
    }

    public static func of(_ url: URL) -> DocumentFormat? {
        of(extension: url.pathExtension)
    }

    public static var allExtensions: [String] {
        markdownExtensions + htmlExtensions
    }
}
