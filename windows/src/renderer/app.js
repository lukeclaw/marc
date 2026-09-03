/*
 * marc — workspace shell.
 *
 * Port of Sources/Marc/WorkspaceView.swift (toolbar, tab strip with project
 * groups, welcome screen, conflict banner) and the surrounding parts of
 * DocumentWorkspaceView.swift (find bar, reading status bar, split layout).
 */
"use strict";

const App = {
  store: null,
  previewView: null,
  textarea: null,
  layoutKey: null,
  showGraph: false,
  showAttention: false,
  showFind: false,
  unreadCursorID: null,
  renderQueue: new Set(),
  renderFrame: null,
  previewTimer: null,
  splitFraction: 0.5,

  /* ------------------------------------------------------------- startup */

  async start() {
    this.store = new DocumentStore();
    this.store.onChange((regions) => this.scheduleRender(regions));
    await this.store.load();

    const startup = await window.marc.startupFiles();
    for (const file of startup.files) await this.store.open(file);

    window.marc.onOpenFiles(async (files) => {
      for (const file of files) await this.store.open(file);
    });
    window.marc.onCommand((payload) => this.handleCommand(payload.name, payload.payload));

    this.installWindowDropTarget();
    this.renderAll();

    if (startup.selfTest === true) {
      // Report rather than reject: an unhandled rejection here would leave the
      // hidden self-test window alive with no result.
      try {
        await MarcSelfTest.run(this, startup.scratchDirectory);
      } catch (error) {
        window.marc.reportSelfTest({
          text: `\nmarc self test crashed: ${error && error.stack ? error.stack : error}`,
          failures: 1
        });
      }
    }
  },

  get mode() {
    return this.store.settings.workspaceMode;
  },

  set mode(value) {
    this.store.settings.workspaceMode = value;
    this.store.persistSettings();
  },

  get tocPosition() {
    return this.store.settings.tocPosition;
  },

  get showTOC() {
    return this.store.settings.showTableOfContents === true;
  },

  /* ------------------------------------------------------------ rendering */

  scheduleRender(regions) {
    for (const region of regions) this.renderQueue.add(region);
    if (this.renderFrame !== null) return;
    this.renderFrame = requestAnimationFrame(() => this.flushRender());
  },

  /*
   * Apply every queued region now. The frame callback above and the self test,
   * which runs in a hidden window where frames are throttled, share this path.
   */
  flushRender() {
    if (this.renderFrame !== null) {
      cancelAnimationFrame(this.renderFrame);
      this.renderFrame = null;
    }
    if (this.renderQueue.size === 0) return;
    const queued = this.renderQueue;
    this.renderQueue = new Set();
    this.applyRender(queued);
  },

  applyRender(regions) {
    if (regions.has("error") && this.store.errorMessage !== null) {
      const message = this.store.errorMessage;
      this.store.errorMessage = null;
      this.showAlert(message);
    }

    const document_ = this.store.selectedDocument;
    if (document_ === null || regions.has("welcome") || regions.has("layout")) {
      this.renderAll();
      return;
    }

    if (regions.has("toolbar") || regions.has("tabs")) this.renderToolbar();
    if (regions.has("tabs")) this.renderTabStrip();
    if (regions.has("banner") || regions.has("status") || regions.has("find")) this.renderBars();

    if (regions.has("document")) this.refreshDocumentSurface();
    else if (regions.has("gutters") && this.previewView !== null) this.previewView.refreshGutters();

    if (regions.has("toc")) this.refreshPanel("toc");
    if (regions.has("graph")) this.refreshPanel("graph");
    if (regions.has("attention")) this.refreshPanel("attention");
  },

  renderAll() {
    this.renderToolbar();
    this.renderTabStrip();
    this.renderWorkspace();
  },

  /* ------------------------------------------------------------- toolbar */

  renderToolbar() {
    const host = UI.clear(document.getElementById("toolbar"));
    const document_ = this.store.selectedDocument;
    const hasDocument = document_ !== null;

    host.append(
      this.toolButton("folder", "Open", "Open Markdown (Ctrl+O)", () => this.store.showOpenPanel())
    );

    const segmented = UI.el("div.segmented");
    for (const item of MarcModels.WORKSPACE_MODES) {
      segmented.append(
        UI.el(
          "button",
          {
            class: this.mode === item.id ? "selected" : "",
            title: item.label,
            disabled: !hasDocument,
            on: { click: () => this.setMode(item.id) }
          },
          [UI.icon(item.icon), UI.el("span", { text: item.label })]
        )
      );
    }
    host.append(segmented);

    host.append(
      this.toolButton(
        "sidebar",
        "Contents",
        "Toggle table of contents (Ctrl+Shift+T)",
        () => this.toggleTOC(),
        this.showTOC
      ),
      this.toolButton(
        "graph",
        "Linked",
        "Toggle linked files (Ctrl+Shift+G)",
        () => this.toggleGraph(),
        this.showGraph
      )
    );

    const attentionButton = this.toolButton(
      "scope",
      "Attention",
      "Analyze attention locally on request (Ctrl+Shift+A)",
      (event) => this.requestAttention(event.currentTarget),
      this.showAttention,
      !hasDocument
    );
    attentionButton.classList.add("attention");
    host.append(attentionButton);

    host.append(
      this.toolButton("search", "Find", "Find in document (Ctrl+F)", () => this.toggleFind(), this.showFind, !hasDocument),
      this.toolButton(
        "palette",
        "Theme",
        "Document theme (Ctrl+Shift+,)",
        (event) => this.openThemeEditor(event.currentTarget),
        false,
        !hasDocument
      ),
      this.toolButton("groups", "Groups", "Group tabs by project (Ctrl+Shift+N)", (event) =>
        this.openGroupsMenu(event.currentTarget)
      ),
      this.toolButton("ellipsis", "", "More", (event) => this.openOverflowMenu(event.currentTarget))
    );

    host.append(UI.el("div.toolbar-spacer"));
    if (hasDocument) {
      host.append(UI.el("div.toolbar-title", { text: document_.path, title: document_.path }));
      window.marc.setTitle(`${document_.displayName}${document_.isDirty ? " •" : ""} — marc`);
    } else {
      window.marc.setTitle("marc");
    }
  },

  toolButton(iconName, label, title, action, active, disabled) {
    return UI.el(
      "button.tool-button",
      {
        title,
        class: active === true ? "active" : "",
        disabled: disabled === true,
        on: { click: action }
      },
      [UI.icon(iconName), label === "" ? null : UI.el("span", { text: label })]
    );
  },

  /* ------------------------------------------------------------ tab strip */

  renderTabStrip() {
    const host = UI.clear(document.getElementById("tabstrip"));
    if (this.store.documents.length === 0) {
      host.style.display = "none";
      return;
    }
    host.style.display = "flex";

    for (const group of this.store.groups) {
      host.append(this.renderGroupSection(group));
    }

    const ungrouped = this.store.groupDocuments(null);
    if (ungrouped.length > 0) {
      const section = UI.el("div.tab-section.ungrouped");
      section.append(UI.el("span.ungrouped-label", { text: "UNGROUPED" }));
      for (const document_ of ungrouped) section.append(this.renderTab(document_));
      this.installTabDropTarget(section, null);
      section.title = "Drag Markdown tabs here to remove their project group";
      host.append(section);
    }

    host.append(
      UI.el("button.tool-button", {
        title: "Open another file",
        on: { click: () => this.store.showOpenPanel() }
      }, [UI.icon("plus")])
    );
  },

  renderGroupSection(group) {
    const documents = this.store.groupDocuments(group.id);
    const section = UI.el("div.tab-section", {
      style: { background: `color-mix(in srgb, ${group.colorHex} 12%, transparent)` },
      title: `Drag Markdown tabs here to move them into ${group.name}`
    });

    const header = UI.el(
      "button.group-header",
      {
        title: group.isCollapsed ? `Expand ${group.name}` : `Collapse ${group.name}`,
        on: {
          click: () => this.store.toggleGroup(group.id),
          contextmenu: (event) => this.openGroupContextMenu(group, event)
        }
      },
      [
        UI.el("span.group-dot", { style: { background: group.colorHex } }),
        UI.el("span", { text: group.name }),
        UI.el("span.group-count", { text: String(documents.length) }),
        UI.icon(group.isCollapsed ? "chevronRight" : "chevronLeft")
      ]
    );
    section.append(header);

    if (!group.isCollapsed) {
      for (const document_ of documents) section.append(this.renderTab(document_));
    }
    this.installTabDropTarget(section, group.id);
    return section;
  },

  renderTab(document_) {
    const selected = this.store.selectedID === document_.id;
    const tab = UI.el(
      "div.tab",
      {
        class: selected ? "selected" : "",
        draggable: true,
        title: document_.path,
        on: {
          click: () => this.selectDocument(document_),
          contextmenu: (event) => this.openTabContextMenu(document_, event),
          dragstart: (event) => {
            event.dataTransfer.setData("application/x-marc-path", document_.path);
            event.dataTransfer.effectAllowed = "move";
            tab.classList.add("dragging");
          },
          dragend: () => tab.classList.remove("dragging")
        }
      },
      [
        UI.icon("doc"),
        UI.el("span.tab-name", { text: document_.displayName }),
        document_.isDirty ? UI.el("span.dirty-dot") : null,
        document_.attentionResults.length > 0
          ? UI.badge(
              document_.attentionSuggestionCount,
              "var(--attention)",
              document_.attentionResultsAreStale ? 0.4 : 1
            )
          : null,
        document_.changedCount > 0
          ? UI.badge(document_.changedCount, "var(--changed)")
          : document_.unreadCount > 0
            ? UI.badge(document_.unreadCount, "var(--unread)")
            : null,
        UI.el("button.tab-close", {
          title: "Close tab",
          on: {
            click: (event) => {
              event.stopPropagation();
              this.store.close(document_.id);
            }
          }
        }, [UI.icon("close")])
      ]
    );
    return tab;
  },

  installTabDropTarget(section, groupID) {
    section.addEventListener("dragover", (event) => {
      event.preventDefault();
      event.dataTransfer.dropEffect = "move";
      section.classList.add("drop-target");
    });
    section.addEventListener("dragleave", () => section.classList.remove("drop-target"));
    section.addEventListener("drop", async (event) => {
      event.preventDefault();
      event.stopPropagation();
      section.classList.remove("drop-target");

      const tabPath = event.dataTransfer.getData("application/x-marc-path");
      if (tabPath !== "") {
        await this.store.moveFiles([tabPath], groupID);
        return;
      }
      const paths = this.filePathsFrom(event.dataTransfer);
      if (paths.length > 0) await this.store.moveFiles(paths, groupID);
    });
  },

  filePathsFrom(dataTransfer) {
    const paths = [];
    for (const file of dataTransfer.files) {
      const filePath = window.marc.pathForFile(file);
      if (typeof filePath === "string" && filePath.length > 0) paths.push(filePath);
    }
    return paths;
  },

  /* ------------------------------------------------------------ workspace */

  renderWorkspace() {
    const host = UI.clear(document.getElementById("workspace"));
    UI.clear(document.getElementById("banner-host"));
    this.previewView?.destroy();
    this.previewView = null;
    this.textarea = null;

    const document_ = this.store.selectedDocument;
    if (document_ === null) {
      this.layoutKey = null;
      host.append(this.renderWelcome());
      return;
    }

    this.layoutKey = this.currentLayoutKey();

    if (this.showTOC && this.tocPosition === "left") {
      host.append(this.panelWrapper("toc"), UI.el("div.pane-divider"));
    }

    const column = UI.el("div.document-column", { dataset: { role: "document-column" } });
    column.append(UI.el("div", { dataset: { role: "bars" } }));
    column.append(this.renderContentSurface(document_));
    host.append(column);

    if (this.showTOC && this.tocPosition === "right") {
      host.append(UI.el("div.pane-divider"), this.panelWrapper("toc"));
    }
    if (this.showGraph) {
      host.append(UI.el("div.pane-divider"), this.panelWrapper("graph"));
    }
    if (this.showAttention) {
      host.append(UI.el("div.pane-divider"), this.panelWrapper("attention"));
    }

    this.renderBars();
  },

  currentLayoutKey() {
    const document_ = this.store.selectedDocument;
    return [
      document_ === null ? "none" : document_.id,
      this.mode,
      this.showTOC ? this.tocPosition : "no-toc",
      this.showGraph ? "graph" : "",
      this.showAttention ? "attention" : ""
    ].join("|");
  },

  ensureLayout() {
    if (this.currentLayoutKey() !== this.layoutKey) this.renderWorkspace();
  },

  panelWrapper(kind) {
    const wrapper = UI.el("div", {
      dataset: { panel: kind },
      style: { display: "flex", minHeight: "0" }
    });
    wrapper.append(this.buildPanel(kind));
    return wrapper;
  },

  buildPanel(kind) {
    const document_ = this.store.selectedDocument;
    if (kind === "toc") {
      return MarcSidebars.tableOfContents(this.store, document_, {
        navigate: (headingID) => this.navigateToHeading(headingID),
        markSection: (headingID, read) => {
          if (read) document_.markSectionRead(headingID);
          else document_.markSectionUnread(headingID);
          this.store.savePreferences(document_);
          this.store.emit("tabs", "toc", "status", "gutters");
        }
      });
    }
    if (kind === "graph") {
      return MarcSidebars.referenceGraph(this.store, document_);
    }
    return MarcAttentionUI.panel(this.store, document_, {
      close: () => this.toggleAttention(false),
      jump: (result) => this.jumpToAttentionResult(result)
    });
  },

  refreshPanel(kind) {
    const wrapper = document.querySelector(`[data-panel="${kind}"]`);
    if (wrapper === null) return;
    UI.clear(wrapper).append(this.buildPanel(kind));
  },

  renderContentSurface(document_) {
    if (this.mode === "source") {
      return this.buildSourceEditor(document_);
    }

    const preview = new PreviewView(this.store, document_, {});
    this.previewView = preview;

    if (this.mode === "rendered") return preview.element;

    const split = UI.el("div.split");
    const editor = this.buildSourceEditor(document_);
    editor.style.flex = `0 0 ${this.splitFraction * 100}%`;
    editor.style.minWidth = "320px";
    preview.element.style.minWidth = "360px";

    const handle = UI.el("div.split-handle");
    handle.addEventListener("mousedown", (event) => {
      event.preventDefault();
      const onMove = (moveEvent) => {
        const rect = split.getBoundingClientRect();
        const fraction = Math.min(0.8, Math.max(0.2, (moveEvent.clientX - rect.left) / rect.width));
        this.splitFraction = fraction;
        editor.style.flex = `0 0 ${fraction * 100}%`;
      };
      const onUp = () => {
        window.removeEventListener("mousemove", onMove);
        window.removeEventListener("mouseup", onUp);
      };
      window.addEventListener("mousemove", onMove);
      window.addEventListener("mouseup", onUp);
    });

    split.append(editor, handle, preview.element);
    return split;
  },

  buildSourceEditor(document_) {
    const textarea = UI.el("textarea", {
      spellcheck: false,
      value: document_.content,
      style: { fontSize: `${document_.preferences.theme.bodySize}px` }
    });
    textarea.addEventListener("input", () => {
      this.store.updateContent(document_, textarea.value);
    });
    textarea.addEventListener("focus", () => {
      this.sourceFocused = true;
    });
    textarea.addEventListener("blur", () => {
      this.sourceFocused = false;
    });
    this.textarea = textarea;
    return UI.el("div.source-editor", null, [textarea]);
  },

  refreshDocumentSurface() {
    this.ensureLayout();
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;

    if (this.textarea !== null && this.textarea.value !== document_.content) {
      // Only replace the buffer for changes that did not come from typing here.
      const selectionStart = this.textarea.selectionStart;
      const selectionEnd = this.textarea.selectionEnd;
      this.textarea.value = document_.content;
      this.textarea.setSelectionRange(
        Math.min(selectionStart, document_.content.length),
        Math.min(selectionEnd, document_.content.length)
      );
    }
    if (this.textarea !== null) {
      this.textarea.style.fontSize = `${document_.preferences.theme.bodySize}px`;
    }

    if (this.previewView === null) return;
    if (this.sourceFocused === true) {
      // Coalesce preview rebuilds while typing in the split editor.
      if (this.previewTimer !== null) clearTimeout(this.previewTimer);
      this.previewTimer = setTimeout(() => {
        this.previewTimer = null;
        this.previewView?.render();
      }, 150);
      return;
    }
    this.previewView.render();
  },

  /* ----------------------------------------------------------------- bars */

  renderBars() {
    const column = document.querySelector('[data-role="document-column"]');
    if (column === null) return;
    const host = UI.clear(column.querySelector('[data-role="bars"]'));
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;

    if (document_.externalConflict) {
      host.append(
        UI.el("div.banner.conflict", null, [
          UI.icon("warning"),
          UI.el("span", { text: "This file changed on disk while you had unsaved edits." }),
          UI.el("span.spacer"),
          UI.el("button", {
            text: "Reload from Disk",
            on: {
              click: async () => {
                await this.store.reloadFromDisk(document_);
                this.store.emit("document", "toc", "graph", "status", "banner", "tabs");
              }
            }
          }),
          UI.el("button", {
            text: "Keep Mine",
            on: { click: () => this.store.overwriteWithLocalVersion(document_) }
          })
        ])
      );
    }

    if (this.showFind) host.append(this.renderFindBar(document_));

    const pending = document_.pendingReadingBlocks;
    if (pending.length > 0) host.append(this.renderReadingStatus(document_));
  },

  renderFindBar(document_) {
    const matches = this.findMatches(document_);
    const input = UI.el("input", {
      type: "text",
      placeholder: "Find in current document",
      value: document_.findText
    });
    const count = UI.el("span.find-count", {
      text: matches.length === 0
        ? "No matches"
        : `${Math.min(document_.currentMatch + 1, matches.length)} of ${matches.length}`
    });

    const step = (direction) => {
      const current = this.findMatches(document_);
      if (current.length === 0) return;
      document_.currentMatch = (document_.currentMatch + direction + current.length) % current.length;
      count.textContent = `${document_.currentMatch + 1} of ${current.length}`;
      this.revealMatch(document_, current[document_.currentMatch]);
    };

    input.addEventListener("input", () => {
      document_.findText = input.value;
      document_.currentMatch = 0;
      const current = this.findMatches(document_);
      count.textContent = current.length === 0 ? "No matches" : `1 of ${current.length}`;
      if (current.length > 0) this.revealMatch(document_, current[0]);
    });
    input.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        step(event.shiftKey ? -1 : 1);
      } else if (event.key === "Escape") {
        event.preventDefault();
        this.toggleFind(false);
      }
    });

    const bar = UI.el("div.find-bar", null, [
      UI.icon("search"),
      input,
      count,
      UI.el("button", {
        title: "Previous match",
        disabled: matches.length === 0,
        on: { click: () => step(-1) }
      }, [UI.icon("chevronUp")]),
      UI.el("button", {
        title: "Next match",
        disabled: matches.length === 0,
        on: { click: () => step(1) }
      }, [UI.icon("chevronDown")]),
      UI.el("button", { title: "Close find", on: { click: () => this.toggleFind(false) } }, [
        UI.icon("close")
      ])
    ]);
    requestAnimationFrame(() => input.focus());
    return bar;
  },

  findMatches(document_) {
    if (document_.findText.length === 0) return [];
    const haystack = document_.content.toLowerCase();
    const needle = document_.findText.toLowerCase();
    const matches = [];
    let position = haystack.indexOf(needle);
    while (position >= 0) {
      matches.push(position);
      position = haystack.indexOf(needle, position + needle.length);
    }
    return matches;
  },

  revealMatch(document_, offset) {
    if (this.textarea !== null) {
      this.textarea.focus();
      this.textarea.setSelectionRange(offset, offset + document_.findText.length);
      // Scroll the caret into view by nudging the selection.
      const before = this.textarea.value.slice(0, offset).split("\n").length;
      const lineHeight = document_.preferences.theme.bodySize * 1.55;
      this.textarea.scrollTop = Math.max(0, (before - 4) * lineHeight);
      return;
    }
    if (this.previewView === null) return;
    const block = this.blockContainingOffset(document_, offset);
    if (block !== null) this.previewView.scrollTo(block.id);
  },

  blockContainingOffset(document_, offset) {
    const needle = document_.content.slice(offset, offset + document_.findText.length).toLowerCase();
    for (const block of document_.parsed.blocks) {
      const text = MarcParser.canonicalBlockContent(block.kind).toLowerCase();
      if (text.includes(needle)) return block;
    }
    return null;
  },

  renderReadingStatus(document_) {
    const changed = document_.changedCount;
    const unread = document_.unreadCount;
    const color = changed > 0 ? "var(--changed)" : "var(--unread)";
    const text =
      changed > 0
        ? `${changed} updated passage${changed === 1 ? "" : "s"}${unread > 0 ? ` · ${unread} unread` : ""}`
        : `${unread} unread passage${unread === 1 ? "" : "s"}`;

    return UI.el(
      "div.reading-status",
      { style: { background: `color-mix(in srgb, ${color} 10%, transparent)` } },
      [
        UI.el("span.dot", { style: { background: color } }),
        UI.el("span", { text }),
        UI.el("span.spacer"),
        UI.el("button", {
          title: "Previous unread passage (Ctrl+Alt+Up)",
          on: { click: () => this.jumpToPending(-1) }
        }, [UI.icon("chevronUp")]),
        UI.el("button", {
          title: "Next unread passage (Ctrl+Alt+Down)",
          on: { click: () => this.jumpToPending(1) }
        }, [UI.icon("chevronDown")]),
        UI.el("button", {
          text: "Mark All Read",
          on: {
            click: () => {
              document_.markAllRead();
              this.store.savePreferences(document_);
              this.store.emit("tabs", "toc", "status", "gutters");
            }
          }
        })
      ]
    );
  },

  /* -------------------------------------------------------------- welcome */

  renderWelcome() {
    const welcome = UI.el("div.welcome");
    welcome.append(
      UI.icon("doc", "welcome-glyph"),
      UI.el("div", { style: { textAlign: "center" } }, [
        UI.el("div.wordmark", { text: "marc" }),
        UI.el("div.tagline", { text: "A calmer way to read what agents write." })
      ]),
      UI.el("button.primary-button", {
        text: "Open Markdown…",
        on: { click: () => this.store.showOpenPanel() }
      })
    );
    welcome.querySelector(".welcome-glyph").style.cssText =
      "width:64px;height:64px;stroke:var(--accent);stroke-width:1.1";

    if (this.store.recentPaths.length > 0) {
      const panel = UI.el("div.recent-panel");
      panel.append(UI.el("div.heading", { text: "Recent" }));
      for (const recent of this.store.recentPaths.slice(0, 6)) {
        panel.append(
          UI.el("button.recent-row", {
            title: recent,
            on: { click: () => this.store.open(recent) }
          }, [
            UI.icon("doc"),
            UI.el("span", { style: { minWidth: "0", flex: "1" } }, [
              UI.el("div", { text: window.marc.path.basename(recent) }),
              UI.el("div.path", { text: window.marc.path.dirname(recent) })
            ])
          ])
        );
      }
      welcome.append(panel);
    }

    welcome.append(UI.el("div.hint", { text: "You can also drop .md files anywhere in this window." }));
    return welcome;
  },

  /* ------------------------------------------------------------- actions */

  selectDocument(document_) {
    this.store.selectedID = document_.id;
    this.unreadCursorID = null;
    this.store.persistSession();
    this.renderAll();
  },

  setMode(mode) {
    if (this.mode === mode) return;
    this.mode = mode;
    this.renderAll();
  },

  toggleTOC() {
    this.store.settings.showTableOfContents = !this.showTOC;
    this.store.persistSettings();
    this.renderAll();
  },

  setTOCPosition(position) {
    this.store.settings.tocPosition = position;
    this.store.persistSettings();
    this.renderAll();
  },

  toggleGraph(value) {
    this.showGraph = value === undefined ? !this.showGraph : value;
    this.renderAll();
  },

  toggleAttention(value) {
    this.showAttention = value === undefined ? !this.showAttention : value;
    this.renderAll();
  },

  toggleFind(value) {
    const next = value === undefined ? !this.showFind : value;
    if (next === this.showFind) return;
    this.showFind = next;
    this.renderToolbar();
    this.renderBars();
  },

  /*
   * Analysis never starts implicitly: the first request shows the disclosure
   * popover, and only an explicit click begins a run.
   */
  requestAttention(anchor) {
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;

    if (this.store.settings.attentionAnalysisAcknowledged !== true) {
      UI.popover(
        MarcAttentionUI.disclosure({
          analyze: () => {
            this.store.settings.attentionAnalysisAcknowledged = true;
            this.store.persistSettings();
            UI.dismissAll();
            this.toggleAttention(true);
            MarcAttentionUI.start(this.store, document_, true);
          },
          cancel: () => UI.dismissAll()
        }),
        anchor,
        { width: 340 }
      );
      return;
    }

    this.toggleAttention(true);
    if (!document_.hasCurrentAttentionResults && document_.attentionState !== "running") {
      MarcAttentionUI.start(this.store, document_, true);
    }
  },

  openThemeEditor(anchor) {
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;
    UI.popover(
      MarcSidebars.themeEditor(this.store, document_, () => {
        this.previewView?.render();
        if (this.textarea !== null) {
          this.textarea.style.fontSize = `${document_.preferences.theme.bodySize}px`;
        }
        this.refreshPanel("toc");
      }),
      anchor,
      { width: 340 }
    );
  },

  openGroupsMenu(anchor) {
    const document_ = this.store.selectedDocument;
    const items = [
      { label: "New Project Group…", action: () => this.promptNewGroup(document_) }
    ];

    if (document_ !== null) {
      items.push({
        label: "Move Current File",
        submenu: [
          { label: "Ungrouped", action: () => this.store.assign(document_, null) },
          { separator: true },
          ...this.store.groups.map((group) => ({
            label: group.name,
            checked: this.store.groupFor(document_)?.id === group.id,
            action: () => this.store.assign(document_, group.id)
          }))
        ]
      });
    }

    items.push(
      { separator: true },
      {
        label: "Sort Tabs",
        submenu: MarcModels.TAB_SORT_ORDERS.map((order) => ({
          label: order.label,
          checked: this.store.settings.tabSortOrder === order.id,
          action: () => this.store.setTabSortOrder(order.id)
        }))
      }
    );
    UI.menu(items, anchor);
  },

  openOverflowMenu(anchor) {
    const document_ = this.store.selectedDocument;
    UI.menu(
      [
        { label: "Move Contents to Left", action: () => this.setTOCPosition("left") },
        { label: "Move Contents to Right", action: () => this.setTOCPosition("right") },
        { separator: true },
        {
          label: "Copy File Path",
          disabled: document_ === null,
          action: () => {
            window.marc.copy(document_.path);
            UI.toast("File path copied.");
          }
        },
        {
          label: "Show in File Explorer",
          disabled: document_ === null,
          action: () => window.marc.reveal(document_.path)
        },
        { separator: true },
        { label: "Set marc as the Default Markdown App…", action: () => this.registerDefaultApp() }
      ],
      anchor
    );
  },

  openGroupContextMenu(group, event) {
    UI.contextMenuAt(
      [
        { label: "Rename Group…", action: () => this.promptRenameGroup(group) },
        group.folderPath === null || group.folderPath === undefined
          ? null
          : { note: `Auto-groups ${group.folderPath}` },
        { separator: true },
        {
          label: "Move Group Left",
          disabled: this.store.groups[0]?.id === group.id,
          action: () => this.store.moveGroup(group.id, -1)
        },
        {
          label: "Move Group Right",
          disabled: this.store.groups[this.store.groups.length - 1]?.id === group.id,
          action: () => this.store.moveGroup(group.id, 1)
        },
        { separator: true },
        {
          label: "Delete Group…",
          destructive: true,
          action: () => this.confirmDeleteGroup(group)
        }
      ].filter((item) => item !== null),
      event
    );
  },

  openTabContextMenu(document_, event) {
    UI.contextMenuAt(
      [
        {
          label: "Move to Project Group",
          submenu: [
            { label: "Ungrouped", action: () => this.store.assign(document_, null) },
            { separator: true },
            ...this.store.groups.map((group) => ({
              label: group.name,
              checked: this.store.groupFor(document_)?.id === group.id,
              action: () => this.store.assign(document_, group.id)
            }))
          ]
        },
        { label: "New Group from This Folder…", action: () => this.promptNewGroup(document_) },
        { separator: true },
        { label: "Show in File Explorer", action: () => window.marc.reveal(document_.path) },
        { label: "Close Tab", action: () => this.store.close(document_.id) }
      ],
      event
    );
  },

  /* --------------------------------------------------------------- modals */

  async promptNewGroup(document_) {
    const result = await UI.modal((close) => {
      const nameInput = UI.el("input", {
        type: "text",
        value: this.store.suggestedGroupName(document_),
        placeholder: "Group name"
      });
      const folderCheckbox = UI.el("input", {
        type: "checkbox",
        checked: document_ !== null && document_ !== undefined,
        disabled: document_ === null || document_ === undefined
      });
      const submit = () => close({ name: nameInput.value, includeFolder: folderCheckbox.checked });
      nameInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") submit();
      });

      return UI.el("div.modal", null, [
        UI.el("h2", { text: "New Project Group" }),
        UI.el("p", {
          text:
            "Group related Markdown tabs and optionally auto-assign files from the same folder."
        }),
        nameInput,
        UI.el("label.checkbox-row", null, [
          folderCheckbox,
          UI.el("span", { text: "Automatically include files from this folder" })
        ]),
        UI.el("div.actions", null, [
          UI.el("button.secondary-button", { text: "Cancel", on: { click: () => close(null) } }),
          UI.el("button.primary-button", { text: "Create", on: { click: submit } })
        ])
      ]);
    });

    if (result === null) return;
    this.store.createGroup(result.name, result.includeFolder, document_);
  },

  async promptRenameGroup(group) {
    const name = await UI.modal((close) => {
      const nameInput = UI.el("input", { type: "text", value: group.name });
      const submit = () => close(nameInput.value);
      nameInput.addEventListener("keydown", (event) => {
        if (event.key === "Enter") submit();
      });
      return UI.el("div.modal", null, [
        UI.el("h2", { text: "Rename Project Group" }),
        nameInput,
        UI.el("div.actions", null, [
          UI.el("button.secondary-button", { text: "Cancel", on: { click: () => close(null) } }),
          UI.el("button.primary-button", { text: "Rename", on: { click: submit } })
        ])
      ]);
    });
    if (name === null) return;
    this.store.renameGroup(group.id, name);
  },

  async confirmDeleteGroup(group) {
    const response = await window.marc.confirm({
      type: "warning",
      message: `Delete “${group.name}”?`,
      detail: "Its files will become ungrouped. No files will be deleted.",
      buttons: ["Delete Group", "Cancel"]
    });
    if (response !== 0) return;
    this.store.deleteGroup(group.id);
  },

  async registerDefaultApp() {
    const response = await window.marc.confirm({
      type: "question",
      message: "Set marc as the default app for Markdown files?",
      detail:
        "This registers .md, .markdown, .mdown, and .mkd for the current user only. " +
        "You can change it back at any time in Windows Settings > Apps > Default apps.",
      buttons: ["Register marc", "Cancel"]
    });
    if (response !== 0) return;

    const result = await window.marc.registerDefault();
    if (result.ok) {
      UI.toast("marc is registered for Markdown files. Windows may still ask you to confirm once.");
    } else {
      this.showAlert(`Could not register marc: ${result.error}`);
    }
  },

  showAlert(message) {
    UI.modal((close) =>
      UI.el("div.modal", null, [
        UI.el("h2", { text: "marc" }),
        UI.el("p", { text: message }),
        UI.el("div.actions", null, [
          UI.el("button.primary-button", { text: "OK", on: { click: () => close(null) } })
        ])
      ])
    );
  },

  /* ---------------------------------------------------------- navigation */

  navigateToHeading(headingID) {
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;

    const block = document_.parsed.blocks.find((candidate) => candidate.id === headingID);
    if (block !== undefined) {
      const collapsed = document_.preferences.collapsedHeadingIDs;
      document_.preferences.collapsedHeadingIDs = collapsed.filter(
        (id) => !block.ancestorHeadingIDs.includes(id)
      );
    }
    document_.preferences.lastScrollHeadingID = headingID;
    this.store.savePreferences(document_);

    if (this.mode === "source") this.setMode("rendered");
    else this.previewView?.render();

    requestAnimationFrame(() => this.previewView?.scrollTo(headingID));
    this.refreshPanel("toc");
  },

  jumpToPending(direction) {
    const document_ = this.store.selectedDocument;
    if (document_ === null) return;
    const blocks = document_.pendingReadingBlocks;
    if (blocks.length === 0) return;

    const currentIndex = blocks.findIndex((block) => block.id === this.unreadCursorID);
    const nextIndex =
      currentIndex >= 0
        ? (currentIndex + direction + blocks.length) % blocks.length
        : direction > 0
          ? 0
          : blocks.length - 1;

    const block = blocks[nextIndex];
    this.unreadCursorID = block.id;
    if (this.mode === "source") this.setMode("rendered");
    requestAnimationFrame(() => this.previewView?.scrollTo(block.id));
  },

  jumpToAttentionResult(result) {
    const blockID = result.blockIDs[0];
    if (blockID === undefined) return;
    if (this.mode !== "rendered") this.setMode("rendered");
    requestAnimationFrame(() => {
      this.previewView?.scrollTo(blockID);
      this.previewView?.setHighlight(blockID);
    });
  },

  /* ------------------------------------------------------------ commands */

  async handleCommand(name, payload) {
    const document_ = this.store.selectedDocument;
    switch (name) {
      case "open":
        await this.store.showOpenPanel();
        break;
      case "save":
        await this.store.saveSelected();
        break;
      case "close-tab":
        await this.store.closeSelected();
        break;
      case "find":
        if (document_ !== null) this.toggleFind(true);
        break;
      case "mode":
        if (document_ !== null) this.setMode(payload);
        break;
      case "toggle-toc":
        this.toggleTOC();
        break;
      case "toc-position":
        this.setTOCPosition(payload);
        break;
      case "toggle-graph":
        this.toggleGraph();
        break;
      case "attention":
        if (document_ !== null) {
          const anchor = document.querySelector(".tool-button.attention");
          this.requestAttention(anchor ?? document.getElementById("toolbar"));
        }
        break;
      case "theme":
        this.openThemeEditor(
          document.querySelector('.tool-button[title^="Document theme"]') ??
            document.getElementById("toolbar")
        );
        break;
      case "font-size":
        if (payload === 0) this.store.resetSelectedFontSize();
        else this.store.adjustSelectedFontSize(payload);
        break;
      case "pending":
        this.jumpToPending(payload);
        break;
      case "mark-all-read":
        if (document_ !== null) {
          document_.markAllRead();
          this.store.savePreferences(document_);
          this.store.emit("tabs", "toc", "status", "gutters");
        }
        break;
      case "new-group":
        await this.promptNewGroup(document_);
        break;
      case "sort-tabs":
        this.store.setTabSortOrder(payload);
        break;
      case "copy-path":
        if (document_ !== null) {
          window.marc.copy(document_.path);
          UI.toast("File path copied.");
        }
        break;
      case "reveal":
        if (document_ !== null) window.marc.reveal(document_.path);
        break;
      case "register-default":
        await this.registerDefaultApp();
        break;
      case "about":
        this.showAlert(
          "marc 0.1.0 — a Markdown workspace for reading long, AI-generated documents. " +
            "All processing is local."
        );
        break;
      case "flush":
        await this.store.flush();
        window.marc.flushed();
        break;
      default:
        break;
    }
  },

  /* --------------------------------------------------------- drag and drop */

  installWindowDropTarget() {
    let veil = null;
    const showVeil = () => {
      if (veil !== null) return;
      veil = UI.el("div.drop-veil", { text: "Drop Markdown files to open" });
      document.body.append(veil);
    };
    const hideVeil = () => {
      veil?.remove();
      veil = null;
    };

    window.addEventListener("dragover", (event) => {
      event.preventDefault();
      if (event.dataTransfer.types.includes("Files")) showVeil();
    });
    window.addEventListener("dragleave", (event) => {
      if (event.relatedTarget === null) hideVeil();
    });
    window.addEventListener("drop", async (event) => {
      event.preventDefault();
      hideVeil();
      const paths = this.filePathsFrom(event.dataTransfer).filter((candidate) =>
        MarcModels.MARKDOWN_EXTENSIONS.includes(
          window.marc.path.extname(candidate).replace(".", "").toLowerCase()
        )
      );
      for (const filePath of paths) await this.store.open(filePath);
    });
  }
};

window.addEventListener("DOMContentLoaded", () => {
  App.start();
});
