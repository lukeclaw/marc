# marc

marc is a Markdown workspace built for reading and editing long, AI-generated
Markdown documents. macOS is the primary, native build; `windows/` holds an
Electron port of the same product.

## Features

- Native `.md` document registration, suitable for use as the default Markdown app
- Rendered, source, and split views
- Per-file themes stored without changing the Markdown file
- Collapsible heading sections
- Navigable table of contents on either side
- In-app tabs for multiple files
- Persistent, collapsible project groups with folder auto-assignment and tab sorting
- Full-window or custom-width pages and `⌘+`/`⌘−` (`Ctrl+`/`Ctrl−`) per-file text sizing
- Drag-resizable table columns and drag-and-drop movement between project groups
- Automatic restoration of open tabs, tab order, selection, groups, and per-file view state
- Persistent unread and externally updated passage tracking with UI-only navigation
- Click-triggered local attention suggestions for urgent, important, and review-worthy passages
- Linked-Markdown graph, closed by default
- Automatic refresh when an external tool or AI agent changes an open file
- Local Markdown link and wiki-link navigation
- Find, recent files, drag-and-drop opening, and keyboard shortcuts

## Build on macOS

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

## Build on Windows

Requirements: Windows 10 or later and Node.js 20 or later. The Electron port
lives in `windows/` and shares no build system with the macOS app.

```sh
cd windows
npm install
npm start
```

To build a distributable portable executable and an installer in
`windows/dist`:

```sh
npm run dist
```

`npm run pack` produces an unpacked directory instead, and `npm run icon`
regenerates `build/icon.ico`, which is a build artifact rather than source.

Two test suites cover the port, and `npm test` runs both:

```sh
npm run checks     # parser and attention analysis, headless, no Electron
npm run selftest   # the real renderer against real files in a scratch profile
```

`npm run checks` is the port of `swift run marc-checks`. `npm run selftest`
covers what only exists once the app is running — rendering, tabs, saving,
external-change handling, persistence, and the attention panel — against a
throwaway profile that never touches your own documents or settings.

## Make marc the default for Markdown

On macOS, build and move `dist/marc.app` to `/Applications`, then:

1. In Finder, select any `.md` file and choose **File > Get Info**.
2. Under **Open with**, select **marc**.
3. Click **Change All**.

macOS will then route Markdown files to marc.

On Windows, choose **File > Set marc as the Default Markdown App…** from the
menu bar. It writes the `marc.MarkdownDocument` file association under
`HKEY_CURRENT_USER`, so it needs no elevation and affects only your account.
Windows may still ask you to confirm the change the first time you open a `.md`
file.

See [SPEC.md](SPEC.md) for the product and implementation plan and
[future-direction.md](future-direction.md) for the roadmap. The click-triggered
local embeddings beta is specified in
[ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md](ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md).

[PORTING.md](PORTING.md) describes how the Windows port is kept in step with the
macOS app. To see what is currently behind:

```sh
./scripts/check-parity.sh
```
