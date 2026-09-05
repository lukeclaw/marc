# marc

marc is a native macOS Markdown workspace built for reading and editing long,
AI-generated Markdown documents.

## Features

- Native `.md` document registration, suitable for use as the default Markdown app
- Rendered, source, and split views
- New Markdown files from the File menu (⌘N), toolbar, welcome screen, tab bar, project group, or a missing link
- Per-file themes stored without changing the Markdown file
- Collapsible heading sections
- Navigable table of contents on either side, closable and drag-resizable
- In-app tabs for multiple files
- Persistent, collapsible project groups with folder auto-assignment and tab sorting
- Full-window or custom-width pages and `⌘+`/`⌘−` per-file text sizing
- Drag-resizable table columns and drag-and-drop movement between project groups
- Automatic restoration of open tabs, tab order, selection, groups, and per-file view state
- Persistent unread and externally updated passage tracking that survives edits, with UI-only navigation
- Click-triggered local attention suggestions for urgent, important, and review-worthy passages
- Rich built-in syntax highlighting for common fenced-code languages, with safe language inference
- Browser-style proportional tabs with group titles above each tab lane
- Persistent high-contrast document scrollbars for light and dark themes
- Linked-Markdown graph, closed by default, with pan, zoom, and a resizable panel
- Automatic refresh when an external tool or AI agent changes an open file
- Local Markdown link and wiki-link navigation
- A View menu for panels, outline placement, and document view mode
- Find, recent files, drag-and-drop opening, and keyboard shortcuts

## Build

Requirements: macOS 14 or later and Xcode Command Line Tools.

```sh
./scripts/build-app.sh
open ./dist/marc.app
```

The release script builds a universal Apple Silicon and Intel app.

To build and replace the copy in `/Applications` (the one the Dock launches):

```sh
./scripts/install-app.sh
```

It quits a running marc first. Set `MARC_INSTALL_DIR` to install somewhere else.

## Rebuild automatically on pull and push

Committed git hooks in `scripts/hooks` run `install-app.sh` after a merge,
rebase, or branch checkout, and before a push. Enable them once per clone:

```sh
git config core.hooksPath scripts/hooks
```

The hooks skip the build when `HEAD` has not moved since the last install and
nothing under `Sources`, `scripts`, `AppBundle`, or `Package.swift` is modified.
Set `MARC_SKIP_AUTO_INSTALL=1` for a single git command to skip them entirely.

For development:

```sh
swift run marc
swift run marc-checks
```

## Make marc the default for Markdown

Build and move `dist/marc.app` to `/Applications`, then:

1. In Finder, select any `.md` file and choose **File > Get Info**.
2. Under **Open with**, select **marc**.
3. Click **Change All**.

macOS will then route Markdown files to marc.

See [SPEC.md](SPEC.md) for the product and implementation plan and
[future-direction.md](future-direction.md) for the roadmap. The click-triggered
local embeddings beta is specified in
[ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md](ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md).
