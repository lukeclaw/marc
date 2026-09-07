# marc HTML Support Specification

## Why HTML belongs in marc

Agents produce HTML when a point needs interactivity that Markdown cannot
carry: a chart you can hover, a table you can sort, a simulation you can run, a
layout that only makes sense rendered. Those files land in the same folders as
the plans and reports beside them, and they are part of the same piece of work.

An HTML file opened in a browser leaves marc's model behind. There are no tabs
alongside the related Markdown, no outline, no memory of what you have already
read, no link graph, and no notice when the agent rewrites the file.

## What first-class means here

marc's features do not actually depend on Markdown. They depend on six things a
document can supply:

1. an outline
2. block identities with change signatures
3. outgoing references
4. a scroll-to target
5. a presentation surface
6. external-change detection

A web view can supply all six. HTML is therefore not a viewer bolted to the side
of the app: it is a second document format that participates in everything marc
already does. Anything short of that would be the afterthought this design
exists to avoid.

## Non-goals

- Editing HTML as rich text or through a visual designer
- Re-rendering HTML through marc's own layout engine
- Applying marc's per-file color themes to a page that has its own design
- Running a page as a general-purpose browser tab
- Fetching anything from the network without the reader saying so

## Structure

`HTMLParser` reads the file's source, not its rendered DOM, and produces the
same shapes the Markdown parser produces:

- **Headings** from `h1`–`h6`, with slug identifiers, nested by level. This is
  the outline, unchanged from Markdown's.
- **Blocks** for structural elements — paragraphs, preformatted text, block
  quotes, tables, lists, figures, media, canvases, frames, and forms. Nested
  structural elements belong to the outermost block rather than forming blocks
  of their own. Each block records the heading it sits under.
- **References** for relative `href` values that point at a `.md` or `.html`
  file, resolved against the document's folder. These are graph edges, so a plan
  in Markdown and a demo in HTML appear in one graph.
- **External resources**, meaning the absolute `http` and `https` URLs the page
  asks for. They are what the reader is asked about before the page is allowed
  to reach the network.

Block identity is content-derived, exactly as in Markdown: a block's identifier
comes from a hash of its text, so it survives insertions elsewhere in the file
and changes when the block itself is edited. `ReadingAlignment` therefore works
on HTML with no additional machinery — an edited HTML paragraph is recognized as
a revision of the paragraph it replaced, and marc can tell a revision from
genuinely new content.

Blocks are numbered in document order. That number is the bridge to the rendered
page: the reader script walks the live DOM for the same elements in the same
order, so a position reported for element 7 belongs to block 7. The page is
never rewritten to carry marc's identifiers.

## Document shape

Reading progress over a dashboard is noise. `HTMLParser` therefore classifies
each page:

- **Document** — real headings and real prose. Outline, unread and updated
  marks, reading progress, and the status strip all apply.
- **App** — heavy scripting or many interactive elements with little prose.
  Reading progress is switched off rather than shown as permanently unread.

The classification is stated in the document bar and can be overridden per file.
It is never silent.

## Rendering and safety

An agent's HTML is arbitrary code, and marc's standing principle is that no
document content leaves the Mac without an explicit action. The web view is
configured accordingly:

- The file is loaded with `loadFileURL(_:allowingReadAccessTo:)` scoped to its
  own folder, so a page can pull in its sibling stylesheet or image and nothing
  else on the disk.
- The data store is non-persistent, so cookies and storage do not outlive the
  tab.
- Every `http` and `https` load is blocked by a content rule list. When a page
  asks for external resources, the document bar says how many and offers to
  allow them for that file. The choice is remembered per file, in the same
  per-file preferences as the theme.
- The page's own scripts run. A local chart or demo is not worth opening
  without them, and with the network blocked and file access confined to the
  page's folder there is nowhere for a script to send anything. Scripts can be
  turned off per file.
- Navigation away from the file is refused. Activating a link to a local `.md`
  or `.html` file opens it as a marc tab; an external link goes to the default
  browser only after a confirmation. Pop-ups open nothing.

Colors and fonts are deliberately left alone: overriding the design of a page
that was built to look a particular way would defeat the reason it is HTML.
Text sizing still works, applied as page zoom.

## Editing

Source mode is the existing plain-text editor with the existing syntax
highlighter, which already covers HTML, CSS, and JavaScript. Split mode puts the
source beside the live page, which is the natural way to iterate on a page an
agent produced. Saving reloads the view.

External-change detection is unchanged and is more valuable here than in
Markdown: when an agent rewrites the file, the rendered page refreshes.

## Registration

`Info.plist` declares HTML as an Editor with `LSHandlerRank: Alternate`. marc
appears under **Open With** for HTML files and can be chosen deliberately, but
does not take `.html` from the browser the way it takes `.md`, which it owns.

## Open work

- Attention analysis reads Markdown block text and is offered only for Markdown
  documents until it understands HTML structure.
- The reader script infers structure from the live DOM. A page that builds its
  content entirely in JavaScript will have a DOM the source parser did not see,
  so its outline and reading marks will be incomplete.
- A reading theme that restyles a plain, unstyled page, without touching one
  that has a design of its own.
