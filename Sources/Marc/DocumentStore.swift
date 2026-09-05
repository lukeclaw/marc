import AppKit
import Combine
import Foundation
import MarcCore
import UniformTypeIdentifiers

@MainActor
final class MarkdownDocument: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var content: String {
        didSet {
            parsedDocument = MarkdownParser.parse(content, baseURL: url)
            reconcileReadingState(for: parsedDocument, origin: contentOrigin)
            if attentionState == .running {
                attentionTask?.cancel()
                attentionTask = nil
                attentionState = .idle
                attentionProgress = 0
                attentionProcessedChunks = 0
                attentionTotalChunks = 0
            }
        }
    }
    @Published var savedContent: String
    @Published var preferences: FilePreferences
    @Published var externalConflict = false
    @Published var findText = ""
    @Published var currentMatch = 0
    @Published private(set) var parsedDocument: ParsedMarkdown
    @Published var attentionState: AttentionRunState = .idle
    @Published var attentionProgress = 0.0
    @Published var attentionProcessedChunks = 0
    @Published var attentionTotalChunks = 0
    @Published var attentionResults: [AttentionResult] = []
    @Published var attentionRevision: String?

    private(set) var lastKnownModificationDate: Date?
    var attentionTask: Task<Void, Never>?

    /// Where the next `content` assignment comes from. Text the reader typed is
    /// already read; text a writer outside marc produced is not.
    private var contentOrigin: ReadingUpdateOrigin = .localEdit

    init(url: URL, content: String, preferences: FilePreferences) {
        let parsed = MarkdownParser.parse(content, baseURL: url)
        var migratedPreferences = preferences
        if (migratedPreferences.tableWidthLayoutVersion ?? 1) < 2 {
            migratedPreferences.tableColumnWidths = migratedPreferences.tableColumnWidths?.mapValues { widths in
                widths.map { $0 + 24 }
            }
            migratedPreferences.tableWidthLayoutVersion = 2
        }
        self.url = url.standardizedFileURL
        self.content = content
        self.savedContent = content
        self.preferences = migratedPreferences
        self.parsedDocument = parsed
        self.lastKnownModificationDate = Self.modificationDate(for: url)
        reconcileReadingState(for: parsed, origin: .external)
    }

    deinit {
        attentionTask?.cancel()
    }

    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var isDirty: Bool { content != savedContent }
    var parsed: ParsedMarkdown { parsedDocument }
    var pendingReadingBlocks: [MarkdownBlock] {
        trackableBlocks(in: parsed).filter { readingStatus(for: $0) != .read }
    }
    var unreadCount: Int {
        pendingReadingBlocks.filter { readingStatus(for: $0) == .unread }.count
    }
    var changedCount: Int {
        pendingReadingBlocks.filter { readingStatus(for: $0) == .changed }.count
    }

    func markSaved() {
        savedContent = content
        lastKnownModificationDate = Self.modificationDate(for: url)
        externalConflict = false
    }

    func checkForExternalChanges() {
        guard let diskDate = Self.modificationDate(for: url) else { return }
        guard diskDate > (lastKnownModificationDate ?? .distantPast) else { return }
        if isDirty {
            externalConflict = true
        } else {
            reloadFromDisk()
        }
    }

    func hasUnseenDiskChange() -> Bool {
        guard let diskDate = Self.modificationDate(for: url) else { return false }
        return diskDate > (lastKnownModificationDate ?? .distantPast)
    }

    func reloadFromDisk() {
        do {
            let diskContent = try String(contentsOf: url, encoding: .utf8)
            contentOrigin = .external
            content = diskContent
            contentOrigin = .localEdit
            savedContent = diskContent
            lastKnownModificationDate = Self.modificationDate(for: url)
            externalConflict = false
        } catch {
            externalConflict = true
        }
    }

    func keepLocalVersion() {
        lastKnownModificationDate = Self.modificationDate(for: url)
        externalConflict = false
    }

    func readingStatus(for block: MarkdownBlock) -> BlockReadingStatus {
        guard isTrackable(block), let state = preferences.readingState else { return .read }
        let key = versionKey(for: block)
        if state.readVersions.contains(key) { return .read }
        if state.changedVersions.contains(key) { return .changed }
        return .unread
    }

    func markBlockRead(_ blockID: String) {
        markBlocksRead([blockID])
    }

    /// Marks several blocks at once. Scrolling can retire a screenful of blocks
    /// in a single update, and each separate write would persist preferences.
    func markBlocksRead(_ blockIDs: [String]) {
        let wanted = Set(blockIDs)
        let keys = trackableBlocks(in: parsed).filter { wanted.contains($0.id) }.map(versionKey)
        guard !keys.isEmpty else { return }
        if let state = preferences.readingState,
           keys.allSatisfy(state.readVersions.contains),
           state.changedVersions.isDisjoint(with: keys) {
            return
        }
        updateReadingState { state in
            state.readVersions.formUnion(keys)
            state.changedVersions.subtract(keys)
        }
    }

    func markSectionRead(_ headingID: String) {
        let blocks = trackableBlocks(in: parsed).filter {
            $0.id == headingID || $0.ancestorHeadingIDs.contains(headingID)
        }
        updateReadingState { state in
            for block in blocks {
                let key = versionKey(for: block)
                state.readVersions.insert(key)
                state.changedVersions.remove(key)
            }
        }
    }

    func markSectionUnread(_ headingID: String) {
        let blocks = trackableBlocks(in: parsed).filter {
            $0.id == headingID || $0.ancestorHeadingIDs.contains(headingID)
        }
        updateReadingState { state in
            for block in blocks {
                let key = versionKey(for: block)
                state.readVersions.remove(key)
                state.changedVersions.remove(key)
            }
        }
    }

    func markAllRead() {
        let blocks = trackableBlocks(in: parsed)
        updateReadingState { state in
            state.readVersions.formUnion(blocks.map(versionKey))
            state.changedVersions.removeAll()
        }
    }

    /// Brings the stored reading state in line with a freshly parsed document.
    ///
    /// Blocks that survive an edit unchanged keep their state. A block that was
    /// edited is matched to the block that previously stood in its place, so a
    /// revision is distinguishable from genuinely new content. Revisions the
    /// reader typed are already read; revisions an outside writer produced are
    /// marked updated when the previous version had been read, and unread when
    /// it had not.
    private func reconcileReadingState(for parsed: ParsedMarkdown, origin: ReadingUpdateOrigin) {
        let currentBlocks = trackableBlocks(in: parsed)
        guard var state = preferences.readingState else {
            preferences.readingState = initialReadingState(for: currentBlocks)
            return
        }

        let previousRead = state.readVersions
        let changes = ReadingAlignment.align(
            previous: state.baseline.map(\.identity),
            current: currentBlocks.map(\.readingIdentity)
        )
        let previousSignatures = Dictionary(
            state.baseline.map { ($0.id, $0.signature) },
            uniquingKeysWith: { first, _ in first }
        )

        let currentKeys = Set(currentBlocks.map(versionKey))
        state.readVersions.formIntersection(currentKeys)
        state.changedVersions.formIntersection(currentKeys)

        for (index, change) in changes.enumerated() where index < currentBlocks.count {
            let block = currentBlocks[index]
            let key = versionKey(for: block)

            switch change {
            case .unchanged:
                continue

            case let .revised(_, previousID):
                if origin == .localEdit {
                    state.readVersions.insert(key)
                    state.changedVersions.remove(key)
                } else {
                    let previousKey = previousSignatures[previousID].map { "\(previousID)|\($0)" }
                    let wasRead = previousKey.map(previousRead.contains) ?? false
                    state.readVersions.remove(key)
                    if wasRead {
                        state.changedVersions.insert(key)
                    } else {
                        state.changedVersions.remove(key)
                    }
                }

            case .inserted:
                if origin == .localEdit {
                    state.readVersions.insert(key)
                    state.changedVersions.remove(key)
                } else {
                    state.readVersions.remove(key)
                    state.changedVersions.remove(key)
                }
            }
        }

        state.baseline = currentBlocks.map(Self.revision)
        guard state != preferences.readingState else { return }
        preferences.readingState = state
    }

    private func initialReadingState(for blocks: [MarkdownBlock]) -> ReadingState {
        ReadingState(
            baseline: blocks.map(Self.revision),
            readVersions: [],
            changedVersions: []
        )
    }

    private static func revision(for block: MarkdownBlock) -> ReadingBlockRevision {
        ReadingBlockRevision(
            id: block.id,
            signature: block.signature,
            kind: block.typeName,
            section: block.sectionID
        )
    }

    private func updateReadingState(_ update: (inout ReadingState) -> Void) {
        var state = preferences.readingState ?? initialReadingState(for: trackableBlocks(in: parsed))
        update(&state)
        preferences.readingState = state
    }

    private func trackableBlocks(in parsed: ParsedMarkdown) -> [MarkdownBlock] {
        parsed.blocks.filter(isTrackable)
    }

    private func isTrackable(_ block: MarkdownBlock) -> Bool {
        if case .horizontalRule = block.kind { return false }
        return true
    }

    private func versionKey(for block: MarkdownBlock) -> String {
        "\(block.id)|\(block.signature)"
    }

    private static func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

@MainActor
final class ThemeStore {
    private var values: [String: FilePreferences] = [:]
    private let fileURL: URL
    private let writeQueue = DispatchQueue(label: "marc.preferences.write", qos: .utility)

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("marc", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("file-preferences.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: FilePreferences].self, from: data) {
            values = decoded
        }
    }

    func preferences(for url: URL) -> FilePreferences {
        values[url.standardizedFileURL.path] ?? FilePreferences()
    }

    func save(_ preferences: FilePreferences, for url: URL) {
        values[url.standardizedFileURL.path] = preferences
        guard let data = try? JSONEncoder().encode(values) else { return }
        let destination = fileURL
        writeQueue.async {
            try? data.write(to: destination, options: .atomic)
        }
    }
}

@MainActor
final class DocumentStore: ObservableObject {
    @Published var documents: [MarkdownDocument] = []
    @Published var selectedID: UUID? {
        didSet {
            if !isRestoringSession {
                persistSession()
            }
        }
    }
    @Published var errorMessage: String?
    @Published var recentURLs: [URL] = []
    @Published private(set) var groups: [DocumentGroup] = []
    @Published private(set) var groupAssignments: [String: UUID] = [:]
    @Published var tabSortOrder: TabSortOrder = .opened {
        didSet {
            UserDefaults.standard.set(tabSortOrder.rawValue, forKey: tabSortKey)
        }
    }

    private let themeStore = ThemeStore()
    private var cancellables: [UUID: Set<AnyCancellable>] = [:]
    private var autosaveTasks: [UUID: Task<Void, Never>] = [:]
    private var monitorTimer: Timer?
    private var terminationObserver: NSObjectProtocol?
    private var isRestoringSession = false
    private let recentKey = "recentMarkdownFiles"
    private let tabSortKey = "tabSortOrder"
    private let groupingFileURL: URL
    private let sessionFileURL: URL

    private struct GroupingState: Codable {
        var groups: [DocumentGroup]
        var assignments: [String: UUID]
    }

    private struct SessionState: Codable {
        var openPaths: [String]
        var selectedPath: String?
    }

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("marc", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        groupingFileURL = support.appendingPathComponent("workspace-groups.json")
        sessionFileURL = support.appendingPathComponent("workspace-session.json")

        if let data = try? Data(contentsOf: groupingFileURL),
           let state = try? JSONDecoder().decode(GroupingState.self, from: data) {
            groups = state.groups
            let validGroupIDs = Set(state.groups.map(\.id))
            groupAssignments = state.assignments.filter { validGroupIDs.contains($0.value) }
        }

        tabSortOrder = TabSortOrder(
            rawValue: UserDefaults.standard.string(forKey: tabSortKey) ?? ""
        ) ?? .opened

        recentURLs = (UserDefaults.standard.array(forKey: recentKey) as? [String] ?? [])
            .map(URL.init(fileURLWithPath:))
            .filter { FileManager.default.fileExists(atPath: $0.path) }

        restoreSession()

        monitorTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.documents.forEach { $0.checkForExternalChanges() } }
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.flushForTermination()
            }
        }
    }

    deinit {
        monitorTimer?.invalidate()
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    var selectedDocument: MarkdownDocument? {
        guard let selectedID else { return nil }
        return documents.first { $0.id == selectedID }
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "md"),
            UTType(filenameExtension: "markdown"),
            .plainText
        ].compactMap { $0 }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in panel.urls.forEach { self?.open(url: $0) } }
        }
    }

    static let markdownExtensions = ["md", "markdown", "mdown", "mkd"]

    /// Asks for a location, writes a starter file there, and opens it as a tab.
    func newDocument(in folder: URL? = nil, groupID: UUID? = nil, suggestedName: String = "Untitled.md") {
        let panel = NSSavePanel()
        panel.title = "New Markdown File"
        panel.prompt = "Create"
        panel.nameFieldLabel = "File name:"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [UTType(filenameExtension: "md"), .plainText].compactMap { $0 }
        if let folder {
            panel.directoryURL = folder
        } else if let current = selectedDocument?.url.deletingLastPathComponent() {
            panel.directoryURL = current
        }
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.createDocument(at: url, groupID: groupID) }
        }
    }

    /// Creates the file at `url` if it is missing, then opens it.
    @discardableResult
    func createDocument(at url: URL, groupID: UUID? = nil) -> Bool {
        var target = url.standardizedFileURL
        if !Self.markdownExtensions.contains(target.pathExtension.lowercased()) {
            target.appendPathExtension("md")
        }

        if !FileManager.default.fileExists(atPath: target.path) {
            let title = target.deletingPathExtension().lastPathComponent
            do {
                try FileManager.default.createDirectory(
                    at: target.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try "# \(title)\n\n".write(to: target, atomically: true, encoding: .utf8)
            } catch {
                errorMessage = "Could not create \(target.lastPathComponent): \(error.localizedDescription)"
                return false
            }
        }

        open(url: target)
        if let groupID, let document = documents.first(where: { $0.url == target }) {
            assign(document, to: groupID)
        }
        return true
    }

    /// Opens a Markdown link, offering to create the file when it does not exist yet.
    func openLink(_ url: URL, from document: MarkdownDocument) {
        let resolved = url.isFileURL
            ? url.standardizedFileURL
            : document.url.deletingLastPathComponent()
                .appendingPathComponent(url.relativePath)
                .standardizedFileURL
        if FileManager.default.fileExists(atPath: resolved.path) {
            open(url: resolved)
        } else {
            offerToCreate(at: resolved, groupID: group(for: document)?.id)
        }
    }

    private func offerToCreate(at url: URL, groupID: UUID? = nil) {
        let alert = NSAlert()
        alert.messageText = "Create “\(url.lastPathComponent)”?"
        alert.informativeText = "This link points to a file that does not exist yet in \(url.deletingLastPathComponent().path)."
        alert.addButton(withTitle: "Create File")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        createDocument(at: url, groupID: groupID)
    }

    func open(url: URL) {
        let normalized = url.standardizedFileURL
        if let existing = documents.first(where: { $0.url == normalized }) {
            selectedID = existing.id
            return
        }

        do {
            let content = try String(contentsOf: normalized, encoding: .utf8)
            let document = MarkdownDocument(
                url: normalized,
                content: content,
                preferences: themeStore.preferences(for: normalized)
            )
            documents.append(document)
            selectedID = document.id
            automaticallyAssignGroup(to: document)
            expandGroupContaining(document)
            observe(document)
            themeStore.save(document.preferences, for: normalized)
            if !isRestoringSession {
                recordRecent(normalized)
                persistSession()
            }
        } catch {
            errorMessage = "Could not open \(normalized.lastPathComponent): \(error.localizedDescription)"
        }
    }

    func open(reference: MarkdownReference, in document: MarkdownDocument? = nil) {
        guard let url = reference.resolvedURL else { return }
        guard reference.exists else {
            offerToCreate(at: url, groupID: document.flatMap { group(for: $0)?.id })
            return
        }
        open(url: url)
    }

    func createFile(for reference: MarkdownReference, in document: MarkdownDocument? = nil) {
        guard let url = reference.resolvedURL else { return }
        createDocument(at: url, groupID: document.flatMap { group(for: $0)?.id })
    }

    func saveSelected() {
        guard let document = selectedDocument else { return }
        save(document)
    }

    @discardableResult
    func save(_ document: MarkdownDocument, force: Bool = false) -> Bool {
        if !document.isDirty {
            return true
        }
        if !force && document.isDirty && document.hasUnseenDiskChange() {
            document.externalConflict = true
            return false
        }

        do {
            try document.content.write(to: document.url, atomically: true, encoding: .utf8)
            document.markSaved()
            return true
        } catch {
            errorMessage = "Could not save \(document.url.lastPathComponent): \(error.localizedDescription)"
            return false
        }
    }

    func overwriteWithLocalVersion(_ document: MarkdownDocument) {
        document.keepLocalVersion()
        save(document, force: true)
    }

    func closeSelected() {
        guard let selectedID else { return }
        close(id: selectedID)
    }

    func close(id: UUID) {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return }
        if documents[index].isDirty {
            let alert = NSAlert()
            alert.messageText = "Save changes to \(documents[index].url.lastPathComponent)?"
            alert.informativeText = "Your changes will be lost if you close without saving."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don’t Save")
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                guard save(documents[index]) else { return }
            } else if response == .alertSecondButtonReturn {
                return
            }
        }

        cancellables[id] = nil
        autosaveTasks[id]?.cancel()
        autosaveTasks[id] = nil
        documents.remove(at: index)
        if self.selectedID == id {
            self.selectedID = documents.indices.contains(index)
                ? documents[index].id
                : documents.last?.id
        }
        persistSession()
    }

    func group(for document: MarkdownDocument) -> DocumentGroup? {
        guard let groupID = groupAssignments[document.url.standardizedFileURL.path] else { return nil }
        return groups.first { $0.id == groupID }
    }

    func groupDocuments(_ groupID: UUID?) -> [MarkdownDocument] {
        let matching = documents.filter { document in
            groupAssignments[document.url.standardizedFileURL.path] == groupID
        }
        switch tabSortOrder {
        case .opened:
            return matching
        case .name:
            return matching.sorted {
                $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
            }
        case .folder:
            return matching.sorted {
                let left = $0.url.deletingLastPathComponent().path
                let right = $1.url.deletingLastPathComponent().path
                if left == right {
                    return $0.url.lastPathComponent.localizedCaseInsensitiveCompare($1.url.lastPathComponent) == .orderedAscending
                }
                return left.localizedCaseInsensitiveCompare(right) == .orderedAscending
            }
        }
    }

    func createGroup(assigning document: MarkdownDocument? = nil) {
            let alert = NSAlert()
            alert.messageText = "New Project Group"
            alert.informativeText = "Group related Markdown tabs and optionally auto-assign files from the same folder."
            alert.addButton(withTitle: "Create")
            alert.addButton(withTitle: "Cancel")

            let nameField = NSTextField(string: suggestedGroupName(for: document))
            nameField.placeholderString = "Group name"
            let folderCheckbox = NSButton(
                checkboxWithTitle: "Automatically include files from this folder",
                target: nil,
                action: nil
            )
            folderCheckbox.state = document == nil ? .off : .on
            folderCheckbox.isEnabled = document != nil

            let stack = NSStackView(views: [nameField, folderCheckbox])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 10
            stack.frame = NSRect(x: 0, y: 0, width: 360, height: 54)
            nameField.frame.size.width = 360
            alert.accessoryView = stack

            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                errorMessage = "A project group needs a name."
                return
            }

            let palette = ["#4F6BED", "#8B5CF6", "#0F9D8A", "#D97706", "#DC5A6A", "#457B9D"]
            let folderPath = folderCheckbox.state == .on
                ? document?.url.deletingLastPathComponent().standardizedFileURL.path
                : nil
            let group = DocumentGroup(
                id: UUID(),
                name: name,
                folderPath: folderPath,
                colorHex: palette[groups.count % palette.count],
                isCollapsed: false
            )
            groups.append(group)
            if let document {
                groupAssignments[document.url.standardizedFileURL.path] = group.id
            }
            persistGrouping()
    }

    func renameGroup(_ group: DocumentGroup) {
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            let alert = NSAlert()
            alert.messageText = "Rename Project Group"
            alert.addButton(withTitle: "Rename")
            alert.addButton(withTitle: "Cancel")
            let nameField = NSTextField(string: group.name)
            nameField.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
            alert.accessoryView = nameField
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return }
            groups[index].name = name
            persistGrouping()
    }

    func deleteGroup(_ group: DocumentGroup) {
            let alert = NSAlert()
            alert.messageText = "Delete “\(group.name)”?"
            alert.informativeText = "Its files will become ungrouped. No files will be deleted."
            alert.addButton(withTitle: "Delete Group")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            groups.removeAll { $0.id == group.id }
            groupAssignments = groupAssignments.filter { $0.value != group.id }
            persistGrouping()
    }

    func assign(_ document: MarkdownDocument, to groupID: UUID?) {
            let path = document.url.standardizedFileURL.path
            if let groupID {
                groupAssignments[path] = groupID
                if let index = groups.firstIndex(where: { $0.id == groupID }) {
                    groups[index].isCollapsed = false
                }
            } else {
                groupAssignments[path] = nil
            }
            persistGrouping()
    }

    func toggleGroup(_ group: DocumentGroup) {
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            groups[index].isCollapsed.toggle()
            persistGrouping()
    }

    func moveGroup(_ group: DocumentGroup, by offset: Int) {
            guard let index = groups.firstIndex(where: { $0.id == group.id }) else { return }
            let destination = index + offset
            guard groups.indices.contains(destination) else { return }
            groups.swapAt(index, destination)
            persistGrouping()
    }

    func moveFiles(_ urls: [URL], to groupID: UUID?) -> Bool {
            var movedAny = false
            for url in urls {
                let normalized = url.standardizedFileURL
                guard ["md", "markdown", "mdown", "mkd"].contains(normalized.pathExtension.lowercased()) else {
                    continue
                }
                open(url: normalized)
                guard let document = documents.first(where: { $0.url == normalized }) else { continue }
                assign(document, to: groupID)
                movedAny = true
            }
            return movedAny
    }

    func updatePreferences(for document: MarkdownDocument) {
        themeStore.save(document.preferences, for: document.url)
    }

    func revealSelectedInFinder() {
        guard let url = selectedDocument?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func copySelectedPath() {
        guard let path = selectedDocument?.url.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func adjustSelectedFontSize(by amount: Double) {
        guard let document = selectedDocument else { return }
        document.preferences.theme.bodySize = min(72, max(8, document.preferences.theme.bodySize + amount))
        document.preferences.theme.id = "custom"
        document.preferences.theme.name = "Custom"
    }

    func resetSelectedFontSize() {
        guard let document = selectedDocument else { return }
        document.preferences.theme.bodySize = 16
        document.preferences.theme.id = "custom"
        document.preferences.theme.name = "Custom"
    }

    private func observe(_ document: MarkdownDocument) {
        var subscriptions = Set<AnyCancellable>()

        document.$content
            .dropFirst()
            .sink { [weak self, weak document] _ in
                guard let self, let document else { return }
                self.autosaveTasks[document.id]?.cancel()
                self.autosaveTasks[document.id] = Task { [weak self, weak document] in
                    try? await Task.sleep(for: .milliseconds(700))
                    guard !Task.isCancelled, let self, let document else { return }
                    self.save(document)
                }
            }
            .store(in: &subscriptions)

        document.$preferences
            .dropFirst()
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self, weak document] _ in
                guard let self, let document else { return }
                self.updatePreferences(for: document)
            }
            .store(in: &subscriptions)

        cancellables[document.id] = subscriptions
    }

    private func recordRecent(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        recentURLs.insert(url, at: 0)
        recentURLs = Array(recentURLs.prefix(12))
        UserDefaults.standard.set(recentURLs.map(\.path), forKey: recentKey)
    }

    private func restoreSession() {
        guard
            let data = try? Data(contentsOf: sessionFileURL),
            let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return }

        isRestoringSession = true
        for path in state.openPaths.prefix(100) {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            open(url: url)
        }
        if let selectedPath = state.selectedPath,
           let selected = documents.first(where: { $0.url.path == selectedPath }) {
            selectedID = selected.id
        }
        isRestoringSession = false
        persistSession()
    }

    private func persistSession() {
        guard !isRestoringSession else { return }
        let state = SessionState(
            openPaths: documents.map(\.url.path),
            selectedPath: selectedDocument?.url.path
        )
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: sessionFileURL, options: .atomic)
        } catch {
            errorMessage = "Could not save the open-tab session: \(error.localizedDescription)"
        }
    }

    private func flushForTermination() {
        autosaveTasks.values.forEach { $0.cancel() }
        autosaveTasks.removeAll()
        for document in documents {
            if document.isDirty {
                save(document)
            }
            themeStore.save(document.preferences, for: document.url)
        }
        persistSession()
    }

    private func suggestedGroupName(for document: MarkdownDocument?) -> String {
        document?.url.deletingLastPathComponent().lastPathComponent ?? "New Project"
    }

    private func automaticallyAssignGroup(to document: MarkdownDocument) {
        let path = document.url.standardizedFileURL.path
        guard groupAssignments[path] == nil else { return }
        let matchingGroup = groups
            .compactMap { group -> (DocumentGroup, Int)? in
                guard let folderPath = group.folderPath else { return nil }
                let prefix = folderPath.hasSuffix("/") ? folderPath : "\(folderPath)/"
                guard path.hasPrefix(prefix) else { return nil }
                return (group, folderPath.count)
            }
            .max { $0.1 < $1.1 }?
            .0
        if let matchingGroup {
            groupAssignments[path] = matchingGroup.id
            persistGrouping()
        }
    }

    private func expandGroupContaining(_ document: MarkdownDocument) {
        guard
            let groupID = groupAssignments[document.url.standardizedFileURL.path],
            let index = groups.firstIndex(where: { $0.id == groupID }),
            groups[index].isCollapsed
        else { return }
        groups[index].isCollapsed = false
        persistGrouping()
    }

    private func persistGrouping() {
        let state = GroupingState(groups: groups, assignments: groupAssignments)
        guard let data = try? JSONEncoder().encode(state) else {
            errorMessage = "Could not encode project groups."
            return
        }
        do {
            try data.write(to: groupingFileURL, options: .atomic)
        } catch {
            errorMessage = "Could not save project groups: \(error.localizedDescription)"
        }
    }
}
