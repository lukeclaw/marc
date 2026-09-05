import Foundation

/// A unit of a document that reading progress can be recorded against.
///
/// Markdown blocks and HTML elements both conform, so unread and updated
/// tracking, outline badges, and the reading status strip work the same way
/// whichever kind of document is open.
public protocol ReadingTrackableBlock {
    var id: String { get }
    var signature: String { get }
    var readingIdentity: ReadingBlockIdentity { get }
    /// Decorative content, such as a rule or a spacer, carries no reading state.
    var isReadingTrackable: Bool { get }
}

extension MarkdownBlock: ReadingTrackableBlock {
    public var isReadingTrackable: Bool {
        if case .horizontalRule = kind { return false }
        return true
    }
}
