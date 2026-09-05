import AppKit
import MarcCore
import SwiftUI

struct WorkspaceView: View {
    @EnvironmentObject private var store: DocumentStore
    @AppStorage("workspaceMode") private var mode: WorkspaceMode = .rendered
    @AppStorage("tocPosition") private var tocPosition: SidebarPosition = .left
    @AppStorage("showTableOfContents") private var showTableOfContents = true
    @AppStorage("attentionAnalysisAcknowledged") private var attentionAnalysisAcknowledged = false
    @AppStorage("graphPanelWidth") private var graphPanelWidth = 360.0
    @State private var showGraph = false
    @State private var showAttention = false
    @State private var showAttentionDisclosure = false
    @State private var showThemeEditor = false
    @State private var showFind = false
    @State private var navigationTarget: String?
    @State private var attentionHighlightTarget: String?

    var body: some View {
        VStack(spacing: 0) {
            if store.documents.isEmpty {
                WelcomeView()
            } else {
                TabStrip()
                Divider()
                if let document = store.selectedDocument {
                    conflictBanner(document)
                    workspace(for: document)
                }
            }
        }
        .toolbar { toolbarContent }
        .onChange(of: store.selectedID) {
            attentionHighlightTarget = nil
        }
        .dropDestination(for: URL.self) { urls, _ in
            urls.filter { ["md", "markdown", "mdown", "mkd"].contains($0.pathExtension.lowercased()) }
                .forEach(store.open)
            return true
        }
        .alert(
            "marc",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func workspace(for document: MarkdownDocument) -> some View {
        HStack(spacing: 0) {
            if showTableOfContents && tocPosition == .left {
                TableOfContentsView(document: document, navigationTarget: $navigationTarget)
                Divider()
            }

            DocumentWorkspaceView(
                document: document,
                mode: $mode,
                navigationTarget: $navigationTarget,
                attentionHighlightTarget: $attentionHighlightTarget,
                showFind: $showFind
            )

            if showTableOfContents && tocPosition == .right {
                Divider()
                TableOfContentsView(document: document, navigationTarget: $navigationTarget)
            }

            if showGraph {
                PanelResizeHandle(width: $graphPanelWidth, edge: .leading, range: 260...620)
                ReferenceGraphView(document: document) { showGraph = false }
                    .frame(width: graphPanelWidth)
            }

            if showAttention {
                Divider()
                AttentionPanel(
                    document: document,
                    mode: $mode,
                    navigationTarget: $navigationTarget,
                    highlightTarget: $attentionHighlightTarget,
                    close: { showAttention = false }
                )
                .frame(width: 280)
            }
        }
    }

    @ViewBuilder
    private func conflictBanner(_ document: MarkdownDocument) -> some View {
        if document.externalConflict {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("This file changed on disk while you had unsaved edits.")
                Spacer()
                Button("Reload from Disk") { document.reloadFromDisk() }
                Button("Keep Mine") { store.overwriteWithLocalVersion(document) }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.yellow.opacity(0.12))
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                store.newDocument()
            } label: {
                Label("New", systemImage: "square.and.pencil")
            }
            .help("New Markdown file (⌘N)")

            Button {
                store.showOpenPanel()
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open Markdown (⌘O)")

            Picker("View", selection: $mode) {
                ForEach(WorkspaceMode.allCases) { item in
                    Label(item.label, systemImage: item.symbol).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 250)

            Button {
                showTableOfContents.toggle()
            } label: {
                Label("Table of Contents", systemImage: "sidebar.left")
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])
            .help("Toggle table of contents (⇧⌘T)")

            Button {
                showGraph.toggle()
            } label: {
                Label("Linked Files", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .help("Toggle linked files (⇧⌘G)")

            Button {
                guard let document = store.selectedDocument else { return }
                if !attentionAnalysisAcknowledged {
                    showAttentionDisclosure = true
                } else {
                    showAttention = true
                    if !document.hasCurrentAttentionResults && document.attentionState != .running {
                        document.startAttentionAnalysis(force: true)
                    }
                }
            } label: {
                Label("Analyze Attention", systemImage: "scope")
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(store.selectedDocument == nil)
            .help("Analyze attention locally on request (⇧⌘A)")
            .popover(isPresented: $showAttentionDisclosure, arrowEdge: .bottom) {
                AttentionDisclosureView(
                    modelAvailable: AttentionAnalyzer.isAvailable,
                    analyze: {
                        guard let document = store.selectedDocument else { return }
                        attentionAnalysisAcknowledged = true
                        showAttentionDisclosure = false
                        showAttention = true
                        document.startAttentionAnalysis(force: true)
                    },
                    cancel: {
                        showAttentionDisclosure = false
                    }
                )
                .frame(width: 340)
                .padding()
            }

            Button {
                showFind.toggle()
            } label: {
                Label("Find", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f")

            Button {
                showThemeEditor.toggle()
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }
            .keyboardShortcut(",", modifiers: [.command, .shift])
            .popover(isPresented: $showThemeEditor, arrowEdge: .bottom) {
                if let document = store.selectedDocument {
                    ThemeEditorView(document: document)
                        .frame(width: 340)
                        .padding()
                }
            }

            Menu {
                Button("New Project Group…") {
                    store.createGroup(assigning: store.selectedDocument)
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                if let document = store.selectedDocument {
                    Menu("Move Current File") {
                        Button("Ungrouped") {
                            store.assign(document, to: nil)
                        }
                        Divider()
                        ForEach(store.groups) { group in
                            Button {
                                store.assign(document, to: group.id)
                            } label: {
                                if store.group(for: document)?.id == group.id {
                                    Label(group.name, systemImage: "checkmark")
                                } else {
                                    Text(group.name)
                                }
                            }
                        }
                    }
                }

                Divider()

                Picker("Sort Tabs", selection: $store.tabSortOrder) {
                    ForEach(TabSortOrder.allCases) { order in
                        Text(order.label).tag(order)
                    }
                }
            } label: {
                Label("Project Groups", systemImage: "rectangle.3.group")
            }
            .help("Group tabs by project (⇧⌘N)")

            Menu {
                Button("Move Contents to Left") { tocPosition = .left }
                Button("Move Contents to Right") { tocPosition = .right }
                Divider()
                Button("Copy File Path") { store.copySelectedPath() }
                Button("Reveal in Finder") { store.revealSelectedInFinder() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }
}

private struct AttentionDisclosureView: View {
    let modelAvailable: Bool
    let analyze: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Label("Local Attention Analysis", systemImage: "scope")
                .font(.headline)
                .foregroundStyle(.purple)
            Text("marc will use Apple’s local sentence embedding model to suggest a small number of urgent, important, or review-worthy passages.")
                .font(.callout)
            VStack(alignment: .leading, spacing: 6) {
                Label("Runs only when you request it", systemImage: "hand.tap")
                Label("No network requests or notifications", systemImage: "network.slash")
                Label("Suggestions link to original source text", systemImage: "text.quote")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !modelAvailable {
                Label("The approved local embedding model is unavailable.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Analyze", action: analyze)
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .disabled(!modelAvailable)
            }
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "text.document")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("marc")
                    .font(.largeTitle.bold())
                Text("A calmer way to read what agents write.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("New Markdown…") { store.newDocument() }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                Button("Open Markdown…") { store.showOpenPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }

            if !store.recentURLs.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent")
                        .font(.headline)
                        .padding(.horizontal, 8)
                    ForEach(store.recentURLs.prefix(6), id: \.self) { url in
                        Button {
                            store.open(url: url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }
                .frame(width: 440)
                .padding(12)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
            }
            Text("You can also drop .md files anywhere in this window.")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct TabStrip: View {
    @EnvironmentObject private var store: DocumentStore

    var body: some View {
        GeometryReader { geometry in
            let ungrouped = store.groupDocuments(nil)
            let metrics = TabStripMetrics(
                availableWidth: geometry.size.width,
                groups: store.groups.map {
                    ($0.isCollapsed, store.groupDocuments($0.id).count)
                },
                ungroupedCount: ungrouped.count
            )

            ScrollView(.horizontal, showsIndicators: metrics.requiresScrolling) {
                HStack(alignment: .top, spacing: metrics.laneSpacing) {
                    ForEach(store.groups) { group in
                        let documentCount = store.groupDocuments(group.id).count
                        GroupTabSection(
                            group: group,
                            tabWidth: metrics.tabWidth,
                            laneWidth: metrics.laneWidth(
                                tabCount: documentCount,
                                collapsed: group.isCollapsed
                            )
                        )
                    }

                    if !ungrouped.isEmpty {
                        UngroupedTabSection(
                            documents: ungrouped,
                            tabWidth: metrics.tabWidth,
                            laneWidth: metrics.laneWidth(
                                tabCount: ungrouped.count,
                                collapsed: false
                            )
                        )
                    }

                    VStack(spacing: 0) {
                        Color.clear.frame(height: 24)
                        Menu {
                            Button("New Markdown File…") { store.newDocument() }
                            Button("Open Markdown…") { store.showOpenPanel() }
                        } label: {
                            Image(systemName: "plus")
                                .frame(width: 28, height: 30)
                                .contentShape(Rectangle())
                        } primaryAction: {
                            store.showOpenPanel()
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .help("New or open a file")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
        }
        .frame(height: 70)
        .background(.bar)
    }
}

private struct GroupTabSection: View {
    @EnvironmentObject private var store: DocumentStore
    let group: DocumentGroup
    let tabWidth: CGFloat
    let laneWidth: CGFloat
    @State private var isDropTargeted = false

    private var documents: [MarkdownDocument] {
        store.groupDocuments(group.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button {
                store.toggleGroup(group)
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(group.color)
                        .frame(width: 8, height: 8)
                    Text(group.name)
                        .font(.caption.bold())
                        .lineLimit(1)
                    Text("\(documents.count)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 2)
                    Image(systemName: group.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.bold())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .frame(width: laneWidth, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.isCollapsed ? "Expand \(group.name)" : "Collapse \(group.name)")
            .contextMenu {
                Button("New File in \(group.name)…") {
                    store.newDocument(
                        in: group.folderPath.map { URL(fileURLWithPath: $0) },
                        groupID: group.id
                    )
                }
                Divider()
                Button("Rename Group…") { store.renameGroup(group) }
                if let folderPath = group.folderPath {
                    Text("Auto-groups \(folderPath)")
                }
                Divider()
                Button("Move Group Left") { store.moveGroup(group, by: -1) }
                    .disabled(store.groups.first?.id == group.id)
                Button("Move Group Right") { store.moveGroup(group, by: 1) }
                    .disabled(store.groups.last?.id == group.id)
                Divider()
                Button("Delete Group…", role: .destructive) { store.deleteGroup(group) }
            }

            if !group.isCollapsed {
                HStack(spacing: 2) {
                    ForEach(documents) { document in
                        TabItemView(document: document, width: tabWidth)
                    }
                }
            }
        }
        .padding(2)
        .frame(width: laneWidth, alignment: .leading)
        .background(
            group.color.opacity(isDropTargeted ? 0.26 : 0.1),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay(alignment: .top) {
            Capsule()
                .fill(group.color.opacity(0.75))
                .frame(height: 2)
                .padding(.horizontal, 6)
        }
        .dropDestination(for: URL.self) { urls, _ in
            store.moveFiles(urls, to: group.id)
        } isTargeted: {
            isDropTargeted = $0
        }
        .help("Drag Markdown tabs here to move them into \(group.name)")
    }
}

private struct UngroupedTabSection: View {
    @EnvironmentObject private var store: DocumentStore
    let documents: [MarkdownDocument]
    let tabWidth: CGFloat
    let laneWidth: CGFloat
    @State private var isDropTargeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("Ungrouped")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text("\(documents.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(width: laneWidth, height: 22)

            HStack(spacing: 2) {
                ForEach(documents) { document in
                    TabItemView(document: document, width: tabWidth)
                }
            }
        }
        .padding(2)
        .frame(width: laneWidth, alignment: .leading)
        .background(
            isDropTargeted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .dropDestination(for: URL.self) { urls, _ in
            store.moveFiles(urls, to: nil)
        } isTargeted: {
            isDropTargeted = $0
        }
        .help("Drag Markdown tabs here to remove their project group")
    }
}

private struct TabItemView: View {
    @EnvironmentObject private var store: DocumentStore
    @ObservedObject var document: MarkdownDocument
    let width: CGFloat
    @State private var isHovered = false

    var body: some View {
        Button {
            store.selectedID = document.id
        } label: {
            HStack(spacing: compact ? 4 : 7) {
                if !veryCompact {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }
                Text(document.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if document.isDirty {
                    Circle()
                        .frame(width: 6, height: 6)
                        .foregroundStyle(.orange)
                }
                if !compact, !document.attentionResults.isEmpty {
                    TabReadingBadge(
                        count: document.attentionSuggestionCount,
                        color: .purple,
                        opacity: document.attentionResultsAreStale ? 0.4 : 1
                    )
                }
                if !compact, document.changedCount > 0 {
                    TabReadingBadge(count: document.changedCount, color: .orange)
                } else if !compact, document.unreadCount > 0 {
                    TabReadingBadge(count: document.unreadCount, color: .blue)
                }
                if showCloseButton {
                    Button {
                        store.close(id: document.id)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption2.bold())
                            .frame(width: 12, height: 16)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            }
            .padding(.horizontal, compact ? 6 : 9)
            .frame(width: width, height: 32)
            .background(
                store.selectedID == document.id
                    ? Color.accentColor.opacity(0.16)
                    : (isHovered ? Color.primary.opacity(0.055) : Color.clear),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(document.url.path)
        .draggable(document.url) {
            HStack(spacing: 7) {
                Image(systemName: "doc.text")
                Text(document.displayName)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .contextMenu {
            Menu("Move to Project Group") {
                Button("Ungrouped") {
                    store.assign(document, to: nil)
                }
                Divider()
                ForEach(store.groups) { group in
                    Button {
                        store.assign(document, to: group.id)
                    } label: {
                        if store.group(for: document)?.id == group.id {
                            Label(group.name, systemImage: "checkmark")
                        } else {
                            Text(group.name)
                        }
                    }
                }
            }
            Button("New File in This Folder…") {
                store.newDocument(
                    in: document.url.deletingLastPathComponent(),
                    groupID: store.group(for: document)?.id
                )
            }
            Button("New Group from This Folder…") {
                store.createGroup(assigning: document)
            }
            Divider()
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([document.url])
            }
            Button("Close Tab") {
                store.close(id: document.id)
            }
        }
    }

    private var compact: Bool { width < 132 }
    private var veryCompact: Bool { width < 96 }
    private var showCloseButton: Bool {
        store.selectedID == document.id || isHovered || width >= 150
    }
}

private struct TabStripMetrics {
    let availableWidth: CGFloat
    let groups: [(collapsed: Bool, count: Int)]
    let ungroupedCount: Int

    let laneSpacing: CGFloat = 6
    let tabSpacing: CGFloat = 2
    let horizontalPadding: CGFloat = 16
    let addButtonWidth: CGFloat = 34
    let collapsedLaneWidth: CGFloat = 124
    let emptyLaneWidth: CGFloat = 124
    let minimumTabWidth: CGFloat = 72
    let maximumTabWidth: CGFloat = 220
    let minimumExpandedLaneWidth: CGFloat = 72

    var tabWidth: CGFloat {
        guard visibleTabCount > 0 else { return maximumTabWidth }
        let availableForTabs = max(
            0,
            availableWidth -
                horizontalPadding -
                addButtonWidth -
                fixedLaneWidth -
                totalLaneSpacing -
                totalTabSpacing
        )
        return min(maximumTabWidth, max(minimumTabWidth, availableForTabs / CGFloat(visibleTabCount)))
    }

    var requiresScrolling: Bool {
        requiredContentWidth > availableWidth
    }

    func laneWidth(tabCount: Int, collapsed: Bool) -> CGFloat {
        if collapsed { return collapsedLaneWidth }
        if tabCount == 0 { return emptyLaneWidth }
        return max(
            minimumExpandedLaneWidth,
            CGFloat(tabCount) * tabWidth + CGFloat(max(0, tabCount - 1)) * tabSpacing
        )
    }

    private var visibleTabCount: Int {
        groups.reduce(ungroupedCount) { partial, group in
            partial + (group.collapsed ? 0 : group.count)
        }
    }

    private var fixedLaneWidth: CGFloat {
        groups.reduce(0) { partial, group in
            if group.collapsed { return partial + collapsedLaneWidth }
            if group.count == 0 { return partial + emptyLaneWidth }
            return partial
        }
    }

    private var laneCount: Int {
        groups.count + (ungroupedCount > 0 ? 1 : 0) + 1
    }

    private var totalLaneSpacing: CGFloat {
        CGFloat(max(0, laneCount - 1)) * laneSpacing
    }

    private var totalTabSpacing: CGFloat {
        let expandedGroupSpacing = groups.reduce(0) { partial, group in
            partial + (group.collapsed ? 0 : max(0, group.count - 1))
        }
        return CGFloat(expandedGroupSpacing + max(0, ungroupedCount - 1)) * tabSpacing
    }

    private var requiredContentWidth: CGFloat {
        let groupWidths = groups.reduce(0) { partial, group in
            partial + laneWidth(tabCount: group.count, collapsed: group.collapsed)
        }
        let ungroupedWidth = ungroupedCount > 0
            ? laneWidth(tabCount: ungroupedCount, collapsed: false)
            : 0
        return horizontalPadding +
            groupWidths +
            ungroupedWidth +
            totalLaneSpacing +
            addButtonWidth
    }
}

private struct TabReadingBadge: View {
    let count: Int
    let color: Color
    var opacity = 1.0

    var body: some View {
        Text("\(count)")
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
            .opacity(opacity)
    }
}
