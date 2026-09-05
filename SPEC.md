# marc Product Specification and Implementation Plan

## Product intent

marc is a personal, native macOS Markdown and HTML editor and reader optimized
for documents produced by AI agents. Its primary job is to turn large, structurally
dense Markdown files into calm, navigable reading experiences without taking
away direct access to the source.

The initial product is deliberately local-first. It opens ordinary files, writes
ordinary Markdown, does not require an account, and stores presentation metadata
outside the document.

## Goals

1. Behave like a normal macOS application that can own `.md` files and open
   `.html` files as first-class documents.
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
- Rendering arbitrary embedded HTML inside a Markdown document
- Running an HTML document as a general-purpose browser tab

## Core user experience

### Opening and document ownership

marc declares itself an Editor for Markdown content types in its app bundle, and
an alternate Editor for HTML, so it appears under Open With for `.html` without
taking those files from the browser. Files can be opened through Finder, the Open
panel, drag and drop, Markdown links, wiki links, HTML links, or recent-file
shortcuts. Multiple files appear as tabs in one
workspace. Open tab paths, order, and selection are persisted continuously and
restored on the next launch; moved or deleted files are skipped.

Tabs can be organized into persistent, collapsible project groups. A group may
remember a folder and automatically include future Markdown files opened from
that folder or its descendants. Files can be reassigned or left ungrouped, groups
can be reordered, tabs can sort by open order, file name, or folder, and tabs can
be dragged directly between group headers.

Group names act as titles above their tab lanes. Expanded tabs share available
window width and shrink uniformly like browser tabs, hiding secondary chrome as
space tightens. Horizontal scrolling is used only after tabs reach their minimum
readable width.

### Reading and editing

Each tab supports three modes:

- **Rendered**: the default, reading-first view
- **Split**: source and rendered views side by side
- **Source**: direct plain-text editing

Edits auto-save after a short debounce and can also be saved explicitly.
marc watches file modification dates. If an agent changes a clean document,
the view refreshes automatically. If local unsaved edits exist, marc shows a
conflict banner rather than overwriting either version.

Fenced code blocks use a built-in lexical syntax highlighter with distinct
colors for comments, strings, numbers, keywords, types, functions, properties,
annotations, literals, and operators. Common fence aliases are supported for
Swift, Kotlin, Java, JavaScript, TypeScript, Python, Go, Rust, C/C++, SQL,
shell, JSON, YAML, HTML/XML, and CSS. Unlabeled blocks use conservative local
language inference and unknown languages fall back to generic highlighting.
No executable plugin or downloaded grammar is required.

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
right. It is closable from its own header, from a toggle in the toolbar, and
from the View menu, and its width is drag-resizable. Hierarchical guide rails
make heading depth visible without repeated icons or badges. Selecting an entry
scrolls the rendered document to it. Headings expose a disclosure control;
collapsing a heading hides all content through the next heading of the same or
higher level.

A View menu carries the outline and linked-files toggles, outline placement, and
the document view mode, so every panel can be reached without the toolbar. marc
turns off macOS window tabbing, which otherwise contributes a Show Tab Bar item
that claims the same shortcut as the outline toggle and window commands that do
not apply to marc's own tabs.

### Reading progress and update awareness

Each semantic Markdown block has a deterministic revision identity. Newly opened
content begins unread. Unchanged blocks preserve their read state even when other
content is inserted around them.

Every re-parse is matched against the previous revision of the document, so an
edited block is recognized as a revision of the block that stood in its place
rather than as unrelated new content. Matching is confined to blocks of the same
kind under the same heading. Where the change came from decides what it means:
text typed in marc's own editor is already read and never raises a marker, while
text written by an agent or another tool is marked as updated when its previous
version had been read and as unread when it had not.

A block becomes read once it has been on screen and then travelled above the
reading line, so scrolling quickly through a section still retires it, and the
block resting on that line is read after a short dwell. Only blocks that were
actually displayed can be retired this way, so jumping into the middle of a
document from the outline never marks the pages that were skipped.

Blue gutter marks represent unread content and orange marks represent externally
updated content. The same state is aggregated into outline and tab badges, with
previous/next navigation, a compact in-app status strip, and manual section or
document read controls. No system notifications or permission prompts are used.

### HTML documents

HTML files open as documents, not as an embedded browser. Their outline, block
identities, reading progress, link-graph membership, per-file settings, and
external-change handling work the way they do for Markdown, because those
features depend on structure rather than on Markdown itself. Structure is read
from the HTML source, and a small injected reader reports where those same
elements sit on screen so navigation and reading progress track the rendered
page.

Pages that are applications rather than documents are recognized as such and get
no reading progress, since unread counts over a page with no prose are noise.
The classification is shown and can be overridden per file.

The page is loaded with read access limited to its own folder, in a data store
that does not outlive the tab, with all network access blocked until allowed for
that file, and with navigation away from the file refused. The page's own colors
and fonts are left alone. The full design is in
[HTML-SUPPORT-SPEC.md](HTML-SUPPORT-SPEC.md).

### On-demand attention analysis

An explicitly requested local analysis can rank sections likely to be urgent,
important, or review-worthy. It is not automatic, does not modify the document,
and presents only source-linked suggestions. The complete design, model
restrictions, evaluation gate, and non-goals are defined in
[ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md](ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md).

### Linked-document graph

marc recognizes relative links and `[[wiki links]]` to any file it can open, in
both directions between formats, so a plan in Markdown and a demo in HTML appear
in one graph. Links out to the web are not graph nodes. The graph panel
is closed by default and shows the current document as a central node with its
referenced Markdown files around it. Existing references open in a tab. Missing
references are visibly distinct and are not silently created.

Nodes are placed on concentric rings sized so that cards never overlap at any
reference count, and edges stop at each card's boundary. The graph is scaled to
fit, then panned and zoomed by drag and pinch, with a double-click reset. The
panel itself is resizable and closable, and link existence is resolved once per
reference set off the main thread rather than during layout.

## Quality-of-life behavior

- Search within the current source document
- Recent-file menu on the welcome screen
- Automatic workspace restoration after quitting and reopening the app
- Closeable tabs with dirty-state indicators
- Persistent project tab groups with automatic folder assignment
- Copy current file path
- Reveal current file in Finder
- Keyboard shortcuts for open, save, view modes, table of contents, graph, and theme
- Closable, drag-resizable outline and linked-files panels
- Empty-state guidance
- Missing-link and disk-write errors surfaced in the UI
- Horizontal reading-width limit instead of edge-to-edge prose
- Full-window reading width and standard `⌘+`, `⌘−`, and `⌘0` text sizing
- An always-available document scrollbar whose contrast follows the page theme
- Source position preservation during ordinary edits

## Architecture

marc uses SwiftUI with selective AppKit integration:

- `MarcApp`: lifecycle, file-open events, and commands
- `DocumentStore`: open tabs, selection, recent files, persistence, and errors
- `DocumentGroup`: project grouping, collapse state, ordering, and folder rules
- `MarkdownDocument`: file contents, dirty state, external-change monitoring
- `MarcCore`: lightweight structural block parsers and reference extraction
- `HTMLParser`: heading, block, reference, and page-shape extraction from HTML
- `HTMLPreview`: sandboxed web view and the reader bridge that reports positions
- `DocumentFormat`: the file kinds marc opens as documents
- `AttentionAnalyzer`: local semantic chunking, Apple embeddings, and reviewed
  attention profiles
- `SyntaxHighlighter`: dependency-free lexical highlighting and language aliases
- `ReferenceGraphLayout`: deterministic, non-overlapping ring layout for the graph
- `ReadingAlignment`: matches a document's blocks against their previous revision
- `ReadingScrollTracker`: turns block positions on screen into reading progress
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
- Markdown and HTML are only written after direct edits in the source editor.
- HTML documents cannot reach the network until allowed for that file, cannot
  read outside their own folder, and cannot navigate away from themselves.
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
- Opening several Markdown or HTML files creates selectable, closeable tabs.
- An HTML document produces an outline, a link graph entry, and reading marks.
- An HTML document loads no external resource until it is allowed for that file.
- Tabs can be grouped, collapsed, reordered, sorted, and restored across launches.
- A document with headings produces a navigable table of contents.
- Collapsing a heading hides its section and nested sections.
- Theme changes persist after closing and reopening a file.
- Clicking an existing referenced Markdown file opens it in a tab.
- External clean-file changes refresh; dirty-file changes produce a conflict.
- The link graph and table of contents can both be hidden.
