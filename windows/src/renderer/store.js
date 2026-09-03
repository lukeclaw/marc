/*
 * marc — document model and workspace store.
 *
 * Port of Sources/Marc/DocumentStore.swift (MarkdownDocument, ThemeStore,
 * DocumentStore) plus Sources/Marc/AttentionController.swift. SwiftUI's
 * @Published reactivity is replaced by explicit change regions: mutating code
 * calls `emit()` with the parts of the UI that need to be rebuilt.
 */
"use strict";

const AUTOSAVE_DELAY = 700;
const PREFERENCES_DELAY = 200;
const EXTERNAL_POLL_INTERVAL = 2000;
const RECENT_LIMIT = 12;

const PREFERENCES_FILE = "file-preferences.json";
const GROUPS_FILE = "workspace-groups.json";
const SESSION_FILE = "workspace-session.json";
const SETTINGS_FILE = "settings.json";

function normalizePath(value) {
  return window.marc.path.resolve(value);
}

// Windows paths are case-insensitive, so map keys are folded while the
// displayed path keeps the casing the user sees in Explorer.
function pathKey(value) {
  return normalizePath(value).toLowerCase();
}

function isMarkdownPath(value) {
  const extension = window.marc.path.extname(value).replace(".", "").toLowerCase();
  return MarcModels.MARKDOWN_EXTENSIONS.includes(extension);
}

function uuid() {
  return crypto.randomUUID();
}

/* ------------------------------------------------------------------ document */

class MarkdownDocument {
  constructor(filePath, content, preferences, modified) {
    this.id = uuid();
    this.path = normalizePath(filePath);
    this.key = pathKey(filePath);
    this.savedContent = content;
    this.preferences = preferences;
    this.externalConflict = false;
    this.findText = "";
    this.currentMatch = 0;
    this.lastKnownModification = modified ?? null;

    this.attentionState = "idle";
    this.attentionMessage = "";
    this.attentionProgress = 0;
    this.attentionProcessedChunks = 0;
    this.attentionTotalChunks = 0;
    this.attentionResults = [];
    this.attentionRevision = null;
    this.attentionRun = null;

    // Migration carried over from the macOS build: layout version 1 stored
    // column widths that excluded cell padding.
    if ((this.preferences.tableWidthLayoutVersion ?? 1) < 2) {
      if (this.preferences.tableColumnWidths !== null) {
        for (const [key, widths] of Object.entries(this.preferences.tableColumnWidths)) {
          this.preferences.tableColumnWidths[key] = widths.map((width) => width + 24);
        }
      }
      this.preferences.tableWidthLayoutVersion = 2;
    }

    this._content = content;
    this._parsed = this.parse(content);
    this.reconcileReadingState(this._parsed);
  }

  parse(content) {
    const directory = window.marc.path.dirname(this.path);
    return MarcParser.parse(content, (relative) =>
      normalizePath(window.marc.path.join(directory, relative))
    );
  }

  get content() {
    return this._content;
  }

  set content(value) {
    if (value === this._content) return;
    this._content = value;
    this._parsed = this.parse(value);
    // Editing invalidates a run in flight (AttentionAnalysisController parity).
    if (this.attentionState === "running") {
      this.cancelAttentionAnalysis();
    }
  }

  get parsed() {
    return this._parsed;
  }

  get fileName() {
    return window.marc.path.basename(this.path);
  }

  get displayName() {
    return window.marc.path.basename(this.path, window.marc.path.extname(this.path));
  }

  get isDirty() {
    return this._content !== this.savedContent;
  }

  get theme() {
    return this.preferences.theme;
  }

  markSaved(modified) {
    this.savedContent = this._content;
    this.lastKnownModification = modified ?? this.lastKnownModification;
    this.externalConflict = false;
  }

  hasUnseenDiskChange(diskModification) {
    if (diskModification === null || diskModification === undefined) return false;
    return diskModification > (this.lastKnownModification ?? -Infinity);
  }

  keepLocalVersion(diskModification) {
    this.lastKnownModification = diskModification ?? this.lastKnownModification;
    this.externalConflict = false;
  }

  /* ------------------------------------------------------- reading state */

  isTrackable(block) {
    return block.kind.type !== "horizontalRule";
  }

  trackableBlocks(parsed) {
    return parsed.blocks.filter((block) => this.isTrackable(block));
  }

  versionKey(block) {
    return `${block.id}|${block.signature}`;
  }

  readingStatus(block) {
    if (!this.isTrackable(block) || this.preferences.readingState === null) return "read";
    const key = this.versionKey(block);
    if (this.preferences.readingState.readVersions.has(key)) return "read";
    if (this.preferences.readingState.changedVersions.has(key)) return "changed";
    return "unread";
  }

  get pendingReadingBlocks() {
    return this.trackableBlocks(this._parsed).filter((block) => this.readingStatus(block) !== "read");
  }

  get unreadCount() {
    return this.pendingReadingBlocks.filter((block) => this.readingStatus(block) === "unread").length;
  }

  get changedCount() {
    return this.pendingReadingBlocks.filter((block) => this.readingStatus(block) === "changed").length;
  }

  initialReadingState(blocks) {
    return {
      baseline: blocks.map((block) => ({ id: block.id, signature: block.signature })),
      readVersions: new Set(),
      changedVersions: new Set()
    };
  }

  updateReadingState(update) {
    if (this.preferences.readingState === null) {
      this.preferences.readingState = this.initialReadingState(this.trackableBlocks(this._parsed));
    }
    update(this.preferences.readingState);
  }

  markBlockRead(blockID) {
    const block = this._parsed.blocks.find((candidate) => candidate.id === blockID);
    if (block === undefined || !this.isTrackable(block)) return false;
    const key = this.versionKey(block);
    if (this.preferences.readingState !== null && this.preferences.readingState.readVersions.has(key)) {
      return false;
    }
    this.updateReadingState((state) => {
      state.readVersions.add(key);
      state.changedVersions.delete(key);
    });
    return true;
  }

  sectionBlocks(headingID) {
    return this.trackableBlocks(this._parsed).filter(
      (block) => block.id === headingID || block.ancestorHeadingIDs.includes(headingID)
    );
  }

  markSectionRead(headingID) {
    const blocks = this.sectionBlocks(headingID);
    this.updateReadingState((state) => {
      for (const block of blocks) {
        const key = this.versionKey(block);
        state.readVersions.add(key);
        state.changedVersions.delete(key);
      }
    });
  }

  markSectionUnread(headingID) {
    const blocks = this.sectionBlocks(headingID);
    this.updateReadingState((state) => {
      for (const block of blocks) {
        const key = this.versionKey(block);
        state.readVersions.delete(key);
        state.changedVersions.delete(key);
      }
    });
  }

  markAllRead() {
    const blocks = this.trackableBlocks(this._parsed);
    this.updateReadingState((state) => {
      for (const block of blocks) state.readVersions.add(this.versionKey(block));
      state.changedVersions.clear();
    });
  }

  /*
   * External writers mark touched blocks as *changed*; the reader has not seen
   * the new revision yet.
   */
  reconcileReadingState(parsed) {
    const currentBlocks = this.trackableBlocks(parsed);
    if (this.preferences.readingState === null) {
      this.preferences.readingState = this.initialReadingState(currentBlocks);
      return;
    }
    const state = this.preferences.readingState;
    const oldBaseline = new Map(state.baseline.map((entry) => [entry.id, entry.signature]));
    const currentKeys = new Set(currentBlocks.map((block) => this.versionKey(block)));

    intersect(state.readVersions, currentKeys);
    intersect(state.changedVersions, currentKeys);

    for (const block of currentBlocks) {
      if (oldBaseline.get(block.id) !== block.signature) {
        const key = this.versionKey(block);
        state.readVersions.delete(key);
        state.changedVersions.add(key);
      }
    }
    state.baseline = currentBlocks.map((block) => ({ id: block.id, signature: block.signature }));
  }

  /* The reader wrote these edits, so their blocks count as already read. */
  reconcileAfterLocalSave() {
    const currentBlocks = this.trackableBlocks(this._parsed);
    if (this.preferences.readingState === null) {
      this.preferences.readingState = this.initialReadingState(currentBlocks);
      return;
    }
    const state = this.preferences.readingState;
    const oldBaseline = new Map(state.baseline.map((entry) => [entry.id, entry.signature]));
    const currentKeys = new Set(currentBlocks.map((block) => this.versionKey(block)));

    intersect(state.readVersions, currentKeys);
    intersect(state.changedVersions, currentKeys);

    for (const block of currentBlocks) {
      if (oldBaseline.get(block.id) !== block.signature) {
        const key = this.versionKey(block);
        state.readVersions.add(key);
        state.changedVersions.delete(key);
      }
    }
    state.baseline = currentBlocks.map((block) => ({ id: block.id, signature: block.signature }));
  }

  /* ---------------------------------------------------- attention analysis */

  get currentAttentionRevision() {
    return MarcAttention.documentRevision(this._parsed);
  }

  get attentionResultsAreStale() {
    if (this.attentionRevision === null) return false;
    return this.attentionRevision !== this.currentAttentionRevision;
  }

  get hasCurrentAttentionResults() {
    return this.attentionState === "ready" && this.attentionRevision === this.currentAttentionRevision;
  }

  get attentionSuggestionCount() {
    return new Set(this.attentionResults.map((result) => result.chunkID)).size;
  }

  attentionResultFor(blockID) {
    return this.attentionResults.find((result) => result.blockIDs.includes(blockID)) ?? null;
  }

  cancelAttentionAnalysis() {
    if (this.attentionRun !== null) this.attentionRun.cancelled = true;
    this.attentionRun = null;
    this.attentionProgress = 0;
    this.attentionProcessedChunks = 0;
    this.attentionTotalChunks = 0;
    this.attentionState = "idle";
    this.attentionMessage = "";
  }

  dismissAttentionChunk(chunkID) {
    this.attentionResults = this.attentionResults.filter((result) => result.chunkID !== chunkID);
  }
}

function intersect(target, allowed) {
  for (const value of [...target]) {
    if (!allowed.has(value)) target.delete(value);
  }
}

/* --------------------------------------------------------------------- store */

class DocumentStore {
  constructor() {
    this.documents = [];
    this.selectedID = null;
    this.errorMessage = null;
    this.recentPaths = [];
    this.groups = [];
    this.groupAssignments = {};
    this.settings = { ...MarcModels.DEFAULT_SETTINGS };
    this.preferencesByPath = {};
    this.referenceExistence = new Map();

    this.listeners = [];
    this.autosaveTimers = new Map();
    this.preferenceTimer = null;
    this.pollTimer = null;
    this.isRestoringSession = false;
    this.suspendPersistence = false;
  }

  /* ------------------------------------------------------------ lifecycle */

  async load() {
    this.settings = { ...MarcModels.DEFAULT_SETTINGS, ...(await window.marc.readStore(SETTINGS_FILE, {})) };
    this.preferencesByPath = await window.marc.readStore(PREFERENCES_FILE, {});

    const grouping = await window.marc.readStore(GROUPS_FILE, null);
    if (grouping !== null && Array.isArray(grouping.groups)) {
      this.groups = grouping.groups;
      const valid = new Set(this.groups.map((group) => group.id));
      this.groupAssignments = Object.fromEntries(
        Object.entries(grouping.assignments ?? {}).filter(([, id]) => valid.has(id))
      );
    }

    this.recentPaths = Array.isArray(this.settings.recentMarkdownFiles)
      ? this.settings.recentMarkdownFiles.map(normalizePath)
      : [];
    const existence = await window.marc.exists(this.recentPaths);
    this.recentPaths = this.recentPaths.filter((candidate) => existence[candidate] === true);

    await this.restoreSession();
    this.startPolling();
  }

  startPolling() {
    if (this.pollTimer !== null) return;
    this.pollTimer = setInterval(() => {
      this.checkExternalChanges();
    }, EXTERNAL_POLL_INTERVAL);
  }

  onChange(listener) {
    this.listeners.push(listener);
  }

  emit(...regions) {
    for (const listener of this.listeners) listener(new Set(regions));
  }

  get selectedDocument() {
    if (this.selectedID === null) return null;
    return this.documents.find((document) => document.id === this.selectedID) ?? null;
  }

  documentByID(id) {
    return this.documents.find((document) => document.id === id) ?? null;
  }

  setError(message) {
    this.errorMessage = message;
    this.emit("error");
  }

  /* ---------------------------------------------------------- open / save */

  async showOpenPanel() {
    const files = await window.marc.openDialog();
    for (const file of files) await this.open(file);
  }

  async open(filePath) {
    const normalized = normalizePath(filePath);
    const key = pathKey(normalized);
    const existing = this.documents.find((document) => document.key === key);
    if (existing !== undefined) {
      this.selectedID = existing.id;
      this.persistSession();
      this.emit("tabs", "document", "toc", "graph", "attention", "toolbar");
      return existing;
    }

    const result = await window.marc.readFile(normalized);
    if (!result.ok) {
      this.setError(`Could not open ${window.marc.path.basename(normalized)}: ${result.error}`);
      return null;
    }

    const preferences = MarcModels.normalizePreferences(this.preferencesByPath[key] ?? null);
    const document = new MarkdownDocument(normalized, result.content, preferences, result.modified);
    this.documents.push(document);
    this.selectedID = document.id;
    this.automaticallyAssignGroup(document);
    this.expandGroupContaining(document);
    this.savePreferences(document);
    if (!this.isRestoringSession) {
      this.recordRecent(normalized);
      this.persistSession();
    }
    this.refreshReferenceExistence(document);
    this.emit("tabs", "document", "toc", "graph", "attention", "toolbar", "welcome");
    return document;
  }

  async openReference(reference) {
    if (reference.resolvedPath === null) return;
    const existence = await window.marc.exists([reference.resolvedPath]);
    if (existence[reference.resolvedPath] !== true) {
      this.setError(`Referenced file does not exist: ${reference.destination}`);
      return;
    }
    await this.open(reference.resolvedPath);
  }

  async saveSelected() {
    const document = this.selectedDocument;
    if (document === null) return false;
    return this.save(document);
  }

  async save(document, force) {
    if (!document.isDirty) return true;

    if (force !== true) {
      const stats = await window.marc.stat([document.path]);
      if (document.hasUnseenDiskChange(stats[document.path])) {
        document.externalConflict = true;
        this.emit("banner");
        return false;
      }
    }

    const result = await window.marc.writeFile(document.path, document.content);
    if (!result.ok) {
      this.setError(`Could not save ${document.fileName}: ${result.error}`);
      return false;
    }
    document.markSaved(result.modified);
    document.reconcileAfterLocalSave();
    this.savePreferences(document);
    this.emit("tabs", "banner", "status", "toc", "gutters");
    return true;
  }

  async overwriteWithLocalVersion(document) {
    const stats = await window.marc.stat([document.path]);
    document.keepLocalVersion(stats[document.path]);
    await this.save(document, true);
    this.emit("banner", "tabs");
  }

  async closeSelected() {
    if (this.selectedID === null) return;
    await this.close(this.selectedID);
  }

  async close(id) {
    const index = this.documents.findIndex((document) => document.id === id);
    if (index < 0) return;
    const document = this.documents[index];

    if (document.isDirty) {
      const choice = await window.marc.confirmClose(document.fileName);
      if (choice === "cancel") return;
      if (choice === "save") {
        const saved = await this.save(document);
        if (!saved) return;
      }
    }

    const timer = this.autosaveTimers.get(id);
    if (timer !== undefined) {
      clearTimeout(timer);
      this.autosaveTimers.delete(id);
    }
    document.cancelAttentionAnalysis();
    this.documents.splice(index, 1);

    if (this.selectedID === id) {
      const next = this.documents[index] ?? this.documents[this.documents.length - 1] ?? null;
      this.selectedID = next === null ? null : next.id;
    }
    this.persistSession();
    this.emit("tabs", "document", "toc", "graph", "attention", "toolbar", "welcome", "banner", "status");
  }

  /* --------------------------------------------------------- content edits */

  updateContent(document, value) {
    document.content = value;
    const existing = this.autosaveTimers.get(document.id);
    if (existing !== undefined) clearTimeout(existing);
    this.autosaveTimers.set(
      document.id,
      setTimeout(() => {
        this.autosaveTimers.delete(document.id);
        this.save(document);
      }, AUTOSAVE_DELAY)
    );
    this.refreshReferenceExistence(document);
    this.emit("tabs", "document", "toc", "graph", "attention", "status");
  }

  /* ---------------------------------------------------- external monitoring */

  async checkExternalChanges() {
    if (this.documents.length === 0) return;
    const paths = this.documents.map((document) => document.path);
    const stats = await window.marc.stat(paths);
    let changed = false;

    for (const document of this.documents) {
      const modification = stats[document.path];
      if (modification === null || modification === undefined) continue;
      if (!(modification > (document.lastKnownModification ?? -Infinity))) continue;

      if (document.isDirty) {
        if (!document.externalConflict) {
          document.externalConflict = true;
          changed = true;
        }
      } else {
        const reloaded = await this.reloadFromDisk(document);
        changed = changed || reloaded;
      }
    }
    if (changed) {
      this.emit("tabs", "document", "toc", "graph", "attention", "status", "banner", "gutters");
    }
  }

  async reloadFromDisk(document) {
    const result = await window.marc.readFile(document.path);
    if (!result.ok) {
      document.externalConflict = true;
      return true;
    }
    document.content = result.content;
    document.savedContent = result.content;
    document.lastKnownModification = result.modified;
    document.externalConflict = false;
    document.reconcileReadingState(document.parsed);
    this.savePreferences(document);
    this.refreshReferenceExistence(document);
    return true;
  }

  /* ---------------------------------------------------------- preferences */

  savePreferences(document) {
    this.preferencesByPath[document.key] = MarcModels.serializePreferences(document.preferences);
    if (this.preferenceTimer !== null) clearTimeout(this.preferenceTimer);
    this.preferenceTimer = setTimeout(() => {
      this.preferenceTimer = null;
      this.flushPreferences();
    }, PREFERENCES_DELAY);
  }

  flushPreferences() {
    if (this.suspendPersistence) return;
    window.marc.writeStore(PREFERENCES_FILE, this.preferencesByPath);
  }

  adjustSelectedFontSize(amount) {
    const document = this.selectedDocument;
    if (document === null) return;
    const theme = document.preferences.theme;
    theme.bodySize = Math.min(72, Math.max(8, theme.bodySize + amount));
    theme.id = "custom";
    theme.name = "Custom";
    this.savePreferences(document);
    this.emit("document", "toolbar");
  }

  resetSelectedFontSize() {
    const document = this.selectedDocument;
    if (document === null) return;
    const theme = document.preferences.theme;
    theme.bodySize = 16;
    theme.id = "custom";
    theme.name = "Custom";
    this.savePreferences(document);
    this.emit("document", "toolbar");
  }

  /* --------------------------------------------------------------- groups */

  groupFor(document) {
    const groupID = this.groupAssignments[document.key];
    if (groupID === undefined) return null;
    return this.groups.find((group) => group.id === groupID) ?? null;
  }

  groupDocuments(groupID) {
    const matching = this.documents.filter(
      (document) => (this.groupAssignments[document.key] ?? null) === groupID
    );
    const compare = (left, right) => left.localeCompare(right, undefined, { sensitivity: "base" });

    switch (this.settings.tabSortOrder) {
      case "name":
        return matching.slice().sort((left, right) => compare(left.fileName, right.fileName));
      case "folder":
        return matching.slice().sort((left, right) => {
          const leftFolder = window.marc.path.dirname(left.path);
          const rightFolder = window.marc.path.dirname(right.path);
          if (leftFolder === rightFolder) return compare(left.fileName, right.fileName);
          return compare(leftFolder, rightFolder);
        });
      default:
        return matching;
    }
  }

  suggestedGroupName(document) {
    if (document === null || document === undefined) return "New Project";
    return window.marc.path.basename(window.marc.path.dirname(document.path));
  }

  createGroup(name, includeFolder, document) {
    const trimmed = name.trim();
    if (trimmed.length === 0) {
      this.setError("A project group needs a name.");
      return null;
    }
    const folderPath =
      includeFolder && document !== null && document !== undefined
        ? window.marc.path.dirname(document.path)
        : null;
    const group = {
      id: uuid(),
      name: trimmed,
      folderPath,
      colorHex: MarcModels.GROUP_PALETTE[this.groups.length % MarcModels.GROUP_PALETTE.length],
      isCollapsed: false
    };
    this.groups.push(group);
    if (document !== null && document !== undefined) {
      this.groupAssignments[document.key] = group.id;
    }
    this.persistGrouping();
    this.emit("tabs");
    return group;
  }

  renameGroup(groupID, name) {
    const group = this.groups.find((candidate) => candidate.id === groupID);
    const trimmed = name.trim();
    if (group === undefined || trimmed.length === 0) return;
    group.name = trimmed;
    this.persistGrouping();
    this.emit("tabs");
  }

  deleteGroup(groupID) {
    this.groups = this.groups.filter((group) => group.id !== groupID);
    this.groupAssignments = Object.fromEntries(
      Object.entries(this.groupAssignments).filter(([, id]) => id !== groupID)
    );
    this.persistGrouping();
    this.emit("tabs");
  }

  assign(document, groupID) {
    if (groupID === null || groupID === undefined) {
      delete this.groupAssignments[document.key];
    } else {
      this.groupAssignments[document.key] = groupID;
      const group = this.groups.find((candidate) => candidate.id === groupID);
      if (group !== undefined) group.isCollapsed = false;
    }
    this.persistGrouping();
    this.emit("tabs");
  }

  toggleGroup(groupID) {
    const group = this.groups.find((candidate) => candidate.id === groupID);
    if (group === undefined) return;
    group.isCollapsed = !group.isCollapsed;
    this.persistGrouping();
    this.emit("tabs");
  }

  moveGroup(groupID, offset) {
    const index = this.groups.findIndex((group) => group.id === groupID);
    const destination = index + offset;
    if (index < 0 || destination < 0 || destination >= this.groups.length) return;
    const [group] = this.groups.splice(index, 1);
    this.groups.splice(destination, 0, group);
    this.persistGrouping();
    this.emit("tabs");
  }

  async moveFiles(paths, groupID) {
    let movedAny = false;
    for (const candidate of paths) {
      if (!isMarkdownPath(candidate)) continue;
      const document = await this.open(candidate);
      if (document === null) continue;
      this.assign(document, groupID);
      movedAny = true;
    }
    return movedAny;
  }

  setTabSortOrder(order) {
    this.settings.tabSortOrder = order;
    this.persistSettings();
    this.emit("tabs");
  }

  automaticallyAssignGroup(document) {
    if (this.groupAssignments[document.key] !== undefined) return;
    // The most specific matching folder rule wins, matching the macOS build.
    let best = null;
    for (const group of this.groups) {
      if (group.folderPath === null || group.folderPath === undefined) continue;
      const folder = normalizePath(group.folderPath).toLowerCase();
      const prefix = folder.endsWith(window.marc.path.sep) ? folder : `${folder}${window.marc.path.sep}`;
      if (!document.key.startsWith(prefix)) continue;
      if (best === null || folder.length > best.length) {
        best = { id: group.id, length: folder.length };
      }
    }
    if (best !== null) {
      this.groupAssignments[document.key] = best.id;
      this.persistGrouping();
    }
  }

  expandGroupContaining(document) {
    const groupID = this.groupAssignments[document.key];
    if (groupID === undefined) return;
    const group = this.groups.find((candidate) => candidate.id === groupID);
    if (group === undefined || !group.isCollapsed) return;
    group.isCollapsed = false;
    this.persistGrouping();
  }

  /* ---------------------------------------------------------- persistence */

  recordRecent(filePath) {
    const key = pathKey(filePath);
    this.recentPaths = this.recentPaths.filter((candidate) => pathKey(candidate) !== key);
    this.recentPaths.unshift(normalizePath(filePath));
    this.recentPaths = this.recentPaths.slice(0, RECENT_LIMIT);
    this.settings.recentMarkdownFiles = this.recentPaths;
    this.persistSettings();
  }

  persistSettings() {
    if (this.suspendPersistence) return;
    window.marc.writeStore(SETTINGS_FILE, this.settings);
  }

  persistGrouping() {
    if (this.suspendPersistence) return;
    window.marc
      .writeStore(GROUPS_FILE, { groups: this.groups, assignments: this.groupAssignments })
      .then((result) => {
        if (result !== undefined && result.ok === false) {
          this.setError(`Could not save project groups: ${result.error}`);
        }
      });
  }

  persistSession() {
    if (this.isRestoringSession || this.suspendPersistence) return;
    const selected = this.selectedDocument;
    window.marc
      .writeStore(SESSION_FILE, {
        openPaths: this.documents.map((document) => document.path),
        selectedPath: selected === null ? null : selected.path
      })
      .then((result) => {
        if (result !== undefined && result.ok === false) {
          this.setError(`Could not save the open-tab session: ${result.error}`);
        }
      });
  }

  async restoreSession() {
    const state = await window.marc.readStore(SESSION_FILE, null);
    if (state === null || !Array.isArray(state.openPaths)) return;

    this.isRestoringSession = true;
    const candidates = state.openPaths.slice(0, 100).map(normalizePath);
    const existence = await window.marc.exists(candidates);
    for (const candidate of candidates) {
      if (existence[candidate] !== true) continue;
      await this.open(candidate);
    }
    if (typeof state.selectedPath === "string") {
      const key = pathKey(state.selectedPath);
      const selected = this.documents.find((document) => document.key === key);
      if (selected !== undefined) this.selectedID = selected.id;
    }
    this.isRestoringSession = false;
    this.persistSession();
  }

  async flush() {
    for (const timer of this.autosaveTimers.values()) clearTimeout(timer);
    this.autosaveTimers.clear();
    if (this.preferenceTimer !== null) {
      clearTimeout(this.preferenceTimer);
      this.preferenceTimer = null;
    }
    for (const document of this.documents) {
      if (document.isDirty) await this.save(document);
      this.preferencesByPath[document.key] = MarcModels.serializePreferences(document.preferences);
    }
    await window.marc.writeStore(PREFERENCES_FILE, this.preferencesByPath);
    await window.marc.writeStore(SETTINGS_FILE, this.settings);
    const selected = this.selectedDocument;
    await window.marc.writeStore(SESSION_FILE, {
      openPaths: this.documents.map((document) => document.path),
      selectedPath: selected === null ? null : selected.path
    });
  }

  /* ----------------------------------------------------------- references */

  async refreshReferenceExistence(document) {
    const paths = document.parsed.references
      .map((reference) => reference.resolvedPath)
      .filter((candidate) => candidate !== null && candidate !== undefined);
    if (paths.length === 0) return;
    const existence = await window.marc.exists(paths);
    let changed = false;
    for (const [candidate, exists] of Object.entries(existence)) {
      if (this.referenceExistence.get(candidate) !== exists) {
        this.referenceExistence.set(candidate, exists);
        changed = true;
      }
    }
    if (changed) this.emit("graph", "document");
  }

  referenceExists(reference) {
    if (reference.resolvedPath === null || reference.resolvedPath === undefined) return false;
    return this.referenceExistence.get(reference.resolvedPath) === true;
  }
}
