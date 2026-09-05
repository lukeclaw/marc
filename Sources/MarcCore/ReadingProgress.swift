import Foundation

/// A block's identity as recorded in a reading-state baseline.
///
/// `id` is content-derived for most block kinds, so it survives insertions
/// elsewhere in the document but changes whenever the block itself is edited.
/// `kind` and `section` let an edited block be recognized as a revision of the
/// block that stood in its place rather than as unrelated new content.
public struct ReadingBlockIdentity: Equatable {
    public let id: String
    public let signature: String
    public let kind: String?
    public let section: String?

    public init(id: String, signature: String, kind: String? = nil, section: String? = nil) {
        self.id = id
        self.signature = signature
        self.kind = kind
        self.section = section
    }

    /// Two identities may describe the same passage before and after an edit.
    /// A paragraph is never treated as a revision of a table, and a block is
    /// never paired across headings.
    func couldBeRevision(of other: ReadingBlockIdentity) -> Bool {
        if let kind, let otherKind = other.kind, kind != otherKind { return false }
        if let section, let otherSection = other.section, section != otherSection { return false }
        return true
    }
}

public enum ReadingBlockChange: Equatable {
    /// Present in both revisions with the same identity.
    case unchanged(id: String)
    /// An edited version of a block that was previously in the same place.
    case revised(id: String, previousID: String)
    /// Content with no counterpart in the previous revision.
    case inserted(id: String)
}

public enum ReadingAlignment {
    /// Largest problem size worth aligning exactly. Past this the middle is
    /// paired positionally, which is what a wholesale rewrite deserves anyway.
    private static let exactLimit = 600

    /// Matches a previous block list against the current one so that an edit is
    /// reported as a revision of a known passage instead of brand-new content.
    public static func align(
        previous: [ReadingBlockIdentity],
        current: [ReadingBlockIdentity]
    ) -> [ReadingBlockChange] {
        // Ordinary typing changes one block, so trimming the matching head and
        // tail usually reduces the alignment to a couple of entries.
        var head = 0
        while head < previous.count, head < current.count, previous[head].id == current[head].id {
            head += 1
        }
        var tail = 0
        while tail < previous.count - head,
              tail < current.count - head,
              previous[previous.count - 1 - tail].id == current[current.count - 1 - tail].id {
            tail += 1
        }

        let previousMiddle = Array(previous[head..<(previous.count - tail)])
        let currentMiddle = Array(current[head..<(current.count - tail)])

        var changes: [ReadingBlockChange] = []
        changes.reserveCapacity(current.count)
        changes.append(contentsOf: current[0..<head].map { .unchanged(id: $0.id) })
        changes.append(contentsOf: alignMiddle(previous: previousMiddle, current: currentMiddle))
        changes.append(contentsOf: current[(current.count - tail)...].map { .unchanged(id: $0.id) })
        return changes
    }

    private static func alignMiddle(
        previous: [ReadingBlockIdentity],
        current: [ReadingBlockIdentity]
    ) -> [ReadingBlockChange] {
        guard !current.isEmpty else { return [] }
        guard !previous.isEmpty else {
            return current.map { .inserted(id: $0.id) }
        }

        let anchors = previous.count * current.count <= exactLimit * exactLimit
            ? commonSubsequence(previous: previous, current: current)
            : [:]

        let anchoredPrevious = Set(anchors.values)
        var changes: [ReadingBlockChange] = []
        var usedPrevious = Set<Int>()
        var previousCursor = 0

        for (index, block) in current.enumerated() {
            if let anchor = anchors[index] {
                changes.append(.unchanged(id: block.id))
                usedPrevious.insert(anchor)
                previousCursor = anchor + 1
                continue
            }

            // Pair with the nearest unclaimed previous block that could plausibly
            // be the same passage, searching forward from the last anchor.
            var match: Int?
            var candidate = previousCursor
            while candidate < previous.count {
                if !usedPrevious.contains(candidate),
                   !anchoredPrevious.contains(candidate),
                   block.couldBeRevision(of: previous[candidate]) {
                    match = candidate
                    break
                }
                candidate += 1
            }

            if let match {
                usedPrevious.insert(match)
                previousCursor = match + 1
                changes.append(.revised(id: block.id, previousID: previous[match].id))
            } else {
                changes.append(.inserted(id: block.id))
            }
        }

        return changes
    }

    /// Longest common subsequence over block ids, returned as a map from an
    /// index in `current` to the matching index in `previous`.
    private static func commonSubsequence(
        previous: [ReadingBlockIdentity],
        current: [ReadingBlockIdentity]
    ) -> [Int: Int] {
        let rows = previous.count
        let columns = current.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)

        for row in stride(from: rows - 1, through: 0, by: -1) {
            for column in stride(from: columns - 1, through: 0, by: -1) {
                table[row][column] = previous[row].id == current[column].id
                    ? table[row + 1][column + 1] + 1
                    : max(table[row + 1][column], table[row][column + 1])
            }
        }

        var matches: [Int: Int] = [:]
        var row = 0
        var column = 0
        while row < rows && column < columns {
            if previous[row].id == current[column].id {
                matches[column] = row
                row += 1
                column += 1
            } else if table[row + 1][column] >= table[row][column + 1] {
                row += 1
            } else {
                column += 1
            }
        }
        return matches
    }
}
