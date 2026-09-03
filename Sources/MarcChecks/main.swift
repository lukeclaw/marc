import Foundation
import MarcCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): message
        }
    }
}

@main
struct MarcChecks {
    static func main() throws {
        try checkHeadingsAndAncestors()
        try checkStableUniqueSlugs()
        try checkCommonBlocks()
        try checkMultilineNestedLists()
        try checkTables()
        try checkStableBlockRevisions()
        try checkAttentionAnalysis()
        try checkSyntaxHighlighting()
        try checkReferences()
        print("All marc parser checks passed.")
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw CheckFailure.failed(message) }
    }

    private static func checkHeadingsAndAncestors() throws {
        let parsed = MarkdownParser.parse(
            """
            # Plan
            Intro
            ## Steps
            - One
            - Two
            # Result
            Done
            """
        )

        try require(parsed.headings.map(\.title) == ["Plan", "Steps", "Result"], "Heading titles were not parsed")
        try require(parsed.blocks[1].ancestorHeadingIDs == ["plan"], "Paragraph ancestor was incorrect")
        try require(parsed.blocks[2].ancestorHeadingIDs == ["plan"], "Nested heading ancestor was incorrect")
        try require(parsed.blocks[3].ancestorHeadingIDs == ["plan", "steps"], "List ancestors were incorrect")
        try require(parsed.blocks.last?.ancestorHeadingIDs == ["result"], "Final section ancestor was incorrect")
    }

    private static func checkStableUniqueSlugs() throws {
        let parsed = MarkdownParser.parse("# Status\n## Status\n## Status")
        try require(
            parsed.headings.map(\.id) == ["status", "status-2", "status-3"],
            "Duplicate heading slugs were not unique"
        )
    }

    private static func checkCommonBlocks() throws {
        let parsed = MarkdownParser.parse(
            """
            > A quote

            - [x] Finished
            - [ ] Pending

            1. First
            2. Second

            ```swift
            let value = 1
            ```
            """
        )

        try require(parsed.blocks.contains { if case .blockquote = $0.kind { true } else { false } }, "Quote missing")
        try require(
            parsed.blocks.contains {
                if case let .list(items) = $0.kind {
                    return items.contains { if case .task = $0.marker { true } else { false } }
                }
                return false
            },
            "Tasks missing"
        )
        try require(parsed.blocks.contains { if case .list = $0.kind { true } else { false } }, "List missing")
        try require(
            parsed.blocks.contains { if case .code(language: "swift", _) = $0.kind { true } else { false } },
            "Code fence missing"
        )
    }

    private static func checkMultilineNestedLists() throws {
        let parsed = MarkdownParser.parse(
            """
            1. First acceptance criterion wraps onto
               a second line.
               1. Nested detail also wraps onto
                  another line.
               1. Another nested detail.
            1. Second top-level criterion.
            """
        )
        guard case let .list(items) = parsed.blocks.first?.kind else {
            throw CheckFailure.failed("Multiline list was split into separate blocks")
        }
        try require(items.count == 4, "Nested list item count was incorrect")
        try require(items.map(\.level) == [0, 1, 1, 0], "Nested list indentation was incorrect")
        try require(items[0].text.contains("a second line."), "Top-level continuation line was lost")
        try require(items[1].text.contains("another line."), "Nested continuation line was lost")
        try require(
            items.compactMap {
                if case let .ordered(number) = $0.marker { return number }
                return nil
            } == [1, 1, 2, 2],
            "Ordered list numbering did not advance by nesting level"
        )
    }

    private static func checkTables() throws {
        let parsed = MarkdownParser.parse(
            """
            | Name | Status | Count |
            | :--- | :----: | ----: |
            | Alpha | **Ready** | 3 |
            | Beta | Waiting | 12 |
            """
        )
        guard case let .table(table) = parsed.blocks.first?.kind else {
            throw CheckFailure.failed("Markdown table was not parsed")
        }
        try require(table.headers == ["Name", "Status", "Count"], "Table headers were incorrect")
        try require(table.rows.count == 2, "Table rows were incorrect")
        try require(table.alignments == [.leading, .center, .trailing], "Table alignment was incorrect")

        let shifted = MarkdownParser.parse("Intro\n\n" + """
            | Name | Status | Count |
            | :--- | :----: | ----: |
            | Alpha | **Ready** | 3 |
            """)
        try require(
            parsed.blocks.first?.id == shifted.blocks.last?.id,
            "Table identity changed when preceding content changed"
        )
    }

    private static func checkStableBlockRevisions() throws {
        let wrapped = MarkdownParser.parse(
            """
            # Title
            A paragraph that is wrapped
            across two source lines.
            """
        )
        let reflowed = MarkdownParser.parse(
            """
            # Title
            A paragraph that is wrapped across two source lines.
            """
        )
        let shifted = MarkdownParser.parse(
            """
            Intro before the section.

            # Title
            A paragraph that is wrapped across two source lines.
            """
        )
        let changed = MarkdownParser.parse(
            """
            # Title
            A paragraph with changed content.
            """
        )

        let wrappedParagraph = wrapped.blocks[1]
        let reflowedParagraph = reflowed.blocks[1]
        let shiftedParagraph = shifted.blocks.last!
        let changedParagraph = changed.blocks[1]
        try require(wrappedParagraph.id == reflowedParagraph.id, "Source wrapping changed block identity")
        try require(wrappedParagraph.signature == reflowedParagraph.signature, "Source wrapping changed block revision")
        try require(wrappedParagraph.id == shiftedParagraph.id, "Preceding content changed block identity")
        try require(wrappedParagraph.id != changedParagraph.id, "Changed prose retained its old block identity")

        let originalTable = MarkdownParser.parse("| Key | Value |\n| --- | --- |\n| A | One |").blocks[0]
        let changedTable = MarkdownParser.parse("| Key | Value |\n| --- | --- |\n| A | Two |").blocks[0]
        try require(originalTable.id == changedTable.id, "Table row edit changed table identity")
        try require(originalTable.signature != changedTable.signature, "Table row edit did not change table revision")
    }

    private static func checkAttentionAnalysis() throws {
        let parsed = MarkdownParser.parse(
            """
            # Routine Background

            The document describes the current architecture and normal operating behavior.

            # Active Incident

            A production outage is blocking all users and requires immediate rollback.

            # Proposed Change

            Approval is required before proceeding with this breaking contract change.
            """
        )
        let chunks = AttentionAnalyzer.makeChunks(from: parsed, fileName: "incident.md")
        try require(chunks.count == 3, "Attention chunking did not preserve sections")
        try require(
            AttentionAnalyzer.documentRevision(for: parsed) == AttentionAnalyzer.documentRevision(for: parsed),
            "Attention document revision was unstable"
        )

        guard AttentionAnalyzer.isAvailable else { return }
        var observedProgress: [Double] = []
        let results = try AttentionAnalyzer.analyze(chunks: chunks) {
            observedProgress.append($0)
        }
        try require(observedProgress.count == chunks.count, "Attention progress did not report each section")
        try require(observedProgress.last == 1, "Attention progress did not finish at 100 percent")
        try require(
            zip(observedProgress, observedProgress.dropFirst()).allSatisfy { pair in
                pair.0 <= pair.1
            },
            "Attention progress moved backwards"
        )
        try require(results.count <= 9, "Attention results exceeded the category caps")
        try require(
            results.contains { $0.category == .urgent && $0.breadcrumb == "Active Incident" },
            "Explicit active incident was not ranked urgent"
        )
        try require(
            results.contains { $0.category == .review && $0.breadcrumb == "Proposed Change" },
            "Explicit approval request was not ranked for review"
        )

        let resolved = MarkdownParser.parse(
            """
            # Historical Test Notes

            The test intentionally verifies an expected failure. The historical production outage was already resolved.
            """
        )
        let resolvedResults = try AttentionAnalyzer.analyze(
            chunks: AttentionAnalyzer.makeChunks(from: resolved, fileName: "history.md")
        )
        try require(
            resolvedResults
                .filter { $0.category == .urgent }
                .allSatisfy { $0.confidence == .relative },
            "Resolved historical failure received absolute-looking urgency confidence"
        )

        let neutral = MarkdownParser.parse(
            """
            # Overview

            This document explains the current data model and how the components interact.

            # Implementation Details

            The service reads records, applies the configured transformation, and writes the result.
            """
        )
        let neutralResults = try AttentionAnalyzer.analyze(
            chunks: AttentionAnalyzer.makeChunks(from: neutral, fileName: "overview.md")
        )
        try require(
            neutralResults.contains { $0.category == .important || $0.category == .review },
            "Neutral document did not receive relative fallback matches"
        )
        try require(
            neutralResults
                .filter { $0.category == .urgent }
                .allSatisfy { $0.confidence == .relative },
            "Neutral document received absolute-looking urgency confidence"
        )

        let crowdedSource = (1...20).map { index in
            """
            # Decision \(index)

            This architecture decision recommends an important scope change and documents a material tradeoff.
            """
        }.joined(separator: "\n\n")
        let crowded = MarkdownParser.parse(crowdedSource)
        let crowdedResults = try AttentionAnalyzer.analyze(
            chunks: AttentionAnalyzer.makeChunks(from: crowded, fileName: "decisions.md")
        )
        try require(
            crowdedResults.contains { $0.category == .important },
            "Strict important threshold suppressed every explicit decision"
        )
        try require(
            crowdedResults.filter { $0.category == .important }.count <= 3,
            "Important category exceeded its independent quota"
        )
        try require(
            crowdedResults.filter { $0.category == .urgent }.count <= 2 &&
                crowdedResults.filter { $0.category == .review }.count <= 4,
            "Attention category quotas were not enforced"
        )
    }

    private static func checkSyntaxHighlighting() throws {
        let swiftSource = """
        // fetch the current member
        let member: Member = fetchMember(id: 42)
        print("ready")
        """
        let swift = SyntaxHighlighter.highlight(swiftSource, language: "swift")
        try require(swift.languageName == "SWIFT", "Swift language alias did not resolve")
        try require(token("let", in: swiftSource, result: swift)?.kind == .keyword, "Swift keyword was not highlighted")
        try require(token("Member", in: swiftSource, result: swift)?.kind == .type, "Swift type was not highlighted")
        try require(token("fetchMember", in: swiftSource, result: swift)?.kind == .function, "Swift function was not highlighted")
        try require(token("42", in: swiftSource, result: swift)?.kind == .number, "Swift number was not highlighted")
        try require(token("\"ready\"", in: swiftSource, result: swift)?.kind == .string, "Swift string was not highlighted")
        try require(
            token("// fetch the current member", in: swiftSource, result: swift)?.kind == .comment,
            "Swift comment was not highlighted"
        )

        let pythonSource = "def greet(name):\n    return f\"hello {name}\" # greeting"
        let python = SyntaxHighlighter.highlight(pythonSource, language: "py")
        try require(token("def", in: pythonSource, result: python)?.kind == .keyword, "Python keyword was not highlighted")
        try require(token("greet", in: pythonSource, result: python)?.kind == .function, "Python function was not highlighted")
        try require(token("# greeting", in: pythonSource, result: python)?.kind == .comment, "Python comment was not highlighted")

        let sqlSource = "SELECT member_id, COUNT(*) FROM premium_grants WHERE active = true;"
        let sql = SyntaxHighlighter.highlight(sqlSource, language: "trino")
        try require(token("SELECT", in: sqlSource, result: sql)?.kind == .keyword, "SQL keyword matching was not case-insensitive")
        try require(token("COUNT", in: sqlSource, result: sql)?.kind == .function, "SQL function was not highlighted")
        try require(token("true", in: sqlSource, result: sql)?.kind == .literal, "SQL literal was not highlighted")

        let jsonSource = #"{"status": "ready", "count": 3, "enabled": true}"#
        let json = SyntaxHighlighter.highlight(jsonSource, language: "json")
        try require(token(#""status""#, in: jsonSource, result: json)?.kind == .property, "JSON key was not highlighted")
        try require(token(#""ready""#, in: jsonSource, result: json)?.kind == .string, "JSON value was not highlighted")
        try require(token("3", in: jsonSource, result: json)?.kind == .number, "JSON number was not highlighted")

        let inferredSource = "def calculate_total(items):\n    return sum(items)"
        let inferred = SyntaxHighlighter.highlight(inferredSource, language: nil)
        try require(inferred.languageName == "PYTHON", "Unlabeled Python was not inferred")

        let expression = "let result = 1-2"
        let expressionResult = SyntaxHighlighter.highlight(expression, language: "swift")
        try require(token("1", in: expression, result: expressionResult)?.kind == .number, "First number was not isolated")
        try require(token("-", in: expression, result: expressionResult)?.kind == .operatorSymbol, "Minus operator was swallowed")
        try require(token("2", in: expression, result: expressionResult)?.kind == .number, "Second number was not isolated")
    }

    private static func token(
        _ token: String,
        in source: String,
        result: SyntaxHighlightResult
    ) -> SyntaxHighlightSpan? {
        let nsSource = source as NSString
        let range = nsSource.range(of: token)
        guard range.location != NSNotFound else { return nil }
        return result.spans.first {
            $0.location == range.location && $0.length == range.length
        }
    }

    private static func checkReferences() throws {
        let base = URL(fileURLWithPath: "/tmp/notes/current.md")
        let parsed = MarkdownParser.parse(
            "See [Plan](plans/plan.md#next) and [[Results|the results]].",
            baseURL: base
        )

        try require(parsed.references.map(\.label) == ["Plan", "the results"], "Reference labels were incorrect")
        try require(
            parsed.references[0].resolvedURL?.path == "/tmp/notes/plans/plan.md",
            "Relative Markdown link did not resolve"
        )
        try require(
            parsed.references[1].resolvedURL?.path == "/tmp/notes/Results.md",
            "Wiki link did not resolve"
        )
    }
}
