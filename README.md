# marc

marc is a native macOS Markdown workspace built for reading and editing long,
AI-generated Markdown documents.

## Features

- Native `.md` document registration, suitable for use as the default Markdown app
- Rendered, source, and split views
- Per-file themes stored without changing the Markdown file
- Collapsible heading sections
- Navigable table of contents on either side
- In-app tabs for multiple files
- Persistent, collapsible project groups with folder auto-assignment and tab sorting
- Full-window or custom-width pages and `⌘+`/`⌘−` per-file text sizing
- Drag-resizable table columns and drag-and-drop movement between project groups
- Automatic restoration of open tabs, tab order, selection, groups, and per-file view state
- Persistent unread and externally updated passage tracking with UI-only navigation
- Click-triggered local attention suggestions for urgent, important, and review-worthy passages
- Linked-Markdown graph, closed by default
- Automatic refresh when an external tool or AI agent changes an open file
- Local Markdown link and wiki-link navigation
- Find, recent files, drag-and-drop opening, and keyboard shortcuts

## Build

Requirements: macOS 14 or later and Xcode Command Line Tools.

```sh
./scripts/build-app.sh
open ./dist/marc.app
```

The release script builds a universal Apple Silicon and Intel app.

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
