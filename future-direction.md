# marc Future Direction

The strongest future features are the ones that reduce the cognitive cost of
reading machine-generated material rather than merely adding more editor chrome.

## Near-term: make AI output digestible

### Reading lenses

Offer one-click views such as **Summary**, **Decisions**, **Action items**,
**Questions**, **Code changes**, and **Risks**. Start with deterministic heading,
list, checkbox, and callout extraction; optional model-assisted lenses can come
later and should always show their source passages.

### Persistent reading progress

Build on the current block-level unread tracking by remembering precise scroll
position and adding a subtle whole-document progress rail and "resume reading"
action.

### Document outline minimap

Show document density, heading boundaries, code blocks, tasks, and search hits in
a compact vertical map. This would make a 2,000-line agent report feel spatially
understandable before reading it.

### Better change awareness

Build on the current updated-passage markers with a richer semantic diff that
classifies changed conclusions, completed tasks, and removed warnings while
preserving the reader's exact position.

### Focus and skim modes

- Focus mode dims everything outside the current section.
- Skim mode shows headings, first sentences, emphasized text, and list leaders.
- Presentation mode turns a document outline into keyboard-navigable cards.

## Medium-term: turn files into a working knowledge space

### Backlinks and richer graph navigation

Index an opted-in folder to show incoming references, orphan files, clusters,
and two-hop neighbors. Keep indexing local and make ignored directories explicit.

### Agent-run timeline

Recognize related plans, logs, reports, and result files as one run. Present them
chronologically with status, elapsed time, touched files, and final outputs,
instead of making the user reconstruct the story from several documents.

### Structured task extraction

Aggregate Markdown checkboxes, owners, deadlines, and blockers across open files.
Let users jump to the source, but never move task truth into a proprietary store.

### Source-aware comments and annotations

Allow private highlights, notes, bookmarks, and "ask later" markers anchored to
headings or source ranges. Store them in sidecar metadata and gracefully recover
anchors after agent edits.

### Workspace sessions

Save a named set of tabs, layout, active theme, search, graph scope, and reading
positions. Useful sessions might be "current incident", "project planning", or
"agent handoff".

### Markdown relationship types

Distinguish ordinary links from dependencies, evidence, generated artifacts,
superseded documents, and follow-ups using lightweight optional syntax. Render
these relationship types differently in the graph.

## Longer-term: careful intelligence

### On-demand attention analysis

The current beta uses an approved local embeddings model only after the user
clicks **Analyze Attention** to suggest a small number of urgent, important, or
review-worthy source passages. It never runs on open, scroll, edit, or external
updates. Future work is limited to evaluation and profile calibration. See
[ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md](ON-DEMAND-ATTENTION-ANALYSIS-SPEC.md).

### Local or enterprise-approved document assistant

Provide question answering, summaries, and comparisons across selected files,
with line-level citations and a visible context boundary. Never upload documents
without an explicit, approved provider configuration.

### Reader-controlled rewriting

Generate temporary views such as "explain simply", "remove repetition", or
"convert to executive brief" while preserving the original file and allowing
every sentence to link back to its source.

### Claim and evidence inspection

Identify claims, decisions, assumptions, and cited evidence. Flag conclusions
that have no nearby support and references that no longer resolve.

### Human handoff generator

Turn a collection of agent documents into a concise handoff containing what
changed, decisions made, unresolved questions, verification performed, and the
exact files to inspect next.

## Platform and editor improvements

- Full GitHub Flavored Markdown tables, footnotes, task lists, and diagrams
- Command palette and customizable key bindings
- Multiple windows and detachable tabs
- Print/PDF export using the active document theme
- Theme sharing as inert JSON, with import review and no executable plugins
- Quick Look extension for themed Markdown previews
- Finder thumbnails based on title and theme
- Spotlight metadata importer for headings and tasks
- Safe image paste with relative asset management
- Git status, blame, history, and side-by-side version comparison
- Accessibility controls for contrast, motion, font scaling, and reading rulers
- Optional iCloud document access while keeping the metadata model local-first

## Principles to preserve

1. The Markdown file remains the source of truth.
2. Reading is the primary workflow; editing supports it.
3. Intelligence is optional, cited, and reversible.
4. External agent edits are expected, not exceptional.
5. No document content leaves the Mac without explicit user action.
6. Extensions must be reviewed and non-executable by default.
