import AppKit
import MarcCore
import SwiftUI

struct TableOfContentsView: View {
    @ObservedObject var document: MarkdownDocument
    @Binding var navigationTarget: String?

    private var headings: [MarkdownHeading] { document.parsed.headings }
    private var baseLevel: Int { headings.map(\.level).min() ?? 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Outline", systemImage: "list.bullet.indent")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .help("\(headings.count) headings")

            Divider()

            if headings.isEmpty {
                ContentUnavailableView(
                    "No Headings",
                    systemImage: "list.bullet.indent",
                    description: Text("Add Markdown headings to build an outline.")
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
        .frame(width: 240)
        .background(.bar)
    }

    private func expandAncestors(of id: String) {
        guard let block = document.parsed.blocks.first(where: { $0.id == id }) else { return }
        document.preferences.collapsedHeadingIDs.subtract(block.ancestorHeadingIDs)
    }

    private func readingCounts(for headingID: String) -> (unread: Int, changed: Int) {
        var unread = 0
        var changed = 0
        for block in document.parsed.blocks
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
            document.parsed.blocks
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

    private var references: [MarkdownReference] { document.parsed.references }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("LINKED FILES")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(references.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            Divider()

            if references.isEmpty {
                ContentUnavailableView(
                    "No Markdown Links",
                    systemImage: "point.3.connected.trianglepath.dotted",
                    description: Text("Relative .md links and [[wiki links]] appear here.")
                )
            } else {
                GeometryReader { geometry in
                    let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                    ZStack {
                        Canvas { context, _ in
                            for point in nodePoints(size: geometry.size) {
                                var path = Path()
                                path.move(to: center)
                                path.addLine(to: point)
                                context.stroke(
                                    path,
                                    with: .color(document.preferences.theme.accent.color.opacity(0.28)),
                                    lineWidth: 1
                                )
                            }
                        }

                        node(
                            title: document.displayName,
                            subtitle: "Current",
                            exists: true,
                            selected: true
                        ) {}
                        .position(center)

                        ForEach(Array(references.enumerated()), id: \.element.id) { index, reference in
                            node(
                                title: reference.label,
                                subtitle: reference.exists ? reference.resolvedURL?.lastPathComponent : "Missing",
                                exists: reference.exists,
                                selected: false
                            ) {
                                store.open(reference: reference)
                            }
                            .position(nodePoints(size: geometry.size)[index])
                        }
                    }
                }
                .padding(16)

                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(references) { reference in
                            Button {
                                store.open(reference: reference)
                            } label: {
                                HStack {
                                    Image(systemName: reference.exists ? "doc.text" : "questionmark.diamond")
                                        .foregroundStyle(reference.exists ? Color.accentColor : Color.orange)
                                    VStack(alignment: .leading) {
                                        Text(reference.label).lineLimit(1)
                                        Text(reference.destination)
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 180)
            }
        }
        .background(.bar)
    }

    private func nodePoints(size: CGSize) -> [CGPoint] {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.36
        return references.indices.map { index in
            let angle = (Double(index) / Double(max(1, references.count))) * 2 * .pi - .pi / 2
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }
    }

    private func node(
        title: String,
        subtitle: String?,
        exists: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.caption.bold())
                    .lineLimit(2)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: selected ? 104 : 92)
            .padding(.vertical, 8)
            .background(
                selected
                    ? document.preferences.theme.accent.color.opacity(0.2)
                    : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(
                        exists ? document.preferences.theme.accent.color.opacity(0.65) : .orange,
                        style: StrokeStyle(lineWidth: 1, dash: exists ? [] : [4])
                    )
            }
        }
        .buttonStyle(.plain)
        .disabled(selected)
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
