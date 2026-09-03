# Porting marc to Windows

macOS is the source of truth. The Windows build in `windows/` is a hand-written
Electron port of it, kept in this repository so that a single history can answer
the only question that matters between releases: **which parts of the port are
behind the Mac app, and by which commits?**

## The parity manifest

[`parity.manifest`](parity.manifest) maps every file in the Windows port to the
macOS sources it was ported from. `scripts/check-parity.sh` reads it, finds the
last commit that touched each Windows file, and lists the commits after that one
which touched any of its macOS sources.

```sh
./scripts/check-parity.sh
```

```
STALE  windows/src/core/parser.js
       2 unported commit(s) in Sources/MarcCore/MarkdownParser.swift:
         92dac14 Support setext headings
         2fa18b0 Parse table column alignment markers

UNMAPPED
       macOS sources that no manifest row ports:
         Sources/Marc/ExportPanel.swift
```

It exits 0 when the port is current and 1 when anything is stale, so it works as
a release gate. Two other forms are useful:

```sh
./scripts/check-parity.sh --since v0.1.0   # everything since a release
./scripts/check-parity.sh --files          # bare paths, for scripting
```

A file stops being reported the moment a commit touches it. Porting one side and
the other in the same commit keeps the report clean, which is the cheapest way to
work when a change is small enough to do twice at once.

When you review a row and conclude the Windows side needs no change, there is no
commit to record that, so record it in the manifest instead:

```
# electron-builder already signs via signtool, so the macOS signing script
# needed no Windows counterpart.
!reviewed	windows/package.json	4570b12
```

That revision becomes the row's baseline, so the commits you just dismissed stop
being reported and anything landing after it still is. Keep the reason above it:
the line is a decision, and the next person to read the report will want to know
why those commits were waved through.

`UNMAPPED` is the check that matters most over time: add a new macOS file and the
manifest keeps saying so until you add a row for it. That is how a new feature
announces that it needs a Windows counterpart.

Two directives control which macOS files that check looks at:

```
!coverage	scripts	*.sh                      scan these files for coverage
!no-port	scripts/hooks/post-merge	reason    this one needs no port
```

`!coverage` takes a directory and a `find -name` pattern. `!no-port` exempts one
path and records why, for macOS-only files such as the auto-install hooks and for
shared tooling such as the checker itself. Anything matched by `!coverage` that
is neither a source in some row nor exempted by `!no-port` is reported.

## Working through the report

1. Run `./scripts/check-parity.sh` and read the commit list for one file.
2. Read those commits on the macOS side: `git show <sha> -- Sources/...`.
3. Apply the same change to the mapped Windows file. Every ported file names its
   macOS counterpart in its own header; keep that header accurate.
4. Run both Windows suites from `windows/`:
   ```sh
   npm test          # npm run checks, then npm run selftest
   ```
5. Commit the Windows change. The file drops out of the report.

Work one manifest row at a time rather than one macOS commit at a time. The rows
are the unit that can be tested independently.

## What is deliberately not the same

These are marked `-` in the manifest and are not drift:

| Windows file | Why there is no macOS counterpart |
| --- | --- |
| `src/core/embedding.js` | macOS uses Apple's `NLEmbedding`. Windows has no reviewed offline sentence model, and the attention spec forbids network providers and downloaded model files, so the port bundles a deterministic lexical embedder. Attention *results* therefore differ between platforms by design. |
| `src/renderer/ui.js` | Stands in for SF Symbols, `NSMenu`, SwiftUI popovers, and `NSAlert`. Adding an icon to a macOS view may still mean adding a path here. |
| `src/main/preload.js` | Electron needs an explicit renderer/main boundary. A SwiftUI app has none. |
| `src/renderer/selftest.js` | Covers the running renderer — rendering, persistence, conflict handling. The macOS build has no equivalent UI-level suite yet. |

Two more known divergences are visual rather than structural, and no manifest row
will catch them:

- **Fonts.** The theme presets name New York, Charter, and Avenir Next, none of
  which ship on Windows. `windows/src/renderer/models.js` maps each to the
  closest installed stack, so the same preset renders in a different typeface at
  the same nominal size.
- **Chrome.** SwiftUI uses semantic materials (`.regularMaterial`, `.quaternary`)
  and system control metrics. `windows/src/renderer/styles.css` hardcodes hex
  values and radii that were matched by eye. This is why `styles.css` maps to
  every view file and is the noisiest row in the manifest.

## Why one repository

The report above is a `git log` across both trees. In separate repositories it
would need a recorded "ported up to `<sha>`" pointer, kept by hand, plus both
clones present to resolve it — which is the bookkeeping the manifest exists to
remove. Splitting is worth revisiting if the Windows build stops tracking the Mac
app and becomes its own product, or if someone else takes ownership of it.

`windows/node_modules` and `windows/dist` are ignored, so the port adds about
twenty source files to the repository.
