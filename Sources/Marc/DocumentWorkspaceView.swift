import AppKit
import MarcCore
import SwiftUI

struct DocumentWorkspaceView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var document: MarkdownDocument
    @Binding var mode: WorkspaceMode
    @Binding var navigationTarget: String?
    @Binding var attentionHighlightTarget: String?
    @Binding var showFind: Bool
    @State private var unreadCursorID: String?

    var body: some View {
        VStack(spacing: 0) {
            if showFind {
                FindBar(document: document, isPresented: $showFind)
                Divider()
            }
            if !document.pendingReadingBlocks.isEmpty {
                ReadingStatusBar(
                    unreadCount: document.unreadCount,
                    changedCount: document.changedCount,
                    previous: { jumpToPending(direction: -1) },
                    next: { jumpToPending(direction: 1) },
                    markAllRead: document.markAllRead
                )
                Divider()
            }
            if document.format == .html {
                HTMLDocumentBar(document: document)
                Divider()
            }
            switch mode {
            case .rendered:
                renderedView
            case .source:
                SourceEditor(document: document)
            case .split:
                HSplitView {
                    SourceEditor(document: document)
                        .frame(minWidth: 320)
                    renderedView
                        .frame(minWidth: 360)
                }
            }
        }
    }

    @ViewBuilder
    private var renderedView: some View {
        switch document.format {
        case .markdown:
            MarkdownPreview(
                document: document,
                navigationTarget: $navigationTarget,
                attentionHighlightTarget: $attentionHighlightTarget
            )
        case .html:
            HTMLPreview(
                document: document,
                navigationTarget: $navigationTarget,
                openLink: { store.openLink($0, from: document) },
                openExternal: { store.openExternalLink($0) }
            )
        }
    }

    private func jumpToPending(direction: Int) {
        let blocks = document.pendingReadingBlocks
        guard !blocks.isEmpty else { return }
        let currentIndex = unreadCursorID.flatMap { id in blocks.firstIndex { $0.id == id } }
        let nextIndex: Int
        if let currentIndex {
            nextIndex = (currentIndex + direction + blocks.count) % blocks.count
        } else {
            nextIndex = direction > 0 ? 0 : blocks.count - 1
        }
        let block = blocks[nextIndex]
        unreadCursorID = block.id
        if mode == .source {
            mode = .rendered
        }
        navigationTarget = block.id
    }
}

/// Shows what marc is doing with an HTML page and what it is holding back.
private struct HTMLDocumentBar: View {
    @ObservedObject var document: MarkdownDocument

    private var blocked: [String] { document.blockedExternalResources }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: shapeSymbol)
                .foregroundStyle(.secondary)
            Text(shapeText)
                .font(.callout)

            if !blocked.isEmpty {
                Text("·").foregroundStyle(.tertiary)
                Image(systemName: "network.slash")
                    .foregroundStyle(.orange)
                Text(blockedText)
                    .font(.callout)
                    .help(blocked.prefix(8).joined(separator: "\n"))
                Button("Allow") { document.htmlAllowsNetwork = true }
                    .buttonStyle(.link)
                    .help("Let this page load its external resources. Remembered for this file.")
            }

            Spacer()

            Menu {
                Picker("Treat As", selection: shapeBinding) {
                    Text("Document").tag(HTMLDocumentShape.prose)
                    Text("App").tag(HTMLDocumentShape.app)
                }
                .pickerStyle(.inline)

                Divider()

                Toggle("Run Page Scripts", isOn: scriptBinding)
                Toggle("Allow Network Access", isOn: networkBinding)
            } label: {
                Label("Page Settings", systemImage: "gearshape")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var shapeSymbol: String {
        document.tracksReadingProgress ? "doc.richtext" : "app.dashed"
    }

    private var shapeText: String {
        document.tracksReadingProgress
            ? "Read as a document"
            : "Treated as an app · reading progress off"
    }

    private var blockedText: String {
        blocked.count == 1
            ? "1 external resource blocked"
            : "\(blocked.count) external resources blocked"
    }

    private var shapeBinding: Binding<HTMLDocumentShape> {
        Binding(
            get: { document.htmlShape ?? .prose },
            set: { document.htmlShape = $0 }
        )
    }

    private var scriptBinding: Binding<Bool> {
        Binding(get: { document.htmlAllowsScripts }, set: { document.htmlAllowsScripts = $0 })
    }

    private var networkBinding: Binding<Bool> {
        Binding(get: { document.htmlAllowsNetwork }, set: { document.htmlAllowsNetwork = $0 })
    }
}

private struct ReadingStatusBar: View {
    let unreadCount: Int
    let changedCount: Int
    let previous: () -> Void
    let next: () -> Void
    let markAllRead: () -> Void

    private var color: Color { changedCount > 0 ? .orange : .blue }

    var body: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.callout.weight(.medium))
            Spacer()
            Button(action: previous) {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.plain)
            .help("Previous unread passage (⌥⌘↑)")
            .keyboardShortcut(.upArrow, modifiers: [.command, .option])

            Button(action: next) {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(.plain)
            .help("Next unread passage (⌥⌘↓)")
            .keyboardShortcut(.downArrow, modifiers: [.command, .option])

            Button("Mark All Read", action: markAllRead)
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(color.opacity(0.08))
    }

    private var statusText: String {
        if changedCount > 0 {
            let remaining = unreadCount > 0 ? " · \(unreadCount) unread" : ""
            return "\(changedCount) updated passage\(changedCount == 1 ? "" : "s")\(remaining)"
        }
        return "\(unreadCount) unread passage\(unreadCount == 1 ? "" : "s")"
    }
}

struct SourceEditor: View {
    @ObservedObject var document: MarkdownDocument

    var body: some View {
        TextEditor(text: $document.content)
            .font(.system(size: document.preferences.theme.bodySize, design: .monospaced))
            .lineSpacing(3)
            .padding(8)
            .scrollContentBackground(.hidden)
            .background(Color(nsColor: .textBackgroundColor))
    }
}

struct FindBar: View {
    @ObservedObject var document: MarkdownDocument
    @Binding var isPresented: Bool
    @FocusState private var focused: Bool

    private var ranges: [Range<String.Index>] {
        guard !document.findText.isEmpty else { return [] }
        var matches: [Range<String.Index>] = []
        var position = document.content.startIndex
        while position < document.content.endIndex,
              let range = document.content.range(
                of: document.findText,
                options: [.caseInsensitive],
                range: position..<document.content.endIndex
              ) {
            matches.append(range)
            position = range.upperBound
        }
        return matches
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find in current document", text: $document.findText)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit { next() }
            Text(ranges.isEmpty ? "No matches" : "\(min(document.currentMatch + 1, ranges.count)) of \(ranges.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 72)
            Button(action: previous) { Image(systemName: "chevron.up") }
                .buttonStyle(.plain)
                .disabled(ranges.isEmpty)
            Button(action: next) { Image(systemName: "chevron.down") }
                .buttonStyle(.plain)
                .disabled(ranges.isEmpty)
            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .onAppear { focused = true }
        .onChange(of: document.findText) {
            document.currentMatch = 0
        }
    }

    private func next() {
        guard !ranges.isEmpty else { return }
        document.currentMatch = (document.currentMatch + 1) % ranges.count
    }

    private func previous() {
        guard !ranges.isEmpty else { return }
        document.currentMatch = (document.currentMatch - 1 + ranges.count) % ranges.count
    }
}

struct MarkdownPreview: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var document: MarkdownDocument
    @Binding var navigationTarget: String?
    @Binding var attentionHighlightTarget: String?
    @State private var readingCandidateID: String?
    @State private var readingTask: Task<Void, Never>?
    @State private var scrollTracker = ReadingScrollTracker()

    private var parsed: ParsedMarkdown { document.parsed }
    private var theme: MarkdownTheme { document.preferences.theme }
    private var readingCoordinateSpace: String { "reading-\(document.id.uuidString)" }

    var body: some View {
        GeometryReader { viewport in
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(parsed.blocks) { block in
                            if isVisible(block) {
                                MarkdownBlockView(
                                    block: block,
                                    theme: theme,
                                    isCollapsed: document.preferences.collapsedHeadingIDs.contains(block.id),
                                    tableColumnWidths: document.preferences.tableColumnWidths?[block.id],
                                    toggleCollapsed: { toggleCollapsed(block.id) },
                                    markSectionRead: { document.markSectionRead(block.id) },
                                    markSectionUnread: { document.markSectionUnread(block.id) },
                                    updateTableColumnWidths: { widths in
                                        var tableWidths = document.preferences.tableColumnWidths ?? [:]
                                        tableWidths[block.id] = widths
                                        document.preferences.tableColumnWidths = tableWidths
                                        document.preferences.tableWidthLayoutVersion = 2
                                    }
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: BlockFramePreferenceKey.self,
                                            value: [block.id: geometry.frame(in: .named(readingCoordinateSpace))]
                                        )
                                    }
                                }
                                .background(
                                    attentionHighlightTarget == block.id
                                        ? Color.purple.opacity(0.14)
                                        : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8)
                                )
                                .animation(.easeInOut(duration: 0.2), value: attentionHighlightTarget)
                                .overlay(alignment: .leading) {
                                    BlockGutterMarkers(
                                        readingStatus: document.readingStatus(for: block),
                                        hasAttentionSuggestion: document.attentionResult(for: block.id) != nil,
                                        attentionStale: document.attentionResultsAreStale
                                    )
                                        .offset(x: -16)
                                }
                                .id(block.id)
                            }
                        }
                    }
                    .frame(maxWidth: theme.usesFullWidth ? .infinity : theme.pageWidth, alignment: .leading)
                    .padding(.horizontal, theme.usesFullWidth ? 28 : 48)
                    .padding(.top, 36)
                    .padding(.bottom, max(36, viewport.size.height * 0.45))
                    .frame(maxWidth: .infinity, alignment: .top)
                    .background {
                        ScrollBarAppearanceConfigurator(
                            knobStyle: preferredScrollerKnobStyle
                        )
                    }
                }
                .coordinateSpace(name: readingCoordinateSpace)
                .background(theme.background.color)
                .onPreferenceChange(BlockFramePreferenceKey.self) { frames in
                    updateReadingProgress(frames: frames, viewportHeight: viewport.size.height)
                }
                .onChange(of: document.id) {
                    scrollTracker.reset()
                    readingCandidateID = nil
                    readingTask?.cancel()
                }
                .onChange(of: navigationTarget) {
                    guard let target = navigationTarget else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(target, anchor: .top)
                    }
                    if parsed.headings.contains(where: { $0.id == target }) {
                        document.preferences.lastScrollHeadingID = target
                    }
                    navigationTarget = nil
                }
            }
        }
        .onDisappear {
            readingTask?.cancel()
        }
        .environment(\.openURL, OpenURLAction { url in
            if DocumentFormat.of(url) != nil {
                store.openLink(url, from: document)
                return .handled
            }
            return .systemAction
        })
    }

    private func isVisible(_ block: MarkdownBlock) -> Bool {
        document.preferences.collapsedHeadingIDs.isDisjoint(with: block.ancestorHeadingIDs)
    }

    private func toggleCollapsed(_ id: String) {
        if document.preferences.collapsedHeadingIDs.contains(id) {
            document.preferences.collapsedHeadingIDs.remove(id)
        } else {
            document.preferences.collapsedHeadingIDs.insert(id)
        }
    }

    private var preferredScrollerKnobStyle: NSScroller.KnobStyle {
        let color = NSColor(theme.background.color).usingColorSpace(.sRGB) ?? .white
        let luminance =
            0.2126 * color.redComponent +
            0.7152 * color.greenComponent +
            0.0722 * color.blueComponent
        return luminance > 0.55 ? .dark : .light
    }

    private func updateReadingProgress(frames: [String: CGRect], viewportHeight: CGFloat) {
        let update = scrollTracker.advance(
            blockIDs: parsed.blocks.map(\.id),
            frames: frames.mapValues { ReadingScrollTracker.Frame(minY: $0.minY, maxY: $0.maxY) },
            viewportHeight: viewportHeight
        )
        if !update.read.isEmpty {
            document.markBlocksRead(update.read)
        }

        let candidate = update.atReadingLine
        guard candidate != readingCandidateID else { return }
        readingTask?.cancel()
        readingCandidateID = candidate
        guard let candidate else { return }

        readingTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, readingCandidateID == candidate else { return }
            document.markBlockRead(candidate)
        }
    }
}

private struct ScrollBarAppearanceConfigurator: NSViewRepresentable {
    let knobStyle: NSScroller.KnobStyle

    func makeNSView(context: Context) -> ScrollBarProbeView {
        ScrollBarProbeView(knobStyle: knobStyle)
    }

    func updateNSView(_ nsView: ScrollBarProbeView, context: Context) {
        nsView.knobStyle = knobStyle
        nsView.configureScroller()
    }
}

private final class ScrollBarProbeView: NSView {
    var knobStyle: NSScroller.KnobStyle

    init(knobStyle: NSScroller.KnobStyle) {
        self.knobStyle = knobStyle
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        configureScroller()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureScroller()
    }

    func configureScroller() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.enclosingScrollView else { return }
            scrollView.hasVerticalScroller = true
            scrollView.autohidesScrollers = false
            scrollView.scrollerStyle = .overlay
            scrollView.verticalScroller?.knobStyle = self.knobStyle
            scrollView.verticalScroller?.alphaValue = 1
            scrollView.flashScrollers()
        }
    }
}

private struct BlockFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct BlockGutterMarkers: View {
    let readingStatus: BlockReadingStatus
    let hasAttentionSuggestion: Bool
    let attentionStale: Bool

    var body: some View {
        VStack(spacing: 4) {
            if hasAttentionSuggestion {
                Diamond()
                    .fill(.purple)
                    .frame(width: 8, height: 8)
                    .opacity(attentionStale ? 0.35 : 1)
            }

            switch readingStatus {
            case .read:
                EmptyView()
            case .unread:
                Circle()
                    .fill(.blue)
                    .frame(width: 7, height: 7)
            case .changed:
                Capsule()
                    .fill(.orange)
                    .frame(width: 4, height: 18)
            }
        }
    }
}

private struct Diamond: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

struct MarkdownBlockView: View {
    let block: MarkdownBlock
    let theme: MarkdownTheme
    let isCollapsed: Bool
    let tableColumnWidths: [Double]?
    let toggleCollapsed: () -> Void
    let markSectionRead: () -> Void
    let markSectionUnread: () -> Void
    let updateTableColumnWidths: ([Double]) -> Void
    @State private var headingHovered = false

    var body: some View {
        switch block.kind {
        case let .heading(level, title):
            Button(action: toggleCollapsed) {
                InlineMarkdownText(source: title, color: theme.heading.color)
                    .font(headingFont(level: level))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .background(
                        theme.accent.color.opacity(headingHovered ? 0.08 : 0),
                        in: RoundedRectangle(cornerRadius: 6)
                    )
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(theme.accent.color)
                            .frame(width: 3)
                            .padding(.vertical, 4)
                            .offset(x: -8)
                            .opacity(headingHovered || isCollapsed ? 0.9 : 0)
                    }
                    .overlay(alignment: .trailing) {
                        if isCollapsed {
                            Text("…")
                                .font(.caption.bold())
                                .foregroundStyle(theme.accent.color)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(theme.accent.color.opacity(0.12), in: Capsule())
                                .padding(.trailing, 4)
                        }
                    }
                }
            .buttonStyle(.plain)
            .onHover { hovering in
                headingHovered = hovering
                (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
            }
            .help(isCollapsed ? "Click to expand section" : "Click to collapse section")
            .contextMenu {
                Button("Mark Section Read", action: markSectionRead)
                Button("Mark Section Unread", action: markSectionUnread)
            }
            .padding(.top, level <= 2 ? 16 : 8)

        case let .paragraph(text):
            InlineMarkdownText(source: text, color: theme.text.color)
                .font(bodyFont)
                .lineSpacing(5)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

        case let .list(items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        listMarker(item.marker)
                            .frame(width: 28, alignment: .trailing)
                        InlineMarkdownText(source: item.text, color: theme.text.color)
                            .strikethrough(isChecked(item), color: theme.quote.color)
                            .lineSpacing(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(item.level) * 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(bodyFont)
            .padding(.leading, 8)

        case let .table(table):
            MarkdownTableView(
                table: table,
                theme: theme,
                savedWidths: tableColumnWidths,
                onWidthsChanged: updateTableColumnWidths
            )
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .blockquote(text):
            HStack(spacing: 14) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(theme.accent.color.opacity(0.65))
                    .frame(width: 4)
                InlineMarkdownText(source: text, color: theme.quote.color)
                    .font(bodyFont.italic())
                    .lineSpacing(4)
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)

        case let .code(language, content):
            HighlightedCodeView(content: content, language: language, theme: theme)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .horizontalRule:
            Divider()
                .overlay(theme.quote.color.opacity(0.5))
                .padding(.vertical, 12)
        }
    }

    private var bodyFont: Font {
        .custom(theme.fontFamily, size: theme.bodySize)
    }

    @ViewBuilder
    private func listMarker(_ marker: MarkdownListItem.Marker) -> some View {
        switch marker {
        case .bullet:
            Text("•")
                .foregroundStyle(theme.accent.color)
        case let .ordered(number):
            Text("\(number).")
                .foregroundStyle(theme.accent.color)
                .monospacedDigit()
        case let .task(checked):
            Image(systemName: checked ? "checkmark.square.fill" : "square")
                .foregroundStyle(checked ? theme.accent.color : theme.quote.color)
        }
    }

    private func isChecked(_ item: MarkdownListItem) -> Bool {
        if case let .task(checked) = item.marker { return checked }
        return false
    }

    private func headingFont(level: Int) -> Font {
        let scale: Double
        let weight: Font.Weight
        switch level {
        case 1: (scale, weight) = (2.0, .bold)
        case 2: (scale, weight) = (1.6, .bold)
        case 3: (scale, weight) = (1.32, .semibold)
        case 4: (scale, weight) = (1.16, .semibold)
        default: (scale, weight) = (1.02, .semibold)
        }
        return .custom(theme.fontFamily, size: theme.bodySize * scale).weight(weight)
    }
}

private struct HighlightedCodeView: View {
    let content: String
    let language: String?
    let theme: MarkdownTheme
    let highlighted: SyntaxHighlightResult
    @State private var copied = false

    init(content: String, language: String?, theme: MarkdownTheme) {
        self.content = content
        self.language = language
        self.theme = theme
        self.highlighted = SyntaxHighlighter.highlight(content, language: language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if let languageName = highlighted.languageName {
                    Text(languageName)
                        .font(.caption2.bold())
                        .foregroundStyle(palette.keyword)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.3))
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(copied ? palette.string : theme.quote.color)
            }

            ScrollView(.horizontal, showsIndicators: true) {
                Text(attributedCode)
                    .font(.system(size: max(12, theme.bodySize - 2), design: .monospaced))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(14)
        .background(theme.codeBackground.color, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(theme.quote.color.opacity(0.16), lineWidth: 1)
        }
    }

    private var attributedCode: AttributedString {
        let attributed = NSMutableAttributedString(string: content)
        let fullRange = NSRange(location: 0, length: attributed.length)
        attributed.addAttributes(
            [
                .foregroundColor: NSColor(palette.plain),
                .font: NSFont.monospacedSystemFont(
                    ofSize: max(12, theme.bodySize - 2),
                    weight: .regular
                )
            ],
            range: fullRange
        )

        for span in highlighted.spans {
            guard span.location >= 0, span.length > 0, span.location + span.length <= attributed.length else {
                continue
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor(palette.color(for: span.kind))
            ]
            if span.kind == .comment {
                attributes[.font] = NSFontManager.shared.convert(
                    NSFont.monospacedSystemFont(
                        ofSize: max(12, theme.bodySize - 2),
                        weight: .regular
                    ),
                    toHaveTrait: .italicFontMask
                )
            } else if span.kind == .keyword || span.kind == .type || span.kind == .function {
                attributes[.font] = NSFont.monospacedSystemFont(
                    ofSize: max(12, theme.bodySize - 2),
                    weight: .medium
                )
            }
            attributed.addAttributes(
                attributes,
                range: NSRange(location: span.location, length: span.length)
            )
        }
        return AttributedString(attributed)
    }

    private var palette: SyntaxPalette {
        SyntaxPalette(theme: theme)
    }
}

private struct SyntaxPalette {
    let plain: Color
    let comment: Color
    let string: Color
    let number: Color
    let keyword: Color
    let type: Color
    let function: Color
    let property: Color
    let annotation: Color
    let literal: Color
    let operatorSymbol: Color

    init(theme: MarkdownTheme) {
        let background = NSColor(theme.codeBackground.color).usingColorSpace(.sRGB) ?? .black
        let luminance =
            0.2126 * background.redComponent +
            0.7152 * background.greenComponent +
            0.0722 * background.blueComponent
        plain = theme.text.color
        if luminance < 0.45 {
            comment = Color(hex: "#7F8C98")
            string = Color(hex: "#A8E66B")
            number = Color(hex: "#FF9D65")
            keyword = Color(hex: "#D89CFF")
            type = Color(hex: "#73D0FF")
            function = Color(hex: "#FFD866")
            property = Color(hex: "#FFCB6B")
            annotation = Color(hex: "#FF7AB2")
            literal = Color(hex: "#FF6188")
            operatorSymbol = Color(hex: "#78DCE8")
        } else {
            comment = Color(hex: "#64727D")
            string = Color(hex: "#2B8A3E")
            number = Color(hex: "#D9480F")
            keyword = Color(hex: "#8F3BB8")
            type = Color(hex: "#1769AA")
            function = Color(hex: "#6F42C1")
            property = Color(hex: "#9C6500")
            annotation = Color(hex: "#C2255C")
            literal = Color(hex: "#C92A2A")
            operatorSymbol = Color(hex: "#087F8C")
        }
    }

    func color(for kind: SyntaxTokenKind) -> Color {
        switch kind {
        case .comment: comment
        case .string: string
        case .number: number
        case .keyword: keyword
        case .type: type
        case .function: function
        case .property: property
        case .annotation: annotation
        case .literal: literal
        case .operatorSymbol: operatorSymbol
        }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable
    let theme: MarkdownTheme
    let onWidthsChanged: ([Double]) -> Void
    @State private var widths: [Double]
    @State private var activeResizeIndex: Int?
    @State private var resizeStartWidth = 0.0
    @State private var viewportWidth = 0.0
    @State private var hasCustomWidths: Bool

    init(
        table: MarkdownTable,
        theme: MarkdownTheme,
        savedWidths: [Double]?,
        onWidthsChanged: @escaping ([Double]) -> Void
    ) {
        self.table = table
        self.theme = theme
        self.onWidthsChanged = onWidthsChanged
        var initialWidths = Array((savedWidths ?? []).prefix(table.headers.count))
        if initialWidths.count < table.headers.count {
            initialWidths.append(contentsOf: repeatElement(180, count: table.headers.count - initialWidths.count))
        }
        _widths = State(initialValue: initialWidths)
        _hasCustomWidths = State(initialValue: savedWidths != nil)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(spacing: 0) {
                tableRow(table.headers, isHeader: true, rowIndex: 0)
                ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                    Divider()
                    tableRow(row, isHeader: false, rowIndex: index)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(theme.quote.color.opacity(0.35), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear {
                        updateViewportWidth(geometry.size.width)
                    }
                    .onChange(of: geometry.size.width) {
                        updateViewportWidth(geometry.size.width)
                    }
            }
        }
        .contextMenu {
            Button("Fit Columns to Table Width") {
                fitColumns(to: viewportWidth)
                hasCustomWidths = true
                onWidthsChanged(widths)
            }
        }
    }

    private func tableRow(_ cells: [String], isHeader: Bool, rowIndex: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { index, cell in
                InlineMarkdownText(source: cell, color: theme.text.color)
                    .font(
                        .custom(theme.fontFamily, size: max(13, theme.bodySize - 1))
                        .weight(isHeader ? .semibold : .regular)
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(width: widths[index], alignment: alignment(for: index))
                    .fixedSize(horizontal: false, vertical: true)
                    .help(cell)
            }
        }
        .background(rowBackground(isHeader: isHeader, rowIndex: rowIndex))
        .overlay {
            tableGridOverlay(isHeader: isHeader)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func alignment(for index: Int) -> Alignment {
        guard table.alignments.indices.contains(index) else { return .topLeading }
        switch table.alignments[index] {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }

    private func rowBackground(isHeader: Bool, rowIndex: Int) -> Color {
        if isHeader {
            return theme.heading.color.opacity(0.12)
        }
        return rowIndex.isMultiple(of: 2)
            ? Color.clear
            : theme.codeBackground.color.opacity(0.5)
    }

    private func tableGridOverlay(isHeader: Bool) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                ForEach(0..<max(0, widths.count - 1), id: \.self) { index in
                    let x = widths.prefix(index + 1).reduce(0, +)
                    Rectangle()
                        .fill(theme.quote.color.opacity(0.28))
                        .frame(width: 1, height: geometry.size.height)
                        .offset(x: x)

                    if isHeader {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(width: 12, height: geometry.size.height)
                            .contentShape(Rectangle())
                            .offset(x: x - 6)
                            .onHover { hovering in
                                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                            }
                            .gesture(resizeGesture(for: index))
                            .onTapGesture(count: 2) {
                                widths[index] = defaultColumnWidth
                                hasCustomWidths = true
                                onWidthsChanged(widths)
                            }
                            .help("Drag to resize column; double-click to reset")
                    }
                }
            }
        }
    }

    private var defaultColumnWidth: Double {
        guard !table.headers.isEmpty, viewportWidth > 0 else { return 180 }
        return max(140, viewportWidth / Double(table.headers.count))
    }

    private func updateViewportWidth(_ width: Double) {
        viewportWidth = width
        if !hasCustomWidths {
            fitColumns(to: width)
        }
    }

    private func fitColumns(to width: Double) {
        guard !table.headers.isEmpty, width > 0 else { return }
        widths = Array(repeating: max(140, width / Double(table.headers.count)), count: table.headers.count)
    }

    private func resizeGesture(for index: Int) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if activeResizeIndex != index {
                    activeResizeIndex = index
                    resizeStartWidth = widths[index]
                    hasCustomWidths = true
                }
                widths[index] = min(900, max(100, resizeStartWidth + value.translation.width))
            }
            .onEnded { _ in
                activeResizeIndex = nil
                onWidthsChanged(widths)
            }
    }
}

struct InlineMarkdownText: View {
    let source: String
    let color: Color

    var body: some View {
        Text(attributed)
            .foregroundStyle(color)
            .tint(color)
    }

    private var attributed: AttributedString {
        (try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(source)
    }
}
