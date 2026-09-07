import CoreGraphics
import Foundation

/// Turns block positions on screen into reading progress.
///
/// A block is retired once it has been on screen and the reader has then
/// scrolled it above the reading line, so moving quickly through a section
/// still counts as reading it. Blocks that were never displayed are never
/// retired, so jumping into the middle of a document leaves the skipped pages
/// unread, and a document that has not been scrolled at all retires nothing.
/// Sitting on a passage is handled separately, by the caller's dwell rule.
///
/// The same tracker drives Markdown, which reports frames from SwiftUI, and
/// HTML, which reports them from the page itself.
public struct ReadingScrollTracker {
    public struct Frame {
        public let minY: CGFloat
        public let maxY: CGFloat

        public init(minY: CGFloat, maxY: CGFloat) {
            self.minY = minY
            self.maxY = maxY
        }
    }

    public struct Update: Equatable {
        /// Blocks that have now been scrolled past.
        public let read: [String]
        /// The block resting on the reading line, if any, for the dwell rule.
        public let atReadingLine: String?
    }

    /// Fraction of the viewport height where reading is assumed to happen.
    public static let readingLineFraction: CGFloat = 0.55

    private var displayed: Set<String> = []
    private var lastPositions: [String: CGFloat] = [:]

    public init() {}

    public mutating func reset() {
        displayed.removeAll()
        lastPositions.removeAll()
    }

    /// - Parameters:
    ///   - blockIDs: every block of the document, in document order.
    ///   - frames: viewport-relative positions of the blocks currently laid out.
    public mutating func advance(
        blockIDs: [String],
        frames: [String: Frame],
        viewportHeight: CGFloat
    ) -> Update {
        guard viewportHeight > 0 else { return Update(read: [], atReadingLine: nil) }
        let readingLine = viewportHeight * Self.readingLineFraction

        // Passages are retired by moving through them, not by sitting on screen.
        // Without this, opening a short document would mark most of it read
        // before the reader had done anything.
        var scrolled = false
        var newlyDisplayed: Set<String> = []
        var highestPassedIndex = -1
        for (index, id) in blockIDs.enumerated() {
            guard let frame = frames[id] else { continue }
            if let previous = lastPositions[id], abs(previous - frame.minY) > 1 {
                scrolled = true
            }
            if frame.maxY > 0 && frame.minY < viewportHeight {
                newlyDisplayed.insert(id)
            }
            if frame.maxY < readingLine {
                highestPassedIndex = max(highestPassedIndex, index)
            }
        }
        lastPositions = frames.mapValues(\.minY)

        // The furthest block observed above the reading line is the high-water
        // mark. Everything ahead of it has been passed too, including blocks a
        // fast scroll dropped from layout before their last frame arrived --
        // but only blocks that were actually displayed are retired, so pages
        // skipped by an outline jump stay unread.
        var read: [String] = []
        if scrolled, highestPassedIndex >= 0 {
            read = blockIDs[...highestPassedIndex].filter(displayed.contains)
        }

        // Applied after the sweep, so a block is never retired by the same
        // update that first put it on screen.
        displayed.formUnion(newlyDisplayed)

        let atReadingLine = blockIDs.first { id in
            guard let frame = frames[id] else { return false }
            return frame.minY <= readingLine && frame.maxY >= readingLine
        }

        return Update(read: read, atReadingLine: atReadingLine)
    }
}
