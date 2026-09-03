/*
 * marc — themed reading surface.
 *
 * Port of MarkdownPreview, MarkdownBlockView, MarkdownTableView, and
 * BlockGutterMarkers from Sources/Marc/DocumentWorkspaceView.swift.
 */
"use strict";

const READING_LINE_FRACTION = 0.55;
const READING_DWELL = 650;
const DEFAULT_COLUMN_WIDTH = 180;
const MINIMUM_COLUMN_WIDTH = 140;
const COPY_FEEDBACK = 1300;
const DARK_SURFACE_LUMINANCE = 0.45;

/*
 * Split the source into alternating plain and highlighted runs. Spans arrive in
 * order and never overlap, and anything the scanner skipped stays plain.
 */
function codePieces(source, spans) {
  const pieces = [];
  let cursor = 0;
  for (const span of spans) {
    if (span.location < cursor || span.length <= 0) continue;
    if (span.location + span.length > source.length) continue;
    if (span.location > cursor) {
      pieces.push({ text: source.slice(cursor, span.location), kind: null });
    }
    pieces.push({
      text: source.slice(span.location, span.location + span.length),
      kind: span.kind
    });
    cursor = span.location + span.length;
  }
  if (cursor < source.length) pieces.push({ text: source.slice(cursor), kind: null });
  return pieces;
}

/* Relative luminance, matching the macOS palette's 0.45 sRGB threshold. */
function isDarkSurface(hex) {
  const value = hex.replace("#", "");
  if (value.length !== 6) return false;
  const red = parseInt(value.slice(0, 2), 16) / 255;
  const green = parseInt(value.slice(2, 4), 16) / 255;
  const blue = parseInt(value.slice(4, 6), 16) / 255;
  return 0.2126 * red + 0.7152 * green + 0.0722 * blue < DARK_SURFACE_LUMINANCE;
}

class PreviewView {
  constructor(store, document_, options) {
    this.store = store;
    this.document = document_;
    this.options = options ?? {};
    this.blockElements = new Map();
    this.tableStates = new Map();
    this.readingCandidateID = null;
    this.readingTimer = null;
    this.highlightTarget = null;
    this.highlightTimer = null;
    this.scrollFrame = null;
    this.copyTimers = new Map();

    this.element = UI.el("div.preview.scroll");
    this.page = UI.el("div.preview-page");
    this.element.append(this.page);

    this.element.addEventListener("scroll", () => this.scheduleReadingUpdate(), { passive: true });
    this.element.addEventListener("click", (event) => this.handleClick(event));

    this.resizeObserver = new ResizeObserver(() => {
      this.refitTables();
      this.scheduleReadingUpdate();
    });
    this.resizeObserver.observe(this.element);

    this.render();
  }

  destroy() {
    this.resizeObserver.disconnect();
    if (this.readingTimer !== null) clearTimeout(this.readingTimer);
    if (this.highlightTimer !== null) clearTimeout(this.highlightTimer);
    if (this.scrollFrame !== null) cancelAnimationFrame(this.scrollFrame);
    for (const timer of this.copyTimers.values()) clearTimeout(timer);
    this.copyTimers.clear();
  }

  /* --------------------------------------------------------------- layout */

  applyTheme() {
    const theme = this.document.preferences.theme;
    const style = this.element.style;
    style.setProperty("--page-bg", theme.background.hex);
    style.setProperty("--page-text", theme.text.hex);
    style.setProperty("--page-heading", theme.heading.hex);
    style.setProperty("--page-accent", theme.accent.hex);
    style.setProperty("--page-code-bg", theme.codeBackground.hex);
    style.setProperty("--page-quote", theme.quote.hex);
    style.setProperty("--page-font", MarcModels.fontStack(theme.fontFamily));
    style.setProperty("--page-size", `${theme.bodySize}px`);

    // Port of preferredScrollerKnobStyle: a dark page gets the light knob.
    this.element.classList.toggle("dark-surface", isDarkSurface(theme.background.hex));

    if (theme.fullWidth === true) {
      this.page.style.width = "100%";
      this.page.style.maxWidth = "none";
      this.page.style.paddingLeft = "28px";
      this.page.style.paddingRight = "28px";
    } else {
      this.page.style.width = "100%";
      this.page.style.maxWidth = `${theme.pageWidth + 96}px`;
      this.page.style.paddingLeft = "48px";
      this.page.style.paddingRight = "48px";
    }
    // Bottom inset keeps the reading line usable for the final passages.
    this.page.style.paddingBottom = `${Math.max(36, this.element.clientHeight * 0.45)}px`;
  }

  isVisible(block) {
    const collapsed = this.document.preferences.collapsedHeadingIDs;
    return !block.ancestorHeadingIDs.some((id) => collapsed.includes(id));
  }

  render() {
    const scrollTop = this.element.scrollTop;
    UI.clear(this.page);
    this.blockElements.clear();
    this.applyTheme();

    for (const block of this.document.parsed.blocks) {
      if (!this.isVisible(block)) continue;
      const node = this.renderBlock(block);
      this.blockElements.set(block.id, node);
      this.page.append(node);
    }

    this.element.scrollTop = scrollTop;
    this.refitTables();
    this.scheduleReadingUpdate();
  }

  renderBlock(block) {
    const theme = this.document.preferences.theme;
    const node = UI.el("div.block", { dataset: { blockId: block.id } });

    switch (block.kind.type) {
      case "heading":
        node.classList.add(`h${block.kind.level}`);
        node.append(this.renderHeading(block, theme));
        break;
      case "paragraph":
        node.append(UI.el("div.md-paragraph", { html: MarcInline.render(block.kind.text) }));
        break;
      case "list":
        node.append(this.renderList(block.kind.items, theme));
        break;
      case "table":
        node.append(this.renderTable(block, theme));
        break;
      case "blockquote":
        node.append(
          UI.el("div.md-quote", null, [
            UI.el("div.rail"),
            UI.el("div.text", { html: MarcInline.render(block.kind.text) })
          ])
        );
        break;
      case "code":
        node.append(this.renderCode(block.kind, theme));
        break;
      default:
        node.append(UI.el("div.md-rule"));
        break;
    }

    node.append(this.renderGutter(block));
    if (this.highlightTarget === block.id) node.classList.add("attention-highlight");
    return node;
  }

  renderHeading(block, theme) {
    const { level, title } = block.kind;
    const collapsed = this.document.preferences.collapsedHeadingIDs.includes(block.id);
    const scales = { 1: 2.0, 2: 1.6, 3: 1.32, 4: 1.16 };
    const weights = { 1: 700, 2: 700, 3: 600, 4: 600 };

    const button = UI.el(
      "button.md-heading",
      {
        title: collapsed ? "Click to expand section" : "Click to collapse section",
        style: {
          fontSize: `${theme.bodySize * (scales[level] ?? 1.02)}px`,
          fontWeight: String(weights[level] ?? 600)
        },
        on: {
          click: () => this.toggleCollapsed(block.id),
          contextmenu: (event) =>
            UI.contextMenuAt(
              [
                { label: "Mark Section Read", action: () => this.markSection(block.id, true) },
                { label: "Mark Section Unread", action: () => this.markSection(block.id, false) }
              ],
              event
            )
        }
      },
      [
        UI.el("span.title", { html: MarcInline.render(title) }),
        collapsed ? UI.el("span.collapse-pill", { text: "…" }) : null
      ]
    );
    if (collapsed) button.classList.add("collapsed");
    return button;
  }

  renderList(items, theme) {
    const list = UI.el("div.md-list");
    for (const item of items) {
      let marker;
      if (item.marker.type === "bullet") {
        marker = UI.el("span.marker", { text: "•" });
      } else if (item.marker.type === "ordered") {
        marker = UI.el("span.marker", { text: `${item.marker.number}.` });
      } else {
        marker = UI.el("span.marker.task", { text: item.marker.checked ? "☑" : "☐" });
        if (!item.marker.checked) marker.classList.add("unchecked");
      }

      const text = UI.el("span.text", { html: MarcInline.render(item.text) });
      if (item.marker.type === "task" && item.marker.checked) text.classList.add("checked");

      list.append(
        UI.el(
          "div.md-list-item",
          { style: { paddingLeft: `${item.level * 24}px` } },
          [marker, text]
        )
      );
    }
    list.style.fontSize = `${theme.bodySize}px`;
    return list;
  }

  renderCode(kind, theme) {
    const size = Math.max(12, theme.bodySize - 2);
    const highlighted = MarcHighlight.highlight(kind.content, kind.language);

    const code = UI.el("code");
    for (const piece of codePieces(kind.content, highlighted.spans)) {
      if (piece.kind === null) {
        code.append(piece.text);
        continue;
      }
      code.append(UI.el(`span.tok-${piece.kind}`, { text: piece.text }));
    }

    const copy = UI.el("button.code-copy", { title: "Copy this code block" }, [
      UI.icon("doc"),
      UI.el("span", { text: "Copy" })
    ]);
    copy.addEventListener("click", () => {
      window.marc.copy(kind.content);
      UI.clear(copy).append(UI.icon("check"), UI.el("span", { text: "Copied" }));
      copy.classList.add("copied");
      if (this.copyTimers.has(copy)) clearTimeout(this.copyTimers.get(copy));
      this.copyTimers.set(
        copy,
        setTimeout(() => {
          this.copyTimers.delete(copy);
          if (!copy.isConnected) return;
          UI.clear(copy).append(UI.icon("doc"), UI.el("span", { text: "Copy" }));
          copy.classList.remove("copied");
        }, COPY_FEEDBACK)
      );
    });

    // The palette follows the page theme's code background, so a dark theme
    // gets the bright token colours and a light one the muted set.
    const node = UI.el("div.md-code", {
      class: isDarkSurface(theme.codeBackground.hex) ? "dark-surface" : ""
    });
    node.append(
      UI.el("div.code-header", null, [
        UI.el("span.language", { text: highlighted.languageName ?? "" }),
        UI.el("span.spacer"),
        copy
      ]),
      UI.el("pre.scroll", { style: { fontSize: `${size}px` } }, [code])
    );
    return node;
  }

  /* --------------------------------------------------------------- tables */

  tableState(block) {
    let state = this.tableStates.get(block.id);
    if (state !== undefined) return state;

    const columnCount = block.kind.table.headers.length;
    const saved = this.document.preferences.tableColumnWidths?.[block.id] ?? null;
    const widths = (saved ?? []).slice(0, columnCount);
    while (widths.length < columnCount) widths.push(DEFAULT_COLUMN_WIDTH);
    state = { widths, hasCustomWidths: saved !== null };
    this.tableStates.set(block.id, state);
    return state;
  }

  renderTable(block, theme) {
    const { headers, alignments, rows } = block.kind.table;
    const state = this.tableState(block);
    const alignmentFor = (index) => {
      const alignment = alignments[index];
      if (alignment === "center") return "center";
      if (alignment === "trailing") return "right";
      return "left";
    };

    const table = UI.el("table.md-table", {
      style: { fontSize: `${Math.max(13, theme.bodySize - 1)}px` }
    });
    const colgroup = UI.el("colgroup");
    for (const width of state.widths) {
      colgroup.append(UI.el("col", { style: { width: `${width}px` } }));
    }
    table.append(colgroup);

    const headerRow = UI.el("tr");
    headers.forEach((header, index) => {
      const cell = UI.el("th", {
        html: MarcInline.render(header),
        title: MarcInline.plain(header),
        style: { textAlign: alignmentFor(index) }
      });
      if (index < headers.length - 1) {
        cell.append(this.columnHandle(block, index, table, colgroup));
      }
      headerRow.append(cell);
    });
    table.append(UI.el("thead", null, [headerRow]));

    const body = UI.el("tbody");
    rows.forEach((row, rowIndex) => {
      const tableRow = UI.el("tr", { class: rowIndex % 2 === 0 ? "" : "odd" });
      row.forEach((cellText, index) => {
        tableRow.append(
          UI.el("td", {
            html: MarcInline.render(cellText),
            title: MarcInline.plain(cellText),
            style: { textAlign: alignmentFor(index) }
          })
        );
      });
      body.append(tableRow);
    });
    table.append(body);

    const scroller = UI.el("div.md-table-scroll.scroll", {
      dataset: { tableId: block.id },
      on: {
        contextmenu: (event) =>
          UI.contextMenuAt(
            [
              {
                label: "Fit Columns to Table Width",
                action: () => {
                  this.fitColumns(block, scroller.clientWidth);
                  state.hasCustomWidths = true;
                  this.persistColumnWidths(block, state.widths);
                  this.applyColumnWidths(block);
                }
              }
            ],
            event
          )
      }
    }, [table]);
    return scroller;
  }

  columnHandle(block, index, table, colgroup) {
    const state = this.tableState(block);
    return UI.el("div.column-handle", {
      title: "Drag to resize column; double-click to reset",
      on: {
        mousedown: (event) => {
          event.preventDefault();
          event.stopPropagation();
          const startX = event.clientX;
          const startWidth = state.widths[index];
          state.hasCustomWidths = true;

          const onMove = (moveEvent) => {
            const width = Math.min(900, Math.max(100, startWidth + (moveEvent.clientX - startX)));
            state.widths[index] = width;
            colgroup.children[index].style.width = `${width}px`;
          };
          const onUp = () => {
            window.removeEventListener("mousemove", onMove);
            window.removeEventListener("mouseup", onUp);
            this.persistColumnWidths(block, state.widths);
          };
          window.addEventListener("mousemove", onMove);
          window.addEventListener("mouseup", onUp);
        },
        dblclick: (event) => {
          event.preventDefault();
          event.stopPropagation();
          state.widths[index] = this.defaultColumnWidth(block);
          state.hasCustomWidths = true;
          colgroup.children[index].style.width = `${state.widths[index]}px`;
          this.persistColumnWidths(block, state.widths);
        }
      }
    });
  }

  defaultColumnWidth(block) {
    const columns = block.kind.table.headers.length;
    const viewport = this.viewportWidthFor(block.id);
    if (columns === 0 || viewport <= 0) return DEFAULT_COLUMN_WIDTH;
    return Math.max(MINIMUM_COLUMN_WIDTH, viewport / columns);
  }

  viewportWidthFor(blockID) {
    const node = this.blockElements.get(blockID);
    if (node === undefined) return 0;
    const scroller = node.querySelector(".md-table-scroll");
    return scroller === null ? 0 : scroller.clientWidth;
  }

  fitColumns(block, width) {
    const state = this.tableState(block);
    const columns = block.kind.table.headers.length;
    if (columns === 0 || width <= 0) return;
    const each = Math.max(MINIMUM_COLUMN_WIDTH, width / columns);
    state.widths = new Array(columns).fill(each);
  }

  applyColumnWidths(blockID) {
    const id = typeof blockID === "string" ? blockID : blockID.id;
    const node = this.blockElements.get(id);
    if (node === undefined) return;
    const colgroup = node.querySelector("colgroup");
    const state = this.tableStates.get(id);
    if (colgroup === null || state === undefined) return;
    state.widths.forEach((width, index) => {
      if (colgroup.children[index] !== undefined) {
        colgroup.children[index].style.width = `${width}px`;
      }
    });
  }

  /* Unmodified tables spread across the available width. */
  refitTables() {
    for (const block of this.document.parsed.blocks) {
      if (block.kind.type !== "table") continue;
      const state = this.tableStates.get(block.id);
      if (state === undefined || state.hasCustomWidths) continue;
      const width = this.viewportWidthFor(block.id);
      if (width <= 0) continue;
      this.fitColumns(block, width);
      this.applyColumnWidths(block.id);
    }
  }

  persistColumnWidths(block, widths) {
    const widthMap = this.document.preferences.tableColumnWidths ?? {};
    widthMap[block.id] = [...widths];
    this.document.preferences.tableColumnWidths = widthMap;
    this.document.preferences.tableWidthLayoutVersion = 2;
    this.store.savePreferences(this.document);
  }

  /* -------------------------------------------------------------- gutters */

  renderGutter(block) {
    const status = this.document.readingStatus(block);
    const hasAttention = this.document.attentionResultFor(block.id) !== null;
    const gutter = UI.el("div.gutter");
    if (this.document.attentionResultsAreStale) gutter.classList.add("stale");
    if (hasAttention) gutter.append(UI.el("div.diamond"));
    if (status === "unread") gutter.append(UI.el("div.unread"));
    else if (status === "changed") gutter.append(UI.el("div.changed"));
    return gutter;
  }

  refreshGutter(blockID) {
    const node = this.blockElements.get(blockID);
    if (node === undefined) return;
    const block = this.document.parsed.blocks.find((candidate) => candidate.id === blockID);
    if (block === undefined) return;
    const existing = node.querySelector(":scope > .gutter");
    if (existing !== null) existing.remove();
    node.append(this.renderGutter(block));
  }

  refreshGutters() {
    for (const blockID of this.blockElements.keys()) this.refreshGutter(blockID);
  }

  /* ------------------------------------------------------------ behaviour */

  toggleCollapsed(id) {
    const collapsed = this.document.preferences.collapsedHeadingIDs;
    const index = collapsed.indexOf(id);
    if (index >= 0) collapsed.splice(index, 1);
    else collapsed.push(id);
    this.store.savePreferences(this.document);
    this.render();
  }

  markSection(headingID, read) {
    if (read) this.document.markSectionRead(headingID);
    else this.document.markSectionUnread(headingID);
    this.store.savePreferences(this.document);
    this.refreshGutters();
    this.store.emit("tabs", "toc", "status");
  }

  handleClick(event) {
    const link = event.target.closest("a.md-link");
    if (link === null) return;
    event.preventDefault();

    const external = link.dataset.external;
    if (external !== undefined) {
      window.marc.openExternal(external);
      return;
    }
    const destination = link.dataset.mdLink;
    if (destination === undefined) return;

    const withoutFragment = destination.split("#")[0] ?? destination;
    const directory = window.marc.path.dirname(this.document.path);
    const resolved = window.marc.path.resolve(window.marc.path.join(directory, withoutFragment));
    // A link to a file that is not there yet offers to create it.
    this.store.openLink(resolved, this.document);
  }

  scrollTo(blockID) {
    const node = this.blockElements.get(blockID);
    if (node === undefined) return false;
    const offset = node.offsetTop - this.page.offsetTop;
    this.element.scrollTo({ top: Math.max(0, offset - 8), behavior: "smooth" });
    return true;
  }

  setHighlight(blockID) {
    if (this.highlightTarget !== null) {
      const previous = this.blockElements.get(this.highlightTarget);
      if (previous !== undefined) previous.classList.remove("attention-highlight");
    }
    if (this.highlightTimer !== null) clearTimeout(this.highlightTimer);
    this.highlightTarget = blockID;
    if (blockID === null) return;

    const node = this.blockElements.get(blockID);
    if (node !== undefined) node.classList.add("attention-highlight");
    this.highlightTimer = setTimeout(() => {
      if (this.highlightTarget !== blockID) return;
      this.setHighlight(null);
    }, 2000);
  }

  /*
   * Reading progress: a passage becomes read after dwelling near the reading
   * line, so that fast scrolling does not clear the document.
   */
  scheduleReadingUpdate() {
    if (this.scrollFrame !== null) return;
    this.scrollFrame = requestAnimationFrame(() => {
      this.scrollFrame = null;
      this.updateReadingCandidate();
    });
  }

  updateReadingCandidate() {
    const viewportHeight = this.element.clientHeight;
    if (viewportHeight === 0) return;
    const containerTop = this.element.getBoundingClientRect().top;
    const readingLine = viewportHeight * READING_LINE_FRACTION;
    const pending = this.document.pendingReadingBlocks;

    let crossing = null;
    let nearest = null;
    let nearestDistance = Infinity;

    for (const block of pending) {
      const node = this.blockElements.get(block.id);
      if (node === undefined) continue;
      const rect = node.getBoundingClientRect();
      const minY = rect.top - containerTop;
      const maxY = rect.bottom - containerTop;

      if (crossing === null && minY <= readingLine && maxY >= readingLine) {
        crossing = block;
      }
      if (maxY >= 0 && minY <= viewportHeight) {
        const distance = Math.abs((minY + maxY) / 2 - readingLine);
        if (distance < nearestDistance) {
          nearestDistance = distance;
          nearest = block;
        }
      }
    }

    const candidate = (crossing ?? nearest)?.id ?? null;
    if (candidate === this.readingCandidateID) return;

    if (this.readingTimer !== null) clearTimeout(this.readingTimer);
    this.readingCandidateID = candidate;
    if (candidate === null) return;

    this.readingTimer = setTimeout(() => {
      if (this.readingCandidateID !== candidate) return;
      if (!this.document.markBlockRead(candidate)) return;
      this.store.savePreferences(this.document);
      this.refreshGutter(candidate);
      this.store.emit("tabs", "toc", "status");
    }, READING_DWELL);
  }
}
