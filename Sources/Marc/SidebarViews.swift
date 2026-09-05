import AppKit
import MarcCore
import SwiftUI

struct TableOfContentsView: View {
    @ObservedObject var document: MarkdownDocument
    @Binding var navigationTarget: String?
    var close: () -> Void = {}

    private var headings: [MarkdownHeading] { document.headings }
    private var baseLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Label("Outline", systemImage: "list.bullet.indent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .help("\(headings.count) headings")

                Spacer(minLength: 4)

                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .help("Hide outline (⇧⌘T)")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if headings.isEmpty {
                ContentUnavailableView(
                    "No Headings",
                    systemImage: "list.bullet.indent",
                    description: Text(
                        document.format == .html
                            ? "Add heading elements to build an outline."
                            : "Add Markdown headings to build an outline."
                    )
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(headings) { heading in
                            let counts = readingCounts(for: heading.id)
                            let attentionCount = attentionCount(for: heading.id)
                            OutlineRow(
                                heading: heading,
                                depth: max(0, heading.level - baseLevel),
                                accent: document.preferences.theme.accent.color,
                                isSelected: document.preferences.lastScrollHeadingID == heading.id,
                                unreadCount: counts.unread,
                                changedCount: counts.changed,
                                attentionCount: attentionCount,
                                attentionStale: document.attentionResultsAreStale,
                                markRead: { document.markSectionRead(heading.id) },
                                markUnread: { document.markSectionUnread(heading.id) }
                            ) {
                                expandAncestors(of: heading.id)
                                navigationTarget = heading.id
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .background(.bar)
    }

    private func expandAncestors(of id: String) {
        guard let block = document.structuralBlocks.first(where: { $0.id == id }) else { return }
        document.preferences.collapsedHeadingIDs.subtract(block.ancestorHeadingIDs)
    }

    private func readingCounts(for headingID: String) -> (unread: Int, changed: Int) {
        var unread = 0
        var changed = 0
        for block in document.structuralBlocks
        where block.id == headingID || block.ancestorHeadingIDs.contains(headingID) {
            switch document.readingStatus(for: block) {
            case .read: break
            case .unread: unread += 1
            case .changed: changed += 1
            }
        }
        return (unread, changed)
    }

    private func attentionCount(for headingID: String) -> Int {
        let sectionBlockIDs = Set(
            document.structuralBlocks
                .filter { $0.id == headingID || $0.ancestorHeadingIDs.contains(headingID) }
                .map(\.id)
        )
        return Set(
            document.attentionResults
                .filter { result in
                    !sectionBlockIDs.isDisjoint(with: result.blockIDs)
                }
                .map(\.chunkID)
        ).count
    }
}

private struct OutlineRow: View {
    let heading: MarkdownHeading
    let depth: Int
    let accent: Color
    let isSelected: Bool
    let unreadCount: Int
    let changedCount: Int
    let attentionCount: Int
    let attentionStale: Bool
    let markRead: () -> Void
    let markUnread: () -> Void
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                OutlineGuides(depth: min(depth, 5), accent: accent)
                    .frame(width: guideWidth, height: rowHeight)

                Text(heading.title)
                    .font(headingFont)
                    .foregroundStyle(isSelected ? accent : Color.primary.opacity(textOpacity))
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if attentionCount > 0 {
                    ReadingCountBadge(
                        count: attentionCount,
                        color: .purple,
                        opacity: attentionStale ? 0.4 : 1
                    )
                }
                if changedCount > 0 {
                    ReadingCountBadge(count: changedCount, color: .orange)
                } else if unreadCount > 0 {
                    ReadingCountBadge(count: unreadCount, color: .blue)
                }
            }
            .padding(.trailing, 9)
            .contentShape(Rectangle())
            .background(
                accent.opacity(isSelected ? 0.11 : (isHovered ? 0.06 : 0)),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .padding(.horizontal, 5)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
            (hovering ? NSCursor.pointingHand : NSCursor.arrow).set()
        }
        .help("H\(heading.level) · \(heading.title)")
        .contextMenu {
            Button("Mark Section Read", action: markRead)
            Button("Mark Section Unread", action: markUnread)
        }
    }

    private var guideWidth: CGFloat {
        depth == 0 ? 5 : CGFloat(min(depth, 5) * 13 + 8)
    }

    private var headingFont: Font {
        switch heading.level {
        case 1: .system(size: 15, weight: .bold)
        case 2: .system(size: 14, weight: .semibold)
        case 3: .system(size: 13, weight: .medium)
        case 4: .system(size: 12.5, weight: .regular)
        case 5: .system(size: 12, weight: .regular)
        default: .system(size: 11.5, weight: .regular)
        }
    }

    private var textOpacity: Double {
        switch heading.level {
        case 1: 1
        case 2: 0.92
        case 3: 0.82
        case 4: 0.74
        default: 0.66
        }
    }

    private var rowHeight: CGFloat {
        switch heading.level {
        case 1: 38
        case 2: 36
        default: 32
        }
    }
}

private struct ReadingCountBadge: View {
    let count: Int
    let color: Color
    var opacity = 1.0

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.13), in: Capsule())
            .opacity(opacity)
    }
}

private struct OutlineGuides: View {
    let depth: Int
    let accent: Color

    var body: some View {
        Canvas { context, size in
            guard depth > 0 else { return }
            let centerY = size.height / 2

            for level in 0..<depth {
                let x = CGFloat(level * 13 + 5)
                var vertical = Path()
                vertical.move(to: CGPoint(x: x, y: 0))
                vertical.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(
                    vertical,
                    with: .color(accent.opacity(level == depth - 1 ? 0.42 : 0.2)),
                    lineWidth: 1
                )
            }

            let currentX = CGFloat((depth - 1) * 13 + 5)
            var branch = Path()
            branch.move(to: CGPoint(x: currentX, y: centerY))
            branch.addLine(to: CGPoint(x: size.width, y: centerY))
            context.stroke(branch, with: .color(accent.opacity(0.42)), lineWidth: 1)
        }
    }
}

struct ReferenceGraphView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var document: MarkdownDocument
    var close: () -> Void = {}

    @State private var existingPaths: Set<String>?
    @State private var hoveredID: String?
    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var gesturePan: CGSize = .zero
    @AppStorage("graphListExpanded") private var listExpanded = true

    private var references: [MarkdownReference] { document.references }
    private var referenceKey: String { references.map(\.id).joined(separator: "\u{1}") }
    private var accent: Color { document.preferences.theme.accent.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if references.isEmpty {
                ContentUnavailableView(
                    "No Local Links",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text(
                        document.format == .html
                            ? "Relative links to .md and .html files appear here."
                            : "Relative .md links and [[wiki links]] appear here."
                    )
                )
            } else {
                canvas
                Divider()
                linkList
            }
        }
        .background(.bar)
        .task(id: referenceKey) {
            existingPaths = await Self.resolveExisting(references.compactMap(\.resolvedURL))
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("LINKED FILES")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            Text("\(references.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 4)

            if !references.isEmpty && !isAtRest {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { resetView() }
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.borderless)
                .help("Reset zoom and position")
            }

            Button(action: close) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Close linked files (⇧⌘G)")
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var canvas: some View {
        GeometryReader { viewport in
            let layout = ReferenceGraphLayout(ids: references.map(\.id))
            let scale = layout.fitScale(in: viewport.size) * zoom * gestureZoom

            ZStack {
                edges(layout: layout)

                nodeCard(
                    title: document.displayName,
                    subtitle: "Current",
                    state: .current,
                    isEmphasized: hoveredID == nil,
                    size: layout.centerNodeSize
                ) {}
                .position(layout.center)

                ForEach(layout.nodes, id: \.id) { node in
                    if let reference = reference(for: node.id) {
                        nodeCard(
                            title: reference.label,
                            subtitle: subtitle(for: reference),
                            state: state(for: reference),
                            isEmphasized: hoveredID == nil || hoveredID == node.id,
                            size: layout.nodeSize
                        ) {
                            store.open(reference: reference, in: document)
                        }
                        .position(node.center)
                        .onHover { hovering in
                            hoveredID = hovering ? node.id : (hoveredID == node.id ? nil : hoveredID)
                        }
                    }
                }
            }
            .frame(width: layout.contentSize.width, height: layout.contentSize.height)
            .scaleEffect(scale)
            .offset(x: pan.width + gesturePan.width, y: pan.height + gesturePan.height)
            .frame(width: viewport.size.width, height: viewport.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { gesturePan = $0.translation }
                    .onEnded { value in
                        pan.width += value.translation.width
                        pan.height += value.translation.height
                        gesturePan = .zero
                    }
            )
            .gesture(
                MagnifyGesture()
                    .onChanged { gestureZoom = $0.magnification }
                    .onEnded { value in
                        zoom = min(3, max(0.4, zoom * value.magnification))
                        gestureZoom = 1
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.2)) { resetView() }
            }
            .clipped()
        }
        .frame(minHeight: 200)
    }

    private func edges(layout: ReferenceGraphLayout) -> some View {
        Canvas { context, _ in
            for node in layout.nodes {
                let start = ReferenceGraphLayout.boundaryPoint(
                    from: layout.center,
                    toward: node.center,
                    size: layout.centerNodeSize
                )
                let end = ReferenceGraphLayout.boundaryPoint(
                    from: node.center,
                    toward: layout.center,
                    size: layout.nodeSize
                )
                var path = Path()
                path.move(to: start)
                path.addLine(to: end)

                let isHovered = hoveredID == node.id
                let dimmed = hoveredID != nil && !isHovered
                let missing = reference(for: node.id).map { state(for: $0) == .missing } ?? false
                context.stroke(
                    path,
                    with: .color(
                        (missing ? Color.orange : accent)
                            .opacity(isHovered ? 0.85 : (dimmed ? 0.1 : 0.3))
                    ),
                    style: StrokeStyle(
                        lineWidth: isHovered ? 2 : 1,
                        dash: missing ? [4, 3] : []
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var linkList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { listExpanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.bold())
                        .rotationEffect(.degrees(listExpanded ? 90 : 0))
                    Text("All Links")
                        .font(.caption.bold())
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
            }
            .buttonStyle(.plain)

            if listExpanded {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(references) { reference in
                            linkRow(reference)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 180)
            }
        }
    }

    private func linkRow(_ reference: MarkdownReference) -> some View {
        let state = state(for: reference)
        return HStack(spacing: 6) {
            Button {
                store.open(reference: reference, in: document)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: state == .missing ? "questionmark.diamond" : "doc.text")
                        .foregroundStyle(state == .missing ? Color.orange : accent)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(reference.label).lineLimit(1)
                        Text(reference.destination)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.leading, 12)
                .padding(.vertical, 5)
            }
            .buttonStyle(.plain)

            if state == .missing {
                Button("Create") {
                    store.createFile(for: reference, in: document)
                }
                .buttonStyle(.link)
                .font(.caption)
                .help("Create \(reference.destination) and open it")
                .padding(.trailing, 10)
            }
        }
        .background(
            accent.opacity(hoveredID == reference.id ? 0.08 : 0),
            in: RoundedRectangle(cornerRadius: 5)
        )
        .padding(.horizontal, 5)
        .onHover { hovering in
            hoveredID = hovering ? reference.id : (hoveredID == reference.id ? nil : hoveredID)
        }
    }

    private enum NodeState {
        case current
        case present
        case missing
        case unknown
    }

    private func nodeCard(
        title: String,
        subtitle: String?,
        state: NodeState,
        isEmphasized: Bool,
        size: CGSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, 8)
            .frame(width: size.width, height: size.height)
            .background(
                state == .current ? accent.opacity(0.18) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        state == .missing ? Color.orange : accent.opacity(state == .current ? 0.8 : 0.55),
                        style: StrokeStyle(lineWidth: 1, dash: state == .missing ? [4, 3] : [])
                    )
            }
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(state == .current)
        .opacity(isEmphasized ? 1 : 0.35)
        .help(subtitle.map { "\(title) · \($0)" } ?? title)
    }

    private var isAtRest: Bool {
        zoom == 1 && pan == .zero
    }

    private func resetView() {
        zoom = 1
        pan = .zero
        gestureZoom = 1
        gesturePan = .zero
    }

    private func reference(for id: String) -> MarkdownReference? {
        references.first { $0.id == id }
    }

    private func state(for reference: MarkdownReference) -> NodeState {
        guard let existingPaths else { return .unknown }
        guard let path = reference.resolvedURL?.path else { return .missing }
        return existingPaths.contains(path) ? .present : .missing
    }

    private func subtitle(for reference: MarkdownReference) -> String? {
        switch state(for: reference) {
        case .missing: "Missing"
        case .current: "Current"
        case .present, .unknown: reference.resolvedURL?.lastPathComponent
        }
    }

    /// Existence is resolved once per reference set, off the main thread.
    /// Reading it during layout used to stat every linked file on every frame.
    private static func resolveExisting(_ urls: [URL]) async -> Set<String> {
        await Task.detached(priority: .utility) {
            var found: Set<String> = []
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                found.insert(url.path)
            }
            return found
        }.value
    }
}
struct ThemeEditorView: View {
    @ObservedObject var document: MarkdownDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Document Theme")
                .font(.headline)
            Text("Saved for this file without changing its Markdown.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Preset", selection: presetBinding) {
                ForEach(MarkdownTheme.presets) { theme in
                    Text(theme.name).tag(theme.id)
                }
                if !MarkdownTheme.presets.contains(where: { $0.id == document.preferences.theme.id }) {
                    Text("Custom").tag(document.preferences.theme.id)
                }
            }

            Divider()

            Picker("Font", selection: $document.preferences.theme.fontFamily) {
                ForEach(["New York", "Charter", "Avenir Next", "Georgia", "Helvetica Neue"], id: \.self) {
                    Text($0).tag($0)
                }
            }

            LabeledContent("Text size") {
                HStack {
                    Slider(value: $document.preferences.theme.bodySize, in: 8...72, step: 1)
                    Text("\(Int(document.preferences.theme.bodySize))")
                        .monospacedDigit()
                        .frame(width: 24)
                }
                .frame(width: 180)
            }

            Toggle(
                "Full window width",
                isOn: Binding(
                    get: { document.preferences.theme.usesFullWidth },
                    set: { value in
                        document.preferences.theme.usesFullWidth = value
                        document.preferences.theme.id = "custom"
                        document.preferences.theme.name = "Custom"
                    }
                )
            )

            if !document.preferences.theme.usesFullWidth {
                LabeledContent("Page width") {
                    HStack {
                        Slider(value: $document.preferences.theme.pageWidth, in: 420...2400, step: 20)
                        Text("\(Int(document.preferences.theme.pageWidth))")
                            .monospacedDigit()
                            .frame(width: 44)
                    }
                    .frame(width: 180)
                }
            }

            Divider()

            colorRow("Page", keyPath: \.background)
            colorRow("Text", keyPath: \.text)
            colorRow("Headings", keyPath: \.heading)
            colorRow("Accent", keyPath: \.accent)
            colorRow("Code", keyPath: \.codeBackground)
            colorRow("Quotes", keyPath: \.quote)

            Button("Reset to Paper") {
                document.preferences.theme = .paper
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var presetBinding: Binding<String> {
        Binding(
            get: { document.preferences.theme.id },
            set: { id in
                if let theme = MarkdownTheme.presets.first(where: { $0.id == id }) {
                    document.preferences.theme = theme
                }
            }
        )
    }

    private func colorRow(
        _ title: String,
        keyPath: WritableKeyPath<MarkdownTheme, ThemeColor>
    ) -> some View {
        LabeledContent(title) {
            ColorPicker(
                "",
                selection: Binding(
                    get: { document.preferences.theme[keyPath: keyPath].color },
                    set: { color in
                        document.preferences.theme[keyPath: keyPath] = ThemeColor(hex: color.hexString)
                        document.preferences.theme.id = "custom"
                        document.preferences.theme.name = "Custom"
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
        }
    }
}

/// Draggable divider that resizes an adjacent side panel.
struct PanelResizeHandle: View {
    enum Edge {
        /// Panel sits to the right of the handle; dragging right shrinks it.
        case leading
        /// Panel sits to the left of the handle; dragging right grows it.
        case trailing
    }

    @Binding var width: Double
    let edge: Edge
    var range: ClosedRange<Double> = 200...520

    @State private var startWidth: Double?
    @State private var isHovered = false

    var body: some View {
        Divider()
            .overlay(
                Rectangle()
                    .fill(isHovered ? Color.accentColor.opacity(0.35) : .clear)
                    .frame(width: 3)
            )
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                isHovered = hovering
                (hovering ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = startWidth ?? width
                        startWidth = base
                        let delta = edge == .trailing ? value.translation.width : -value.translation.width
                        width = min(range.upperBound, max(range.lowerBound, base + delta))
                    }
                    .onEnded { _ in startWidth = nil }
            )
    }
}
