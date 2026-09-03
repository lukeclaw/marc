/*
 * marc — table of contents, linked-file graph, and theme editor.
 *
 * Port of Sources/Marc/SidebarViews.swift.
 */
"use strict";

const MarcSidebars = (() => {
  const SVG_NS = "http://www.w3.org/2000/svg";

  /* ------------------------------------------------- table of contents */

  const HEADING_FONTS = {
    1: { size: 15, weight: 700, opacity: 1 },
    2: { size: 14, weight: 600, opacity: 0.92 },
    3: { size: 13, weight: 500, opacity: 0.82 },
    4: { size: 12.5, weight: 400, opacity: 0.74 },
    5: { size: 12, weight: 400, opacity: 0.66 },
    6: { size: 11.5, weight: 400, opacity: 0.66 }
  };

  function rowHeight(level) {
    if (level === 1) return 38;
    if (level === 2) return 36;
    return 32;
  }

  /* Hierarchical rails make heading depth visible without badges or icons. */
  function outlineGuides(depth, accent, height) {
    const width = depth === 0 ? 5 : depth * 13 + 8;
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("class", "guides");
    svg.setAttribute("width", String(width));
    svg.setAttribute("height", String(height));
    svg.setAttribute("viewBox", `0 0 ${width} ${height}`);

    if (depth > 0) {
      for (let level = 0; level < depth; level += 1) {
        const x = level * 13 + 5;
        const line = document.createElementNS(SVG_NS, "line");
        line.setAttribute("x1", String(x));
        line.setAttribute("y1", "0");
        line.setAttribute("x2", String(x));
        line.setAttribute("y2", String(height));
        line.setAttribute("stroke", accent);
        line.setAttribute("stroke-opacity", level === depth - 1 ? "0.42" : "0.2");
        line.setAttribute("stroke-width", "1");
        svg.append(line);
      }
      const currentX = (depth - 1) * 13 + 5;
      const branch = document.createElementNS(SVG_NS, "line");
      branch.setAttribute("x1", String(currentX));
      branch.setAttribute("y1", String(height / 2));
      branch.setAttribute("x2", String(width));
      branch.setAttribute("y2", String(height / 2));
      branch.setAttribute("stroke", accent);
      branch.setAttribute("stroke-opacity", "0.42");
      branch.setAttribute("stroke-width", "1");
      svg.append(branch);
    }
    return svg;
  }

  function readingCounts(document_, headingID) {
    let unread = 0;
    let changed = 0;
    for (const block of document_.parsed.blocks) {
      if (block.id !== headingID && !block.ancestorHeadingIDs.includes(headingID)) continue;
      const status = document_.readingStatus(block);
      if (status === "unread") unread += 1;
      else if (status === "changed") changed += 1;
    }
    return { unread, changed };
  }

  function attentionCount(document_, headingID) {
    const sectionBlockIDs = new Set(
      document_.parsed.blocks
        .filter((block) => block.id === headingID || block.ancestorHeadingIDs.includes(headingID))
        .map((block) => block.id)
    );
    const chunks = new Set(
      document_.attentionResults
        .filter((result) => result.blockIDs.some((id) => sectionBlockIDs.has(id)))
        .map((result) => result.chunkID)
    );
    return chunks.size;
  }

  function tableOfContents(store, document_, callbacks) {
    const headings = document_.parsed.headings;
    const accent = document_.preferences.theme.accent.hex;
    const baseLevel = headings.length === 0 ? 1 : Math.min(...headings.map((heading) => heading.level));

    const panel = UI.el("aside.sidebar.toc");
    panel.append(
      UI.el("div.sidebar-header", { title: `${headings.length} headings` }, [
        UI.icon("outline"),
        UI.el("span", { text: "Outline" })
      ])
    );

    if (headings.length === 0) {
      panel.append(
        UI.el("div.empty-state", null, [
          UI.icon("outline"),
          UI.el("div.title", { text: "No Headings" }),
          UI.el("div.description", { text: "Add Markdown headings to build an outline." })
        ])
      );
      return panel;
    }

    const body = UI.el("div.sidebar-body.scroll");
    const list = UI.el("div.outline-list");

    for (const heading of headings) {
      const depth = Math.max(0, heading.level - baseLevel);
      const font = HEADING_FONTS[heading.level] ?? HEADING_FONTS[6];
      const counts = readingCounts(document_, heading.id);
      const attention = attentionCount(document_, heading.id);
      const selected = document_.preferences.lastScrollHeadingID === heading.id;

      const row = UI.el(
        "button.outline-row",
        {
          title: `H${heading.level} · ${heading.title}`,
          class: selected ? "selected" : "",
          style: { height: `${rowHeight(heading.level)}px` },
          on: {
            click: () => callbacks.navigate(heading.id),
            contextmenu: (event) =>
              UI.contextMenuAt(
                [
                  { label: "Mark Section Read", action: () => callbacks.markSection(heading.id, true) },
                  { label: "Mark Section Unread", action: () => callbacks.markSection(heading.id, false) }
                ],
                event
              )
          }
        },
        [
          outlineGuides(Math.min(depth, 5), accent, rowHeight(heading.level)),
          UI.el("span.label", {
            text: heading.title,
            style: {
              fontSize: `${font.size}px`,
              fontWeight: String(font.weight),
              opacity: selected ? "1" : String(font.opacity)
            }
          }),
          attention > 0
            ? UI.badge(attention, "var(--attention)", document_.attentionResultsAreStale ? 0.4 : 1)
            : null,
          counts.changed > 0
            ? UI.badge(counts.changed, "var(--changed)")
            : counts.unread > 0
              ? UI.badge(counts.unread, "var(--unread)")
              : null
        ]
      );
      list.append(row);
    }

    body.append(list);
    panel.append(body);
    return panel;
  }

  /* --------------------------------------------------------------- graph */

  function referenceGraph(store, document_) {
    const references = document_.parsed.references;
    const accent = document_.preferences.theme.accent.hex;

    const panel = UI.el("aside.sidebar.graph");
    panel.append(
      UI.el("div.sidebar-header", null, [
        UI.el("span", { text: "LINKED FILES" }),
        UI.el("span.spacer"),
        UI.el("span", { text: String(references.length) })
      ])
    );

    if (references.length === 0) {
      panel.append(
        UI.el("div.empty-state", null, [
          UI.icon("graph"),
          UI.el("div.title", { text: "No Markdown Links" }),
          UI.el("div.description", {
            text: "Relative .md links and [[wiki links]] appear here."
          })
        ])
      );
      return panel;
    }

    const canvas = UI.el("div.graph-canvas");
    const svg = document.createElementNS(SVG_NS, "svg");
    svg.setAttribute("width", "100%");
    svg.setAttribute("height", "100%");
    svg.style.position = "absolute";
    svg.style.inset = "0";
    canvas.append(svg);

    const current = UI.el("div.graph-node.current", null, [
      UI.el("span", { text: document_.displayName }),
      UI.el("span.subtitle", { text: "Current" })
    ]);
    canvas.append(current);

    const nodes = references.map((reference) => {
      const exists = store.referenceExists(reference);
      const node = UI.el(
        "button.graph-node",
        {
          class: exists ? "" : "missing",
          title: reference.destination,
          on: { click: () => store.openReference(reference, document_) }
        },
        [
          UI.el("span", { text: reference.label }),
          UI.el("span.subtitle", {
            text: exists
              ? window.marc.path.basename(reference.resolvedPath ?? reference.destination)
              : "Missing"
          })
        ]
      );
      canvas.append(node);
      return node;
    });

    // Radial layout, laid out once the panel has real dimensions.
    const layout = () => {
      const width = canvas.clientWidth;
      const height = canvas.clientHeight;
      if (width === 0 || height === 0) return;
      const centerX = width / 2;
      const centerY = height / 2;
      const radius = Math.min(width, height) * 0.36;

      current.style.left = `${centerX}px`;
      current.style.top = `${centerY}px`;
      UI.clear(svg);

      nodes.forEach((node, index) => {
        const angle = (index / Math.max(1, references.length)) * 2 * Math.PI - Math.PI / 2;
        const x = centerX + Math.cos(angle) * radius;
        const y = centerY + Math.sin(angle) * radius;
        node.style.left = `${x}px`;
        node.style.top = `${y}px`;

        const line = document.createElementNS(SVG_NS, "line");
        line.setAttribute("x1", String(centerX));
        line.setAttribute("y1", String(centerY));
        line.setAttribute("x2", String(x));
        line.setAttribute("y2", String(y));
        line.setAttribute("stroke", accent);
        line.setAttribute("stroke-opacity", "0.28");
        line.setAttribute("stroke-width", "1");
        svg.append(line);
      });
    };

    panel.append(canvas);
    requestAnimationFrame(layout);
    const observer = new ResizeObserver(layout);
    observer.observe(canvas);

    const body = UI.el("div.sidebar-body.scroll", { style: { maxHeight: "180px", flex: "none" } });
    for (const reference of references) {
      const exists = store.referenceExists(reference);
      const row = UI.el("div.reference-row-group", null, [
        UI.el(
          "button.reference-row",
          { on: { click: () => store.openReference(reference, document_) } },
          [
            UI.icon(exists ? "doc" : "missing", exists ? "" : "missing"),
            UI.el("span", { style: { minWidth: "0", flex: "1" } }, [
              UI.el("div.label", { text: reference.label }),
              UI.el("div.destination", { text: reference.destination })
            ])
          ]
        )
      ]);
      if (!exists) {
        row.append(
          UI.el("button.link-button.create", {
            text: "Create",
            title: `Create ${reference.destination} and open it`,
            on: {
              click: (event) => {
                event.stopPropagation();
                store.createFileForReference(reference, document_);
              }
            }
          })
        );
      }
      body.append(row);
    }
    panel.append(UI.el("div.pane-divider", { style: { width: "auto", height: "1px" } }), body);
    return panel;
  }

  /* -------------------------------------------------------- theme editor */

  function themeEditor(store, document_, onChange) {
    const theme = document_.preferences.theme;

    const markCustom = () => {
      theme.id = "custom";
      theme.name = "Custom";
    };
    const commit = () => {
      store.savePreferences(document_);
      onChange();
    };

    const container = UI.el("div");
    container.append(
      UI.el("h2", { text: "Document Theme" }),
      UI.el("div.caption", { text: "Saved for this file without changing its Markdown." })
    );

    const presetSelect = UI.el("select");
    for (const preset of MarcModels.THEME_PRESETS) {
      presetSelect.append(UI.el("option", { value: preset.id, text: preset.name }));
    }
    if (!MarcModels.THEME_PRESETS.some((preset) => preset.id === theme.id)) {
      presetSelect.append(UI.el("option", { value: theme.id, text: "Custom" }));
    }
    presetSelect.value = theme.id;
    presetSelect.addEventListener("change", () => {
      const preset = MarcModels.themePreset(presetSelect.value);
      if (preset === null) return;
      document_.preferences.theme = preset;
      commit();
    });
    container.append(field("Preset", [presetSelect]));

    container.append(UI.el("div.divider"));

    const fontSelect = UI.el("select");
    for (const family of MarcModels.FONT_CHOICES) {
      fontSelect.append(UI.el("option", { value: family, text: family }));
    }
    if (!MarcModels.FONT_CHOICES.includes(theme.fontFamily)) {
      fontSelect.append(UI.el("option", { value: theme.fontFamily, text: theme.fontFamily }));
    }
    fontSelect.value = theme.fontFamily;
    fontSelect.addEventListener("change", () => {
      theme.fontFamily = fontSelect.value;
      commit();
    });
    container.append(field("Font", [fontSelect]));

    const sizeValue = UI.el("span.value", { text: String(Math.round(theme.bodySize)) });
    const sizeSlider = UI.el("input", {
      type: "range",
      min: "8",
      max: "72",
      step: "1",
      value: String(theme.bodySize)
    });
    sizeSlider.addEventListener("input", () => {
      theme.bodySize = Number(sizeSlider.value);
      sizeValue.textContent = sizeSlider.value;
      markCustom();
      commit();
    });
    container.append(field("Text size", [sizeSlider, sizeValue]));

    const fullWidthToggle = UI.el("input", { type: "checkbox", checked: theme.fullWidth === true });
    fullWidthToggle.addEventListener("change", () => {
      theme.fullWidth = fullWidthToggle.checked;
      markCustom();
      widthRow.style.display = fullWidthToggle.checked ? "none" : "flex";
      commit();
    });
    container.append(field("Full width", [fullWidthToggle]));

    const widthValue = UI.el("span.value", { text: String(Math.round(theme.pageWidth)) });
    const widthSlider = UI.el("input", {
      type: "range",
      min: "420",
      max: "2400",
      step: "20",
      value: String(theme.pageWidth)
    });
    widthSlider.addEventListener("input", () => {
      theme.pageWidth = Number(widthSlider.value);
      widthValue.textContent = widthSlider.value;
      markCustom();
      commit();
    });
    const widthRow = field("Page width", [widthSlider, widthValue]);
    if (theme.fullWidth === true) widthRow.style.display = "none";
    container.append(widthRow);

    container.append(UI.el("div.divider"));

    const colorRows = [
      ["Page", "background"],
      ["Text", "text"],
      ["Headings", "heading"],
      ["Accent", "accent"],
      ["Code", "codeBackground"],
      ["Quotes", "quote"]
    ];
    for (const [label, key] of colorRows) {
      const picker = UI.el("input", { type: "color", value: theme[key].hex });
      picker.addEventListener("input", () => {
        theme[key] = { hex: MarcModels.normalizeHex(picker.value) };
        markCustom();
        commit();
      });
      container.append(field(label, [picker]));
    }

    container.append(
      UI.el("div.popover-actions", null, [
        UI.el("button.secondary-button", {
          text: "Reset to Paper",
          on: {
            click: () => {
              document_.preferences.theme = MarcModels.themePreset("paper");
              UI.dismissAll();
              commit();
            }
          }
        })
      ])
    );
    return container;
  }

  function field(label, controls) {
    return UI.el("div.field-row", null, [
      UI.el("label", { text: label }),
      UI.el("div.control", null, controls)
    ]);
  }

  return { tableOfContents, referenceGraph, themeEditor };
})();
