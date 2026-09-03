/*
 * marc — value types and theme presets.
 *
 * Port of Sources/Marc/Models.swift. The preference JSON shape is unchanged so
 * that a file-preferences.json written by the macOS build stays readable.
 */
"use strict";

const MarcModels = (() => {
  const WORKSPACE_MODES = [
    { id: "rendered", label: "Rendered", icon: "doc" },
    { id: "split", label: "Split", icon: "split" },
    { id: "source", label: "Source", icon: "code" }
  ];

  const TAB_SORT_ORDERS = [
    { id: "opened", label: "Open Order" },
    { id: "name", label: "File Name" },
    { id: "folder", label: "Folder" }
  ];

  const MARKDOWN_EXTENSIONS = ["md", "markdown", "mdown", "mkd"];

  const GROUP_PALETTE = ["#4F6BED", "#8B5CF6", "#0F9D8A", "#D97706", "#DC5A6A", "#457B9D"];

  /*
   * The presets keep their macOS font names so that preferences round-trip, and
   * each name maps to the closest Windows stack that is actually installed.
   */
  const FONT_CHOICES = ["New York", "Charter", "Avenir Next", "Georgia", "Helvetica Neue"];

  const FONT_STACKS = {
    "New York": '"New York", Georgia, Cambria, "Times New Roman", serif',
    Charter: 'Charter, "Bitstream Charter", Cambria, Constantia, Georgia, serif',
    "Avenir Next": '"Avenir Next", "Segoe UI Variable Text", "Segoe UI", system-ui, sans-serif',
    Georgia: 'Georgia, Cambria, "Times New Roman", serif',
    "Helvetica Neue": '"Helvetica Neue", Arial, "Segoe UI", system-ui, sans-serif'
  };

  function fontStack(family) {
    return FONT_STACKS[family] ?? `"${family}", "Segoe UI", system-ui, sans-serif`;
  }

  const THEME_PRESETS = [
    {
      id: "paper",
      name: "Paper",
      fontFamily: "New York",
      bodySize: 16,
      pageWidth: 760,
      fullWidth: false,
      background: { hex: "#FBFAF7" },
      text: { hex: "#252422" },
      heading: { hex: "#4A5568" },
      accent: { hex: "#2B6CB0" },
      codeBackground: { hex: "#EEECE7" },
      quote: { hex: "#718096" }
    },
    {
      id: "midnight",
      name: "Midnight",
      fontFamily: "Avenir Next",
      bodySize: 16,
      pageWidth: 780,
      fullWidth: false,
      background: { hex: "#111827" },
      text: { hex: "#E5E7EB" },
      heading: { hex: "#93C5FD" },
      accent: { hex: "#60A5FA" },
      codeBackground: { hex: "#1F2937" },
      quote: { hex: "#9CA3AF" }
    },
    {
      id: "forest",
      name: "Forest",
      fontFamily: "Charter",
      bodySize: 17,
      pageWidth: 740,
      fullWidth: false,
      background: { hex: "#F3F6F1" },
      text: { hex: "#243128" },
      heading: { hex: "#2F6B4F" },
      accent: { hex: "#3A7D5D" },
      codeBackground: { hex: "#E1E9DE" },
      quote: { hex: "#587064" }
    },
    {
      id: "solar",
      name: "Solar",
      fontFamily: "Georgia",
      bodySize: 17,
      pageWidth: 760,
      fullWidth: false,
      background: { hex: "#FFF8E7" },
      text: { hex: "#44392E" },
      heading: { hex: "#B45309" },
      accent: { hex: "#C2410C" },
      codeBackground: { hex: "#F5E9D0" },
      quote: { hex: "#8A6D4B" }
    }
  ];

  const THEME_COLOR_KEYS = ["background", "text", "heading", "accent", "codeBackground", "quote"];

  function clone(value) {
    return JSON.parse(JSON.stringify(value));
  }

  function themePreset(id) {
    const preset = THEME_PRESETS.find((theme) => theme.id === id);
    return preset === undefined ? null : clone(preset);
  }

  function defaultTheme() {
    return themePreset("paper");
  }

  /** Normalize any stored theme, filling in fields written by older versions. */
  function normalizeTheme(theme) {
    const base = defaultTheme();
    if (theme === null || typeof theme !== "object") return base;
    const merged = { ...base, ...theme };
    for (const key of THEME_COLOR_KEYS) {
      const value = theme[key];
      merged[key] =
        value !== null && typeof value === "object" && typeof value.hex === "string"
          ? { hex: normalizeHex(value.hex) }
          : base[key];
    }
    merged.fullWidth = theme.fullWidth === true;
    merged.bodySize = clampNumber(merged.bodySize, 8, 72, base.bodySize);
    merged.pageWidth = clampNumber(merged.pageWidth, 420, 2400, base.pageWidth);
    if (typeof merged.fontFamily !== "string" || merged.fontFamily.length === 0) {
      merged.fontFamily = base.fontFamily;
    }
    if (typeof merged.id !== "string") merged.id = "custom";
    if (typeof merged.name !== "string") merged.name = "Custom";
    return merged;
  }

  function clampNumber(value, minimum, maximum, fallback) {
    const number = Number(value);
    if (!Number.isFinite(number)) return fallback;
    return Math.min(maximum, Math.max(minimum, number));
  }

  function normalizeHex(hex) {
    let value = String(hex).replace(/[^0-9a-f]/giu, "");
    if (value.length === 3) {
      value = value.split("").map((character) => character + character).join("");
    }
    if (value.length !== 6) return "#000000";
    return `#${value.toUpperCase()}`;
  }

  function defaultPreferences() {
    return {
      theme: defaultTheme(),
      collapsedHeadingIDs: [],
      lastScrollHeadingID: null,
      tableColumnWidths: null,
      tableWidthLayoutVersion: null,
      readingState: null
    };
  }

  /** Accept preferences written by either platform, including Swift Sets. */
  function normalizePreferences(raw) {
    const base = defaultPreferences();
    if (raw === null || typeof raw !== "object") return base;

    const preferences = {
      theme: normalizeTheme(raw.theme),
      collapsedHeadingIDs: Array.isArray(raw.collapsedHeadingIDs) ? [...raw.collapsedHeadingIDs] : [],
      lastScrollHeadingID:
        typeof raw.lastScrollHeadingID === "string" ? raw.lastScrollHeadingID : null,
      tableColumnWidths:
        raw.tableColumnWidths !== null && typeof raw.tableColumnWidths === "object"
          ? { ...raw.tableColumnWidths }
          : null,
      tableWidthLayoutVersion:
        Number.isFinite(raw.tableWidthLayoutVersion) ? raw.tableWidthLayoutVersion : null,
      readingState: null
    };

    const state = raw.readingState;
    if (state !== null && typeof state === "object" && Array.isArray(state.baseline)) {
      preferences.readingState = {
        baseline: state.baseline
          .filter((entry) => entry !== null && typeof entry === "object")
          .map((entry) => ({ id: String(entry.id), signature: String(entry.signature) })),
        readVersions: new Set(Array.isArray(state.readVersions) ? state.readVersions : []),
        changedVersions: new Set(Array.isArray(state.changedVersions) ? state.changedVersions : [])
      };
    }

    return preferences;
  }

  /** Convert to the JSON shape stored on disk (Sets become arrays). */
  function serializePreferences(preferences) {
    return {
      theme: preferences.theme,
      collapsedHeadingIDs: [...preferences.collapsedHeadingIDs],
      lastScrollHeadingID: preferences.lastScrollHeadingID,
      tableColumnWidths: preferences.tableColumnWidths,
      tableWidthLayoutVersion: preferences.tableWidthLayoutVersion,
      readingState:
        preferences.readingState === null
          ? null
          : {
              baseline: preferences.readingState.baseline,
              readVersions: [...preferences.readingState.readVersions],
              changedVersions: [...preferences.readingState.changedVersions]
            }
    };
  }

  const DEFAULT_SETTINGS = {
    recentMarkdownFiles: [],
    tabSortOrder: "opened",
    workspaceMode: "rendered",
    tocPosition: "left",
    showTableOfContents: true,
    attentionAnalysisAcknowledged: false
  };

  return {
    WORKSPACE_MODES,
    TAB_SORT_ORDERS,
    MARKDOWN_EXTENSIONS,
    GROUP_PALETTE,
    FONT_CHOICES,
    FONT_STACKS,
    THEME_PRESETS,
    THEME_COLOR_KEYS,
    DEFAULT_SETTINGS,
    fontStack,
    themePreset,
    defaultTheme,
    normalizeTheme,
    normalizeHex,
    defaultPreferences,
    normalizePreferences,
    serializePreferences,
    clone
  };
})();
