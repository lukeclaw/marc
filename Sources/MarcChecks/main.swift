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
        try checkGraphLayout()
        try checkReadingAlignment()
        try checkHTMLStructure()
        try checkReadingScrollTracker()
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

    private static func checkGraphLayout() throws {
        for count in [0, 1, 2, 5, 9, 24, 60] {
            let ids = (0..<count).map { "node-\($0)" }
            let layout = ReferenceGraphLayout(ids: ids)

            try require(layout.nodes.count == count, "Layout dropped nodes for a count of \(count)")
            try require(
                Set(layout.nodes.map(\.id)).count == count,
                "Layout produced duplicate nodes for a count of \(count)"
            )

            let half = CGSize(width: layout.nodeSize.width / 2, height: layout.nodeSize.height / 2)
            for node in layout.nodes {
                try require(
                    node.center.x - half.width >= 0,
                    "Node \(node.id) fell outside the canvas for a count of \(count)"
                )
                try require(
                    node.center.x + half.width <= layout.contentSize.width,
                    "Node \(node.id) fell outside the canvas for a count of \(count)"
                )
                try require(
                    node.center.y - half.height >= 0,
                    "Node \(node.id) fell outside the canvas for a count of \(count)"
                )
                try require(
                    node.center.y + half.height <= layout.contentSize.height,
                    "Node \(node.id) fell outside the canvas for a count of \(count)"
                )
                try require(
                    !overlaps(node.center, layout.nodeSize, layout.center, layout.centerNodeSize),
                    "Node \(node.id) overlapped the current-file node for a count of \(count)"
                )
            }

            for (index, node) in layout.nodes.enumerated() {
                for other in layout.nodes[(index + 1)...] {
                    try require(
                        !overlaps(node.center, layout.nodeSize, other.center, layout.nodeSize),
                        "Nodes \(node.id) and \(other.id) overlapped for a count of \(count)"
                    )
                }
            }
        }

        let layout = ReferenceGraphLayout(ids: ["a", "b", "c"])
        guard let first = layout.nodes.first else {
            throw CheckFailure.failed("Layout produced no nodes to trim an edge against")
        }
        let start = ReferenceGraphLayout.boundaryPoint(
            from: layout.center,
            toward: first.center,
            size: layout.centerNodeSize
        )
        try require(
            abs(start.x - layout.center.x) <= layout.centerNodeSize.width / 2 + 0.001
                && abs(start.y - layout.center.y) <= layout.centerNodeSize.height / 2 + 0.001,
            "Edge start was not trimmed to the center card boundary"
        )
        try require(
            start != layout.center,
            "Edge start was not moved off the center point"
        )

        let fit = ReferenceGraphLayout(ids: (0..<30).map { "n\($0)" })
        try require(
            fit.fitScale(in: CGSize(width: 300, height: 300)) < 1,
            "A large graph should scale down to fit a narrow panel"
        )
        try require(
            fit.fitScale(in: CGSize(width: 4000, height: 4000)) == 1,
            "A graph should not scale up beyond its natural size"
        )
    }

    private static func overlaps(
        _ a: CGPoint,
        _ aSize: CGSize,
        _ b: CGPoint,
        _ bSize: CGSize
    ) -> Bool {
        abs(a.x - b.x) < (aSize.width + bSize.width) / 2
            && abs(a.y - b.y) < (aSize.height + bSize.height) / 2
    }

    private static func checkReadingAlignment() throws {
        func identities(_ source: String) -> [ReadingBlockIdentity] {
            MarkdownParser.parse(source).blocks.map(\.readingIdentity)
        }

        let original = """
        # Report

        The build finished cleanly.

        ## Results

        Latency held steady.

        Throughput improved.
        """

        try require(
            ReadingAlignment.align(previous: identities(original), current: identities(original))
                .allSatisfy { if case .unchanged = $0 { true } else { false } },
            "Re-parsing an unchanged document reported changes"
        )

        let edited = original.replacingOccurrences(
            of: "Latency held steady.",
            with: "Latency regressed by 12ms."
        )
        let editChanges = ReadingAlignment.align(
            previous: identities(original),
            current: identities(edited)
        )
        let revised = editChanges.compactMap { change -> (String, String)? in
            if case let .revised(id, previousID) = change { (id, previousID) } else { nil }
        }
        try require(revised.count == 1, "An edited paragraph should report exactly one revision")
        try require(
            revised[0].1 == identities(original)[3].id,
            "The revision did not point at the paragraph it replaced"
        )
        try require(
            editChanges.filter { if case .inserted = $0 { true } else { false } }.isEmpty,
            "An edited paragraph should not report an insertion"
        )

        let inserted = original.replacingOccurrences(
            of: "Latency held steady.",
            with: "Latency held steady.\n\nMemory was flat."
        )
        let insertChanges = ReadingAlignment.align(
            previous: identities(original),
            current: identities(inserted)
        )
        try require(
            insertChanges.filter { if case .inserted = $0 { true } else { false } }.count == 1,
            "Inserting a paragraph should report exactly one insertion"
        )
        try require(
            insertChanges.filter { if case .revised = $0 { true } else { false } }.isEmpty,
            "Inserting a paragraph should leave surrounding blocks untouched"
        )
        try require(
            insertChanges.filter { if case .unchanged = $0 { true } else { false } }.count
                == identities(original).count,
            "Every pre-existing block should survive an insertion unchanged"
        )

        let retyped = original.replacingOccurrences(
            of: "Latency held steady.",
            with: "```\nlatency: steady\n```"
        )
        let kindChanges = ReadingAlignment.align(
            previous: identities(original),
            current: identities(retyped)
        )
        try require(
            kindChanges.contains { if case .inserted = $0 { true } else { false } },
            "Replacing a paragraph with a code block should not read as a revision"
        )

        let moved = """
        # Report

        The build finished cleanly.

        ## Results

        Throughput improved.

        ## Notes

        Latency held steadyish.
        """
        let sectionChanges = ReadingAlignment.align(
            previous: identities(original),
            current: identities(moved)
        )
        try require(
            sectionChanges.filter { if case .revised = $0 { true } else { false } }.isEmpty,
            "Blocks should not be paired as revisions across different headings"
        )

        let empty = ReadingAlignment.align(previous: [], current: identities(original))
        try require(
            empty.allSatisfy { if case .inserted = $0 { true } else { false } },
            "Every block of a document with no baseline should be new"
        )
        try require(
            ReadingAlignment.align(previous: identities(original), current: []).isEmpty,
            "Aligning against an empty document should report nothing"
        )
    }

    private static func checkHTMLStructure() throws {
        let page = """
        <!doctype html>
        <html>
        <head><title>Latency Report</title></head>
        <body>
          <h1>Latency Report</h1>
          <p>The p99 held at <strong>240ms</strong>.</p>
          <h2>Details</h2>
          <p>Regional breakdown follows.</p>
          <table><tr><td>eu-west</td><td>212ms</td></tr></table>
          <pre><code>p99 = 240</code></pre>
          <p>See <a href="plan.md">the plan</a> and <a href="appendix.html">the appendix</a>.</p>
          <p>Also <a href="https://example.com/x">an external page</a>.</p>
          <script src="https://cdn.example.com/chart.js"></script>
        </body>
        </html>
        """
        let parsed = HTMLParser.parse(page, baseURL: URL(fileURLWithPath: "/tmp/notes/report.html"))

        try require(parsed.title == "Latency Report", "The page title was not read")
        try require(
            parsed.headings.map(\.title) == ["Latency Report", "Details"],
            "HTML headings did not build an outline"
        )
        try require(parsed.headings.map(\.level) == [1, 2], "Heading levels were wrong")

        let details = parsed.blocks.filter { $0.ancestorHeadingIDs.contains("details") }
        try require(
            details.map(\.tag) == ["p", "table", "pre", "p", "p"],
            "Blocks were not attributed to the heading they sit under"
        )

        try require(
            parsed.blocks.contains { $0.tag == "p" && $0.text == "The p99 held at 240ms." },
            "Inline markup was not flattened into block text"
        )
        try require(
            Set(parsed.blocks.map(\.id)).count == parsed.blocks.count,
            "HTML block identifiers were not unique"
        )
        try require(
            parsed.blocks.map(\.ordinal) == Array(0..<parsed.blocks.count),
            "Block ordinals were not document order"
        )

        try require(
            parsed.references.map(\.destination) == ["plan.md", "appendix.html"],
            "Only local Markdown and HTML links belong in the graph"
        )
        try require(
            parsed.references[0].resolvedURL?.path == "/tmp/notes/plan.md",
            "A relative link from an HTML file did not resolve"
        )
        try require(
            parsed.externalResources == ["https://cdn.example.com/chart.js"],
            "External resources were not reported for the network prompt"
        )
        try require(parsed.shape == .prose, "A report should be treated as prose")

        // Editing a paragraph should read as a revision, exactly as in Markdown.
        let edited = page.replacingOccurrences(of: "held at <strong>240ms</strong>", with: "rose to 310ms")
        let changes = ReadingAlignment.align(
            previous: parsed.blocks.map(\.readingIdentity),
            current: HTMLParser.parse(edited).blocks.map(\.readingIdentity)
        )
        try require(
            changes.filter { if case .revised = $0 { true } else { false } }.count == 1,
            "An edited HTML paragraph should report exactly one revision"
        )

        let dashboard = """
        <html><body>
        <div id="root"></div>
        <canvas id="chart"></canvas>
        <form><input name="q"><button>Go</button></form>
        <script>
        const state = { count: 0, series: [1, 2, 3], labels: ["a", "b", "c"] };
        function render() { document.getElementById("chart").innerHTML = state.count; }
        setInterval(render, 1000);
        </script>
        </body></html>
        """
        try require(
            HTMLParser.parse(dashboard).shape == .app,
            "An interactive page should not be treated as prose"
        )

        try require(
            HTMLParser.parse("").blocks.isEmpty,
            "An empty page should produce no blocks"
        )
        try require(
            HTMLParser.parse("<p>Unclosed paragraph").blocks.count == 1,
            "An unclosed element should still produce its block"
        )

        // Markup a browser accepts and repairs. The block list has to end up
        // where the rendered page puts it, or every reading mark after the
        // first repair lands on the wrong element.
        try require(
            HTMLParser.parse("<p>One<p>Two").blocks.map(\.text) == ["One", "Two"],
            "A paragraph closed by the next paragraph should be two blocks"
        )
        try require(
            HTMLParser.parse("<p>Lead<h2>Heading</h2><p>Tail").headings.map(\.title) == ["Heading"],
            "An unclosed paragraph should not swallow the heading after it"
        )
        try require(
            HTMLParser.parse("<ul><li>One<li>Two</ul><p>After").blocks.map(\.tag) == ["ul", "p"],
            "Unclosed list items should not stop the list from closing"
        )
        try require(
            HTMLParser.parse("<p>Text</p></p><p>After").blocks.map(\.text) == ["Text", "", "After"],
            "A stray end tag for a paragraph should make the empty one a browser makes"
        )
        try require(
            HTMLParser.parse("<blockquote>Quote</section><p>After").blocks.map(\.text)
                == ["QuoteAfter"],
            "An end tag matching nothing on the stack should be ignored, leaving the quote open"
        )
        try require(
            HTMLParser.parse("<div/><p>After").blocks.map(\.text) == ["After"],
            "A trailing slash should not close an HTML element"
        )
        try require(
            HTMLParser.parse("<svg><title>Chart</title><rect/></svg><p>After").blocks.map(\.tag)
                == ["svg", "p"],
            "A trailing slash should close a foreign element"
        )
        try require(
            HTMLParser.parse("<svg><title>Chart</title></svg><title>Real</title>").title == "Real",
            "A title inside inline SVG is not the document's title"
        )

        // Text that only looks like markup.
        try require(
            HTMLParser.parse("<p title=\"a > b\">Body</p>").blocks.first?.text == "Body",
            "A greater-than sign inside an attribute value should not end its tag"
        )
        try require(
            HTMLParser.parse("<p>Before<!-- <b>hidden</b> -->After</p>").blocks.first?.text
                == "BeforeAfter",
            "A comment should run to its end rather than to the first angle bracket"
        )
        try require(
            HTMLParser.parse("<p>5 < 6 and 7 > 4</p>").blocks.first?.text == "5 < 6 and 7 > 4",
            "An angle bracket that opens no tag is text"
        )
        try require(
            HTMLParser.parse("<img alt=\"see src=https://nowhere.example/x.png\" src=\"local.png\">")
                .externalResources.isEmpty,
            "An attribute name inside another attribute's value is not a request"
        )
        try require(
            HTMLParser.parse("<script>if (a < b) { x = \"<p>no</p>\"; }</script><p>After")
                .blocks.map(\.tag) == ["p"],
            "A comparison inside a script should not open a block"
        )

        // Entity references, decoded in one pass.
        try require(
            HTMLParser.parse("<p>&amp;lt;p&amp;gt;</p>").blocks.first?.text == "&lt;p&gt;",
            "A doubled entity should decode once, not twice"
        )
        try require(
            HTMLParser.parse("<p>&mdash; &#8212; &#x2192; &nosuchentity;</p>").blocks.first?.text
                == "— — → &nosuchentity;",
            "Named and numeric references should decode, and unknown names should not"
        )

        try require(DocumentFormat.of(URL(fileURLWithPath: "/a/b.md")) == .markdown, "md was not Markdown")
        try require(DocumentFormat.of(URL(fileURLWithPath: "/a/b.HTML")) == .html, "HTML was not html")
        try require(DocumentFormat.of(URL(fileURLWithPath: "/a/b.txt")) == nil, "txt is not a marc document")
    }

    private static func checkReadingScrollTracker() throws {
        let ids = (0..<10).map { "b\($0)" }
        let viewport: CGFloat = 600
        let blockHeight: CGFloat = 200

        /// Frames for every block when the document is scrolled by `offset`.
        func frames(offset: CGFloat) -> [String: ReadingScrollTracker.Frame] {
            var result: [String: ReadingScrollTracker.Frame] = [:]
            for (index, id) in ids.enumerated() {
                let top = CGFloat(index) * blockHeight - offset
                // Only blocks near the viewport are laid out, as in a lazy stack.
                guard top < viewport + 400, top + blockHeight > -400 else { continue }
                result[id] = ReadingScrollTracker.Frame(minY: top, maxY: top + blockHeight)
            }
            return result
        }

        var tracker = ReadingScrollTracker()
        for _ in 0..<5 {
            let opened = tracker.advance(
                blockIDs: ids,
                frames: frames(offset: 0),
                viewportHeight: viewport
            )
            try require(
                opened.read.isEmpty,
                "Opening a document should not retire passages until it is scrolled"
            )
        }

        var everRead: Set<String> = []
        for offset in stride(from: CGFloat(0), through: 1400, by: 350) {
            let update = tracker.advance(
                blockIDs: ids,
                frames: frames(offset: offset),
                viewportHeight: viewport
            )
            everRead.formUnion(update.read)
        }
        try require(
            everRead.isSuperset(of: ["b0", "b1", "b2", "b3"]),
            "Scrolling past a run of passages should retire all of them, not only one"
        )

        // A fast scroll skips straight past several screens at once.
        var fast = ReadingScrollTracker()
        _ = fast.advance(blockIDs: ids, frames: frames(offset: 0), viewportHeight: viewport)
        let jumped = fast.advance(blockIDs: ids, frames: frames(offset: 1200), viewportHeight: viewport)
        try require(
            jumped.read.contains("b0"),
            "A passage dropped from layout during a fast scroll should still be retired"
        )

        // An outline jump lands deep in the document without displaying the
        // pages in between, which must stay unread.
        var jumper = ReadingScrollTracker()
        let landed = jumper.advance(
            blockIDs: ids,
            frames: frames(offset: 1200),
            viewportHeight: viewport
        )
        try require(
            landed.read.isEmpty,
            "Jumping into a document should not retire the passages that were skipped"
        )
        let afterNudge = jumper.advance(
            blockIDs: ids,
            frames: frames(offset: 1500),
            viewportHeight: viewport
        )
        try require(
            !afterNudge.read.contains("b0") && !afterNudge.read.contains("b3"),
            "Passages above an outline jump should stay unread after scrolling on"
        )

        var line = ReadingScrollTracker()
        let resting = line.advance(blockIDs: ids, frames: frames(offset: 0), viewportHeight: viewport)
        try require(
            resting.atReadingLine == "b1",
            "The block crossing the reading line was not identified"
        )
        try require(
            line.advance(blockIDs: ids, frames: [:], viewportHeight: viewport).read.isEmpty,
            "Reporting no frames should retire nothing"
        )
        try require(
            line.advance(blockIDs: ids, frames: frames(offset: 0), viewportHeight: 0).read.isEmpty,
            "A zero-height viewport should retire nothing"
        )
    }

    private static func checkReferences() throws {
        let base = URL(fileURLWithPath: "/tmp/notes/current.md")
        let parsed = MarkdownParser.parse(
            """
            See [Plan](plans/plan.md#next) and [[Results|the results]].
            The [demo](out/demo.html) and [notes](notes.mkd) belong here too.
            [Upstream](https://example.com/page.html) does not, nor does [[Chart.html]].
            """,
            baseURL: base
        )

        try require(
            parsed.references.map(\.label) == ["Plan", "demo", "notes", "the results", "Chart.html"],
            "Reference labels were incorrect"
        )
        try require(
            parsed.references[1].resolvedURL?.path == "/tmp/notes/out/demo.html",
            "A link to an HTML file should be a graph edge"
        )
        try require(
            parsed.references[2].resolvedURL?.path == "/tmp/notes/notes.mkd",
            "Every Markdown extension marc opens should be a graph edge"
        )
        try require(
            parsed.references[4].resolvedURL?.path == "/tmp/notes/Chart.html",
            "A wiki link naming an HTML file should not have .md appended"
        )
        try require(
            !parsed.references.contains { $0.destination.contains("://") },
            "A link to the web is not a document in the folder"
        )
        try require(
            parsed.references[0].resolvedURL?.path == "/tmp/notes/plans/plan.md",
            "Relative Markdown link did not resolve"
        )
        try require(
            parsed.references[3].resolvedURL?.path == "/tmp/notes/Results.md",
            "Wiki link did not resolve"
        )
    }
}
