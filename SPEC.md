# marc Product Specification and Implementation Plan

## Product intent

marc is a personal, native macOS Markdown editor and reader optimized for
documents produced by AI agents. Its primary job is to turn large, structurally
dense Markdown files into calm, navigable reading experiences without taking
away direct access to the source.

The initial product is deliberately local-first. It opens ordinary files, writes
ordinary Markdown, does not require an account, and stores presentation metadata
outside the document.

## Goals

1. Behave like a normal macOS application that can own `.md` files.
2. Make long Markdown significantly easier to scan, navigate, and collapse.
3. Allow each document to have its own visual identity.
4. Make a collection of cross-referenced Markdown files easy to traverse.
5. Coexist safely with AI agents and other tools that update files externally.
6. Keep the document format portable and unmodified by app-specific metadata.

## Non-goals for the first version

- Rich-text/WYSIWYG editing
- Cloud sync, collaboration, or accounts
- A plugin marketplace
- Full CommonMark/GitHub Markdown parity
- Rendering arbitrary embedded HTML or executing document code

## Core user experience

### Opening and document ownership

marc declares itself an Editor for Markdown content types in its app bundle.
Files can be opened through Finder, the Open panel, drag and drop, Markdown links,
wiki links, or recent-file shortcuts. Multiple files appear as tabs in one
workspace. Open tab paths, order, and selection are persisted continuously and
restored on the next launch; moved or deleted files are skipped.

Tabs can be organized into persistent, collapsible project groups. A group may
remember a folder and automatically include future Markdown files opened from
that folder or its descendants. Files can be reassigned or left ungrouped, groups
can be reordered, tabs can sort by open order, file name, or folder, and tabs can
be dragged directly between group headers.

### Reading and editing

Each tab supports three modes:

- **Rendered**: the default, reading-first view
- **Split**: source and rendered views side by side
- **Source**: direct plain-text editing

Edits auto-save after a short debounce and can also be saved explicitly.
marc watches file modification dates. If an agent changes a clean document,
the view refreshes automatically. If local unsaved edits exist, marc shows a
conflict banner rather than overwriting either version.

### Per-file themes

Themes control page, text, accent, heading, code, and quote colors, font family,
base font size, and readable line width. Pages can use a specific width or expand
to the full available window. Preferences are keyed by normalized file
path and stored in Application Support. The Markdown remains portable.

Built-in presets provide useful starting points. Any preset can be customized
for the current file.

Rendered blocks consume the configured page width rather than retaining narrow
intrinsic widths. Table columns have draggable header dividers; their widths are
stored per table for the current file. Unmodified tables distribute columns
across the available width, switch to horizontal scrolling only when their
minimum readable widths exceed it, and render each row as one top-aligned
rectangular grid.

### Structure navigation

The table of contents derives from headings and can be shown on the left or
right. Hierarchical guide rails make heading depth visible without repeated
icons or badges. Selecting an entry scrolls the rendered document to it. Headings expose a
disclosure control; collapsing a heading hides all content through the next
heading of the same or higher level.

### Reading progress and update awareness

Each semantic Markdown block has a deterministic revision identity. Newly opened
content begins unread, while blocks inserted or changed by an external writer are
marked as updated. Unchanged blocks preserve their read state even when other
content is inserted around them.

Rendered blocks become read after dwelling in the visible reading area; fast
scrolling does not immediately clear them. Blue gutter marks represent unread
content and orange marks represent externally updated content. The same state is
aggregated into outline and tab badges, with previous/next navigation, a compact
in-app status strip, and manual section or document read controls. No system
notifications or permission prompts are used.

### On-demand attention analysis

An explicitly requested local analysis can rank sections likely to be urgent,
important, or review-worthy. It is not automatic, does not modify the document,
and presents only source-linked suggestions. The complete design, model
restrictions, evaluation gate, and non-goals are defined in
[ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md](ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md).

### Linked-document graph

marc recognizes relative Markdown links and `[[wiki links]]`. The graph panel
is closed by default and shows the current document as a central node with its
referenced Markdown files around it. Existing references open in a tab. Missing
references are visibly distinct and are not silently created.

## Quality-of-life behavior

- Search within the current source document
- Recent-file menu on the welcome screen
- Automatic workspace restoration after quitting and reopening the app
- Closeable tabs with dirty-state indicators
- Persistent project tab groups with automatic folder assignment
- Copy current file path
- Reveal current file in Finder
- Keyboard shortcuts for open, save, view modes, table of contents, graph, and theme
- Empty-state guidance
- Missing-link and disk-write errors surfaced in the UI
- Horizontal reading-width limit instead of edge-to-edge prose
- Full-window reading width and standard `⌘+`, `⌘−`, and `⌘0` text sizing
- Source position preservation during ordinary edits

## Architecture

marc uses SwiftUI with selective AppKit integration:

- `MarcApp`: lifecycle, file-open events, and commands
- `DocumentStore`: open tabs, selection, recent files, persistence, and errors
- `DocumentGroup`: project grouping, collapse state, ordering, and folder rules
- `MarkdownDocument`: file contents, dirty state, external-change monitoring
- `MarcCore`: lightweight structural block parser and reference extraction
- `AttentionAnalyzer`: local semantic chunking, Apple embeddings, and reviewed
  attention profiles
- `WorkspaceView`: tabs, sidebars, toolbar, reader/editor composition
- `MarkdownPreview`: themed structural rendering and fold state
- `ThemeStore`: per-file presentation preferences in Application Support
- `AppBundle/Info.plist`: Markdown document type declarations

The parser is intentionally structural rather than an HTML web view. This keeps
folding, navigation, native text selection, and theme control predictable. Inline
Markdown uses Foundation's Markdown attributed-string support.

## Data and safety

- No network access is required.
- Optional intelligence must be explicitly requested and use an approved local
  model; version 1 has no network provider.
- Markdown is only written after direct edits in the source editor.
- Presentation settings are stored separately as JSON.
- External changes never overwrite a dirty in-memory edit.
- Referenced files are resolved relative to the current file.
- HTML and code blocks are displayed as text, not executed.

## Implementation phases

### Phase 1: native shell and file lifecycle

- Swift package and app bundle build
- Markdown content-type registration
- Open panel, Finder open events, tabs, save, recent files
- File monitoring and conflict handling

### Phase 2: structured reading

- Heading/block parser
- Native rendered view
- Table of contents
- Heading collapse
- Rendered/source/split modes

### Phase 3: visual customization and links

- Theme presets and per-file customization
- Relative Markdown and wiki-link extraction
- Linked-document graph
- Link-to-tab navigation

### Phase 4: polish and validation

- Search and native file actions
- Keyboard shortcuts and drag/drop
- Parser tests
- Release app bundle script
- Documentation and future roadmap

## Acceptance criteria

- `swift build` and `swift run marc-checks` succeed.
- The packaged app opens as a standard `.app`.
- Its `Info.plist` declares Markdown Editor support.
- Opening several Markdown files creates selectable, closeable tabs.
- Tabs can be grouped, collapsed, reordered, sorted, and restored across launches.
- A document with headings produces a navigable table of contents.
- Collapsing a heading hides its section and nested sections.
- Theme changes persist after closing and reopening a file.
- Clicking an existing referenced Markdown file opens it in a tab.
- External clean-file changes refresh; dirty-file changes produce a conflict.
- The link graph and table of contents can both be hidden.
