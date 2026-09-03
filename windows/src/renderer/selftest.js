/*
 * marc — renderer self test.
 *
 * src/checks/checks.js covers the parser and the attention scorer as pure
 * functions, exactly as Sources/MarcChecks/main.swift does. This suite covers
 * everything that only exists once the app is running: the real DOM, the real
 * DocumentStore, real files on disk, and the real preload bridge. It is the
 * Windows stand-in for the manual passes the macOS build gets in Xcode.
 *
 * Run it with `npm run selftest`. The main process points this window at a
 * throwaway profile and scratch directory, so nothing here can touch the
 * user's settings, preferences, session, or documents.
 */
"use strict";

const MarcSelfTest = (() => {
  const ATTENTION_TIMEOUT = 30000;

  class SelfTestFailure extends Error {}

  let app = null;
  let scratch = null;
  let counter = 0;

  /* ----------------------------------------------------------- assertions */

  function assert(condition, message) {
    if (!condition) throw new SelfTestFailure(message);
  }

  function equal(left, right) {
    return JSON.stringify(left) === JSON.stringify(right);
  }

  /* -------------------------------------------------------------- helpers */

  /*
   * Renders are queued on an animation frame. A hidden window may not produce
   * frames, so the suite drains the queue itself rather than waiting for one.
   */
  function flush() {
    app.flushRender();
  }

  function wait(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  }

  async function until(description, condition, timeout) {
    const deadline = Date.now() + timeout;
    while (Date.now() < deadline) {
      if (condition()) return;
      await wait(20);
    }
    throw new SelfTestFailure(`Timed out waiting for ${description}`);
  }

  async function scratchFile(name, lines) {
    counter += 1;
    const filePath = window.marc.path.join(scratch, `${counter}-${name}`);
    const result = await window.marc.writeFile(filePath, lines.join("\n"));
    assert(result.ok, `Could not create the scratch file ${name}: ${result.error}`);
    return filePath;
  }

  async function openScratch(name, lines) {
    const filePath = await scratchFile(name, lines);
    const document_ = await app.store.open(filePath);
    assert(document_ !== null, `Opening ${name} returned no document`);
    flush();
    return document_;
  }

  function sampleDocument(title) {
    return [
      `# ${title}`,
      "",
      "An opening paragraph that introduces the document.",
      "",
      "## Findings",
      "",
      "- First finding",
      "- Second finding",
      "",
      "| Column | Value |",
      "| --- | --- |",
      "| One | 1 |",
      "",
      "```js",
      "const answer = 42;",
      "```",
      "",
      "> A quoted remark.",
      "",
      "### Next Steps",
      "",
      "Close out the remaining work.",
      ""
    ];
  }

  /*
   * Between checks the workspace is torn down directly rather than through
   * store.close(), which would open a native "save changes?" dialog for dirty
   * documents and block the run.
   */
  async function reset() {
    const store = app.store;
    for (const timer of store.autosaveTimers.values()) clearTimeout(timer);
    store.autosaveTimers.clear();
    for (const document_ of store.documents) document_.cancelAttentionAnalysis();

    store.documents = [];
    store.selectedID = null;
    store.errorMessage = null;
    store.groups = [];
    store.groupAssignments = {};
    store.preferencesByPath = {};
    store.referenceExistence.clear();
    store.settings = { ...MarcModels.DEFAULT_SETTINGS };

    app.showGraph = false;
    app.showAttention = false;
    app.showFind = false;
    app.layoutKey = null;
    app.renderAll();
    flush();
  }

  /* --------------------------------------------------------------- checks */

  async function checkRendersDocument() {
    const document_ = await openScratch("render.md", sampleDocument("Rendered Document"));

    const nodes = document.querySelectorAll(".preview .block");
    assert(
      nodes.length === document_.parsed.blocks.length,
      `Rendered ${nodes.length} block elements for ${document_.parsed.blocks.length} parsed blocks`
    );

    const rendered = document.querySelector(".preview");
    assert(rendered.querySelector(".block.h1 .md-heading .title") !== null, "No level 1 heading rendered");
    assert(rendered.querySelector(".md-paragraph") !== null, "No paragraph rendered");
    assert(rendered.querySelectorAll(".md-list .md-list-item").length === 2, "List items were not rendered");
    assert(rendered.querySelector(".md-table-scroll table") !== null, "No table rendered");
    assert(rendered.querySelector(".md-code code").textContent.includes("42"), "Code block content is missing");
    assert(rendered.querySelector(".md-quote .text") !== null, "No blockquote rendered");

    // Every trackable block carries a gutter, and all of them start unread.
    assert(
      rendered.querySelectorAll(".gutter .unread").length === document_.unreadCount,
      "Unread gutter markers do not match the unread count"
    );
  }

  /*
   * Structure assertions pass happily against a broken stylesheet, so this
   * checks the geometry too: the chrome and the reading surface must actually
   * fill the window. A dropped rule shows up here and nowhere else.
   */
  async function checkWorkspaceLayout() {
    await openScratch("layout.md", sampleDocument("Layout"));

    const strip = document.getElementById("tabstrip").getBoundingClientRect();
    assert(strip.height > 40, `The tab strip collapsed to ${strip.height}px`);

    const preview = document.querySelector(".preview").getBoundingClientRect();
    assert(preview.width > 200, `The reading surface is only ${preview.width}px wide`);
    assert(preview.height > 200, `The reading surface is only ${preview.height}px tall`);
    assert(
      window.innerHeight - preview.bottom < 4,
      `The reading surface stops ${Math.round(window.innerHeight - preview.bottom)}px above the window bottom`
    );

    const toc = document.querySelector('[data-panel="toc"] .sidebar.toc').getBoundingClientRect();
    assert(
      window.innerHeight - toc.bottom < 4,
      `The outline stops ${Math.round(window.innerHeight - toc.bottom)}px above the window bottom`
    );
    assert(toc.width > 100, `The outline is only ${toc.width}px wide`);

    // Nothing may overflow horizontally into a second scroll axis.
    assert(
      document.documentElement.scrollWidth <= window.innerWidth,
      "The window scrolls horizontally"
    );
  }

  async function checkViewModes() {
    await openScratch("modes.md", sampleDocument("View Modes"));

    app.setMode("source");
    flush();
    assert(document.querySelector(".source-editor textarea") !== null, "Source mode has no editor");
    assert(document.querySelector(".preview") === null, "Source mode still shows the rendered view");

    app.setMode("split");
    flush();
    assert(document.querySelector(".split .source-editor") !== null, "Split mode has no editor");
    assert(document.querySelector(".split .preview") !== null, "Split mode has no rendered view");
    assert(document.querySelector(".split-handle") !== null, "Split mode has no drag handle");

    app.setMode("rendered");
    flush();
    assert(document.querySelector(".preview") !== null, "Rendered mode has no rendered view");
    assert(document.querySelector("textarea") === null, "Rendered mode still shows an editor");
  }

  async function checkHeadingCollapse() {
    // Two sibling sections, so the test can tell "hid the subtree" apart from
    // "hid everything after the heading".
    const document_ = await openScratch("collapse.md", [
      "# Collapsing",
      "",
      "The introduction stays visible.",
      "",
      "## First Section",
      "",
      "A paragraph inside the first section.",
      "",
      "### Nested Detail",
      "",
      "A nested paragraph that collapses with its parent.",
      "",
      "## Second Section",
      "",
      "A paragraph inside the second section.",
      ""
    ]);
    const before = document.querySelectorAll(".preview .block").length;

    document_.preferences.collapsedHeadingIDs.push("first-section");
    app.previewView.render();

    const after = document.querySelectorAll(".preview .block").length;
    assert(after === before - 3, `Collapsing hid ${before - after} blocks, expected the 3 below the heading`);
    assert(
      document.querySelector(".block.h2 .md-heading .collapse-pill") !== null,
      "A collapsed heading shows no collapsed indicator"
    );

    const titles = [...document.querySelectorAll(".md-heading .title")].map((node) => node.textContent);
    assert(titles.includes("First Section"), "The collapsed heading itself disappeared");
    assert(!titles.includes("Nested Detail"), "A nested heading survived its parent collapsing");
    assert(titles.includes("Second Section"), "Collapsing a section also hid the sibling section");

    document_.preferences.collapsedHeadingIDs.length = 0;
    app.previewView.render();
    assert(
      document.querySelectorAll(".preview .block").length === before,
      "Expanding a section did not restore its blocks"
    );
  }

  async function checkSyntaxHighlighting() {
    const document_ = await openScratch("highlight.md", [
      "# Highlighting",
      "",
      "```swift",
      "// load the member",
      "let member: Member = fetchMember(id: 42)",
      "```",
      "",
      "```",
      "def calculate_total(items):",
      "    return sum(items)",
      "```",
      ""
    ]);

    const blocks = document.querySelectorAll(".preview .md-code");
    assert(blocks.length === 2, `Expected 2 code blocks, found ${blocks.length}`);

    const [labelled, unlabelled] = blocks;
    assert(labelled.querySelector(".language").textContent === "SWIFT", "The language label is wrong");
    assert(
      unlabelled.querySelector(".language").textContent === "PYTHON",
      "An unlabelled block did not get its inferred language label"
    );

    assert(labelled.querySelector(".tok-keyword").textContent === "let", "No keyword token rendered");
    assert(labelled.querySelector(".tok-type").textContent === "Member", "No type token rendered");
    assert(
      labelled.querySelector(".tok-function").textContent === "fetchMember",
      "No function token rendered"
    );
    assert(labelled.querySelector(".tok-number").textContent === "42", "No number token rendered");
    assert(
      labelled.querySelector(".tok-comment").textContent === "// load the member",
      "No comment token rendered"
    );

    // The rendered text must still be the source, exactly, tokens and all.
    const source = document_.parsed.blocks.find((block) => block.kind.type === "code").kind.content;
    assert(
      labelled.querySelector("pre code").textContent === source,
      "Highlighting altered the code block's text"
    );

    // Highlighting must never execute or inject markup from the document.
    const hostile = await openScratch("hostile.md", [
      "# Hostile",
      "",
      "```html",
      '<img src=x onerror="globalThis.__marcSelfTestEscaped = true">',
      "```",
      ""
    ]);
    assert(hostile !== null, "The hostile fixture did not open");
    assert(
      document.querySelector(".preview .md-code img") === null,
      "A code block rendered document markup as live HTML"
    );
    assert(
      globalThis.__marcSelfTestEscaped === undefined,
      "A code block executed script from the document"
    );

    const copy = document.querySelector(".preview .md-code .code-copy");
    assert(copy !== null, "A code block has no copy control");
    copy.click();
    assert(copy.classList.contains("copied"), "The copy control gave no feedback");
  }

  async function checkTableOfContents() {
    const document_ = await openScratch("toc.md", sampleDocument("Outline"));

    // The outline is part of the default layout rather than opt-in.
    assert(app.showTOC, "The table of contents should be visible by default");
    const panel = document.querySelector('[data-panel="toc"] .sidebar.toc');
    assert(panel !== null, "The table of contents panel did not appear");

    const labels = [...panel.querySelectorAll(".outline-row .label")].map((node) => node.textContent);
    assert(
      equal(labels, document_.parsed.headings.map((heading) => heading.title)),
      `Outline rows ${JSON.stringify(labels)} do not match the parsed headings`
    );

    const order = () => {
      const children = [...document.getElementById("workspace").children];
      return {
        toc: children.findIndex((node) => node.dataset.panel === "toc"),
        column: children.findIndex((node) => node.dataset.role === "document-column")
      };
    };
    assert(order().toc < order().column, "The outline should start on the left");
    app.setTOCPosition("right");
    flush();
    assert(order().toc > order().column, "Moving the outline to the right had no effect");

    app.toggleTOC();
    flush();
    assert(document.querySelector('[data-panel="toc"]') === null, "The table of contents did not close");

    app.toggleTOC();
    flush();
    assert(document.querySelector('[data-panel="toc"]') !== null, "The table of contents did not reopen");
  }

  async function checkNewDocument() {
    const target = window.marc.path.join(scratch, "created-by-self-test.md");

    // newDocument() goes through a native save panel, so drive the step below
    // it, which is what the panel's result calls.
    const created = await app.store.createDocument(target, null);
    assert(created !== null, "Creating a document returned nothing");
    assert(created.path === target, "The created document has the wrong path");

    const onDisk = await window.marc.readFile(target);
    assert(onDisk.ok, "The new file was not written to disk");
    assert(
      onDisk.content === "# created-by-self-test\n\n",
      `A new file should start with its title heading, got ${JSON.stringify(onDisk.content)}`
    );
    assert(app.store.selectedID === created.id, "The new document was not selected");

    // An extension is added when the chosen name has none.
    const bare = window.marc.path.join(scratch, "no-extension");
    const withExtension = await app.store.createDocument(bare, null);
    assert(withExtension.path === `${bare}.md`, "A missing .md extension was not added");

    // Creating over an existing file must open it, never blank it.
    await window.marc.writeFile(target, "# Existing\n\nKeep me.\n");
    app.store.documents = [];
    app.store.selectedID = null;
    const reopened = await app.store.createDocument(target, null);
    assert(reopened.content.includes("Keep me."), "Creating over an existing file overwrote it");
  }

  async function checkNewDocumentJoinsGroup() {
    const seed = await openScratch("group-seed.md", sampleDocument("Seed"));
    const group = app.store.createGroup("Created", false, seed);
    const target = window.marc.path.join(scratch, "created-in-group.md");

    const created = await app.store.createDocument(target, group.id);
    assert(created !== null, "Creating a document in a group returned nothing");
    assert(
      app.store.groupFor(created)?.id === group.id,
      "A file created in a group was not assigned to it"
    );
  }

  async function checkMissingLinkOffersCreation() {
    const missing = window.marc.path.join(scratch, "not-written-yet.md");
    const document_ = await openScratch("linking.md", [
      "# Linking",
      "",
      "See [the follow-up](not-written-yet.md).",
      ""
    ]);

    const reference = document_.parsed.references[0];
    assert(reference !== undefined, "The link was not parsed as a reference");
    assert(reference.resolvedPath === missing, "The link resolved to the wrong path");

    // openLink offers to create; the self test answers the dialog by calling
    // the same path the "Create File" button does.
    await app.store.createFileForReference(reference, document_);
    const existence = await window.marc.exists([missing]);
    assert(existence[missing] === true, "Creating from a missing link did not write the file");
    assert(
      app.store.selectedDocument.path === missing,
      "Creating from a missing link did not open the new file"
    );

    // Now that it exists, following the link opens it rather than offering.
    await app.store.openLink(missing, document_);
    assert(app.store.selectedDocument.path === missing, "Following an existing link failed");
  }

  async function checkProportionalTabs() {
    const wide = app.tabStripMetrics(1200);
    const narrow = app.tabStripMetrics(400);
    assert(wide.tabWidth === 220, `An empty strip should offer the maximum tab width, got ${wide.tabWidth}`);

    for (let index = 0; index < 6; index += 1) {
      await openScratch(`lane-${index}.md`, sampleDocument(`Lane ${index}`));
    }
    flush();

    const roomy = app.tabStripMetrics(1600);
    const tight = app.tabStripMetrics(560);
    assert(roomy.tabWidth > tight.tabWidth, "Tabs did not shrink as the window narrowed");
    assert(roomy.tabWidth <= 220, "A tab grew past the maximum width");
    assert(tight.tabWidth >= 72, "A tab shrank below the minimum readable width");
    assert(!roomy.requiresScrolling, "A roomy strip should not need scrolling");

    const cramped = app.tabStripMetrics(200);
    assert(cramped.tabWidth === 72, "A cramped strip should pin tabs to the minimum width");
    assert(cramped.requiresScrolling, "A cramped strip should scroll");

    // Every tab in a lane shares one width, and the lane is their total.
    const laneOfThree = roomy.laneWidth(3, false);
    assert(
      Math.abs(laneOfThree - (3 * roomy.tabWidth + 2 * 2)) < 0.001,
      "The lane width does not match its tabs plus spacing"
    );
    assert(roomy.laneWidth(4, true) === 124, "A collapsed lane should use the fixed collapsed width");

    const tabs = document.querySelectorAll("#tabstrip .tab");
    assert(tabs.length === 6, `Expected 6 tabs, found ${tabs.length}`);
    const widths = new Set([...tabs].map((tab) => tab.style.width));
    assert(widths.size === 1, "Tabs in the strip were laid out at differing widths");

    const header = document.querySelector("#tabstrip .tab-section.ungrouped .lane-header .lane-name");
    assert(header !== null, "The ungrouped lane has no title");
    assert(header.textContent === "Ungrouped", "The ungrouped lane title is wrong");
  }

  async function checkGroupLaneTitles() {
    const first = await openScratch("titled-one.md", sampleDocument("Titled One"));
    const group = app.store.createGroup("Release Plan", false, first);
    flush();

    const section = document.querySelector("#tabstrip .tab-section");
    assert(section !== null, "No group lane rendered");
    assert(
      section.querySelector(".lane-header .lane-name").textContent === "Release Plan",
      "The group lane does not show its name as a title"
    );
    assert(section.querySelector(".lane-accent") !== null, "The group lane has no colour accent");
    assert(section.querySelector(".lane-tabs .tab") !== null, "The group lane shows no tabs");

    app.store.toggleGroup(group.id);
    flush();
    assert(
      document.querySelector("#tabstrip .tab-section .lane-tabs") === null,
      "Collapsing a lane did not hide its tab row"
    );
    assert(
      document.querySelector("#tabstrip .tab-section .lane-header .lane-name").textContent ===
        "Release Plan",
      "A collapsed lane lost its title"
    );
  }

  async function checkTabsAndSelection() {
    const first = await openScratch("tab-one.md", sampleDocument("First"));
    const second = await openScratch("tab-two.md", sampleDocument("Second"));

    const tabs = document.querySelectorAll("#tabstrip .tab");
    assert(tabs.length === 2, `Expected 2 tabs, found ${tabs.length}`);
    assert(app.store.selectedID === second.id, "Opening a file did not select it");

    app.selectDocument(first);
    flush();
    const selected = document.querySelectorAll("#tabstrip .tab.selected");
    assert(selected.length === 1, "Exactly one tab should be selected");
    assert(selected[0].textContent.includes(first.displayName), "The wrong tab is selected");

    // Re-opening an already open path selects the existing tab, never a second.
    await app.store.open(second.path);
    flush();
    assert(document.querySelectorAll("#tabstrip .tab").length === 2, "Re-opening a file duplicated its tab");
    assert(app.store.selectedID === second.id, "Re-opening a file did not select its tab");
  }

  async function checkEditSaveAndDirtyState() {
    const document_ = await openScratch("edit.md", sampleDocument("Editing"));
    app.setMode("source");
    flush();

    const textarea = document.querySelector(".source-editor textarea");
    assert(textarea.value === document_.content, "The editor did not load the document content");

    textarea.value = `${document_.content}\nA sentence typed by the self test.\n`;
    textarea.dispatchEvent(new Event("input"));
    flush();

    assert(document_.isDirty, "Typing did not mark the document dirty");
    assert(document.querySelector("#tabstrip .tab .dirty-dot") !== null, "No unsaved-changes dot on the tab");

    const saved = await app.store.save(document_);
    assert(saved, "Saving the document failed");
    assert(!document_.isDirty, "The document is still dirty after saving");

    const onDisk = await window.marc.readFile(document_.path);
    assert(onDisk.ok, "Could not read the saved file back");
    assert(onDisk.content === document_.content, "The file on disk does not match the editor buffer");

    flush();
    assert(document.querySelector("#tabstrip .tab .dirty-dot") === null, "The unsaved-changes dot survived the save");

    // The reader wrote this edit, so its blocks must not come back as unread.
    assert(document_.changedCount === 0, "A local save produced externally-changed passages");
  }

  async function checkAutosave() {
    const document_ = await openScratch("autosave.md", sampleDocument("Autosave"));
    app.store.updateContent(document_, `${document_.content}\nAutosaved line.\n`);
    assert(document_.isDirty, "The document should be dirty before the autosave fires");

    await until("the autosave to write", () => !document_.isDirty, 5000);

    const onDisk = await window.marc.readFile(document_.path);
    assert(onDisk.content.includes("Autosaved line."), "The autosave did not reach disk");
  }

  async function checkExternalReload() {
    const document_ = await openScratch("external.md", sampleDocument("External"));
    const originalUnread = document_.unreadCount;
    document_.markAllRead();
    assert(document_.unreadCount === 0, "Mark all read left unread passages");

    // Wait past the filesystem timestamp granularity so the change is visible.
    await wait(20);
    const rewritten = [...sampleDocument("External")];
    rewritten[2] = "An opening paragraph that an agent rewrote while marc was open.";
    await window.marc.writeFile(document_.path, rewritten.join("\n"));

    await app.store.checkExternalChanges();
    flush();

    assert(
      document_.content.includes("an agent rewrote"),
      "An external edit to a clean document was not picked up"
    );
    assert(document_.changedCount === 1, `Expected 1 changed passage, found ${document_.changedCount}`);
    assert(originalUnread > 0, "The fixture should start with unread passages");
    assert(
      document.querySelector(".preview .gutter .changed") !== null,
      "No changed marker in the rendered gutter"
    );
    assert(document.querySelector(".reading-status") !== null, "No reading status bar for changed passages");
  }

  async function checkExternalConflict() {
    const document_ = await openScratch("conflict.md", sampleDocument("Conflict"));
    const local = `${document_.content}\nA local edit that must not be lost.\n`;
    document_.content = local;

    await wait(20);
    await window.marc.writeFile(document_.path, sampleDocument("Conflict Rewritten").join("\n"));

    await app.store.checkExternalChanges();
    flush();

    assert(document_.externalConflict, "A conflicting external edit raised no conflict");
    assert(document_.content === local, "The conflicting external edit overwrote unsaved local changes");
    const banner = document.querySelector(".banner.conflict");
    assert(banner !== null, "No conflict banner is shown");
    assert(banner.textContent.includes("Reload from Disk"), "The conflict banner offers no reload");
    assert(banner.textContent.includes("Keep Mine"), "The conflict banner offers no way to keep local edits");

    // Saving over a conflict is refused until the reader resolves it.
    const saved = await app.store.save(document_);
    assert(!saved, "A plain save silently overwrote the conflicting file");

    await app.store.overwriteWithLocalVersion(document_);
    const onDisk = await window.marc.readFile(document_.path);
    assert(onDisk.content === local, "Keeping the local version did not write it to disk");
    assert(!document_.externalConflict, "The conflict survived an explicit resolution");
  }

  async function checkReadingStatePersists() {
    const document_ = await openScratch("reading.md", sampleDocument("Reading State"));
    const path = document_.path;
    const trackable = document_.trackableBlocks(document_.parsed).length;

    document_.markSectionRead("findings");
    app.store.savePreferences(document_);
    const readAfterSection = document_.unreadCount;
    assert(readAfterSection > 0, "Marking one section read should not clear the whole document");
    assert(readAfterSection < trackable, "Marking a section read had no effect");

    await app.store.flush();
    app.store.documents = [];
    app.store.selectedID = null;

    const reopened = await app.store.open(path);
    flush();
    assert(
      reopened.unreadCount === readAfterSection,
      `Reading state did not survive reopening: ${reopened.unreadCount} unread, expected ${readAfterSection}`
    );
  }

  async function checkPreferencesPersist() {
    const document_ = await openScratch("prefs.md", sampleDocument("Preferences"));
    const path = document_.path;

    document_.preferences.theme = MarcModels.themePreset("midnight");
    app.store.adjustSelectedFontSize(3);
    const expectedSize = document_.preferences.theme.bodySize;
    document_.preferences.collapsedHeadingIDs.push("findings");
    app.store.savePreferences(document_);

    await app.store.flush();
    app.store.documents = [];
    app.store.selectedID = null;

    const reopened = await app.store.open(path);
    flush();
    assert(reopened.preferences.theme.bodySize === expectedSize, "The per-file text size did not persist");
    assert(
      equal(reopened.preferences.collapsedHeadingIDs, ["findings"]),
      "Collapsed sections did not persist"
    );
    assert(
      reopened.preferences.theme.background.hex === MarcModels.themePreset("midnight").background.hex,
      "The per-file theme did not persist"
    );

    // The theme must live outside the document: the Markdown is untouched.
    const onDisk = await window.marc.readFile(path);
    assert(
      onDisk.content === sampleDocument("Preferences").join("\n"),
      "Setting a theme modified the Markdown file"
    );
  }

  async function checkProjectGroups() {
    const first = await openScratch("group-one.md", sampleDocument("Group One"));
    const second = await openScratch("group-two.md", sampleDocument("Group Two"));

    const group = app.store.createGroup("Self Test", false, first);
    flush();
    assert(group !== null && group !== undefined, "Creating a project group returned nothing");
    assert(
      equal(app.store.groupDocuments(group.id).map((item) => item.id), [first.id]),
      "The new group does not contain the document it was created from"
    );
    assert(
      equal(app.store.groupDocuments(null).map((item) => item.id), [second.id]),
      "The second document should still be ungrouped"
    );

    const header = document.querySelector("#tabstrip .tab-section .lane-header");
    assert(header !== null, "No group header in the tab strip");
    assert(header.textContent.includes("Self Test"), "The group header shows the wrong name");
    assert(
      document.querySelector("#tabstrip .tab-section.ungrouped") !== null,
      "No ungrouped section in the tab strip"
    );

    app.store.assign(second, group.id);
    flush();
    assert(app.store.groupDocuments(group.id).length === 2, "Assigning a document to a group had no effect");

    app.store.toggleGroup(group.id);
    flush();
    assert(
      document.querySelectorAll("#tabstrip .tab-section .tab").length === 0,
      "Collapsing a group did not hide its tabs"
    );

    // The grouping store is what a restart reads back.
    const stored = await window.marc.readStore("workspace-groups.json", null);
    assert(stored !== null, "The grouping store was never written");
    assert(
      stored.groups.some((candidate) => candidate.name === "Self Test"),
      "The group was not persisted"
    );
    assert(
      Object.values(stored.assignments).filter((id) => id === group.id).length === 2,
      "Group assignments were not persisted"
    );
  }

  async function checkSessionRestore() {
    const first = await openScratch("session-one.md", sampleDocument("Session One"));
    const second = await openScratch("session-two.md", sampleDocument("Session Two"));
    app.selectDocument(first);

    await app.store.flush();
    const stored = await window.marc.readStore("workspace-session.json", null);
    assert(stored !== null, "The session store was never written");
    assert(
      equal(stored.openPaths, [first.path, second.path]),
      "The session did not record the open tabs in order"
    );
    assert(stored.selectedPath === first.path, "The session did not record the selected tab");

    app.store.documents = [];
    app.store.selectedID = null;
    await app.store.restoreSession();
    flush();

    assert(
      equal(app.store.documents.map((item) => item.path), [first.path, second.path]),
      "Restoring the session reopened the wrong tabs"
    );
    assert(app.store.selectedDocument.path === first.path, "Restoring the session selected the wrong tab");
    assert(document.querySelectorAll("#tabstrip .tab").length === 2, "The restored tabs are not in the tab strip");
  }

  async function checkMissingFilesAreSkipped() {
    const present = await scratchFile("present.md", sampleDocument("Present"));
    const missing = window.marc.path.join(scratch, "deleted-by-someone-else.md");
    await window.marc.writeStore("workspace-session.json", {
      openPaths: [missing, present],
      selectedPath: missing
    });

    await app.store.restoreSession();
    flush();
    assert(
      equal(app.store.documents.map((item) => item.path), [present]),
      "Restoring a session did not skip the file that no longer exists"
    );
  }

  async function checkFind() {
    const document_ = await openScratch("find.md", sampleDocument("Finding"));
    app.toggleFind(true);
    flush();

    const field = document.querySelector(".find-bar input");
    assert(field !== null, "The find bar has no input field");

    // Case-insensitive substring search: the title, the "Findings" heading,
    // and both list items match.
    document_.findText = "finding";
    const matches = app.findMatches(document_);
    assert(matches.length === 4, `Expected 4 matches for "finding", found ${matches.length}`);
    for (const offset of matches) {
      assert(
        document_.content.slice(offset, offset + 7).toLowerCase() === "finding",
        `Match offset ${offset} does not point at the search text`
      );
    }

    document_.findText = "no such text anywhere";
    assert(app.findMatches(document_).length === 0, "A search with no matches returned results");

    app.toggleFind(false);
    flush();
    assert(document.querySelector(".find-bar") === null, "The find bar did not close");
  }

  async function checkLinkedFileGraph() {
    const target = await scratchFile("linked-target.md", ["# Target", "", "The linked document.", ""]);
    const name = window.marc.path.basename(target);
    const document_ = await openScratch("linked-source.md", [
      "# Source",
      "",
      `A [real link](${name}) and a [broken link](does-not-exist.md).`,
      ""
    ]);

    assert(document_.parsed.references.length === 2, "Both Markdown links should be parsed as references");
    await app.store.refreshReferenceExistence(document_);
    app.toggleGraph(true);
    flush();

    const graph = document.querySelector('[data-panel="graph"] .sidebar.graph');
    assert(graph !== null, "The linked-file graph did not appear");
    assert(graph.querySelector(".graph-node.current") !== null, "The graph does not show the current document");
    assert(
      graph.querySelectorAll(".graph-node").length === 3,
      "The graph should show the current file and both links"
    );

    const resolved = document_.parsed.references.find((reference) => reference.destination === name);
    assert(app.store.referenceExists(resolved), "An existing linked file was reported as missing");
    await app.store.openReference(resolved);
    flush();
    assert(app.store.selectedDocument.path === target, "Following a Markdown link did not open the target file");
    assert(document.querySelectorAll("#tabstrip .tab").length === 2, "Following a link did not open a new tab");
  }

  async function checkRecentFiles() {
    const first = await openScratch("recent-one.md", sampleDocument("Recent One"));
    const second = await openScratch("recent-two.md", sampleDocument("Recent Two"));

    assert(
      equal(app.store.recentPaths.slice(0, 2), [second.path, first.path]),
      "Recent files are not in most-recent-first order"
    );

    app.store.recordRecent(first.path);
    assert(app.store.recentPaths[0] === first.path, "Re-opening a file did not move it to the top of recents");
    assert(
      app.store.recentPaths.filter((candidate) => candidate === first.path).length === 1,
      "A re-opened file appears twice in recents"
    );
  }

  async function checkAttentionAnalysis() {
    const document_ = await openScratch("attention.md", [
      "# Deployment Review",
      "",
      "The checkout service is down after last night release and customers cannot pay.",
      "We need an urgent rollback before the morning traffic peak.",
      "",
      "## Background",
      "",
      "The team migrated the payment client to a new HTTP library over the last two sprints.",
      "The migration was reviewed and merged without incident.",
      "",
      "## Decision",
      "",
      "We recommend adopting the new library everywhere and deleting the old client next quarter.",
      "That is a breaking change for three downstream services.",
      "",
      "## Notes",
      "",
      "The office coffee machine was also replaced this week.",
      "Lunch is at noon on Fridays.",
      ""
    ]);

    app.store.settings.attentionAnalysisAcknowledged = true;
    app.toggleAttention(true);
    flush();

    assert(MarcAttention.isAvailable(), "The bundled local embedding model reports itself unavailable");

    MarcAttentionUI.start(app.store, document_, true);
    assert(document_.attentionState === "running", "Starting the analysis did not enter the running state");
    flush();
    assert(
      document.querySelector('[data-panel="attention"] .progress-track') !== null,
      "No analysis progress shown"
    );

    await until("the attention analysis to finish", () => document_.attentionState === "ready", ATTENTION_TIMEOUT);
    flush();

    assert(document_.attentionResults.length > 0, "The analysis produced no suggestions");
    assert(document_.hasCurrentAttentionResults, "The finished results are not current for the document");
    assert(
      document_.attentionRevision === document_.currentAttentionRevision,
      "The results were stamped with the wrong document revision"
    );

    const categories = new Set(document_.attentionResults.map((result) => result.category));
    for (const category of categories) {
      assert(MarcAttention.categories.includes(category), `Unknown attention category ${category}`);
    }

    // Every suggestion must point at a block that is actually in the document.
    const blockIDs = new Set(document_.parsed.blocks.map((block) => block.id));
    for (const result of document_.attentionResults) {
      for (const blockID of result.blockIDs) {
        assert(blockIDs.has(blockID), `A suggestion referenced the unknown block ${blockID}`);
      }
    }

    const panel = document.querySelector('[data-panel="attention"]');
    assert(panel.querySelector(".sidebar-body") !== null, "The finished analysis rendered no results list");

    // The tab also carries an unread badge, so match on the attention colour.
    const badges = [...document.querySelectorAll("#tabstrip .tab .count-badge")];
    assert(
      badges.some((node) => node.style.color.includes("--attention")),
      "A finished analysis puts no suggestion badge on the tab"
    );

    // Editing the document must mark the results stale rather than silently
    // leaving suggestions pinned to passages that no longer exist.
    app.store.updateContent(document_, `${document_.content}\nA newly appended paragraph.\n`);
    assert(document_.attentionResultsAreStale, "Editing the document did not make the results stale");
    assert(!document_.hasCurrentAttentionResults, "Stale results are still reported as current");
  }

  async function checkAttentionCancellation() {
    const document_ = await openScratch("cancel.md", sampleDocument("Cancellation"));
    app.store.settings.attentionAnalysisAcknowledged = true;
    app.toggleAttention(true);

    MarcAttentionUI.start(app.store, document_, true);
    assert(document_.attentionState === "running", "The analysis did not start");

    MarcAttentionUI.cancel(app.store, document_);
    assert(document_.attentionState !== "running", "Cancelling left the analysis running");
    assert(document_.attentionRun === null, "Cancelling did not release the run token");

    const state = document_.attentionState;
    await wait(300);
    assert(document_.attentionState === state, "A cancelled analysis kept running in the background");
    assert(document_.attentionResults.length === 0, "A cancelled analysis still produced results");
  }

  async function checkMissingFileReportsError() {
    const missing = window.marc.path.join(scratch, "never-created.md");
    const opened = await app.store.open(missing);
    assert(opened === null, "Opening a missing file returned a document");
    assert(app.store.documents.length === 0, "A missing file was added to the workspace");
  }

  /* ----------------------------------------------------------------- main */

  async function run(application, scratchDirectory) {
    app = application;
    scratch = scratchDirectory;
    assert(typeof scratch === "string" && scratch.length > 0, "The self test received no scratch directory");

    // Drive external-change checks explicitly instead of racing the poll timer.
    if (app.store.pollTimer !== null) {
      clearInterval(app.store.pollTimer);
      app.store.pollTimer = null;
    }

    const checks = [
      ["renders a document", checkRendersDocument],
      ["workspace fills the window", checkWorkspaceLayout],
      ["rendered, split, and source modes", checkViewModes],
      ["collapsible heading sections", checkHeadingCollapse],
      ["syntax highlighted code blocks", checkSyntaxHighlighting],
      ["table of contents", checkTableOfContents],
      ["tabs and selection", checkTabsAndSelection],
      ["proportional tab lanes", checkProportionalTabs],
      ["group lane titles", checkGroupLaneTitles],
      ["new document creation", checkNewDocument],
      ["new document joins a group", checkNewDocumentJoinsGroup],
      ["a missing link offers creation", checkMissingLinkOffersCreation],
      ["edit, save, and dirty state", checkEditSaveAndDirtyState],
      ["autosave", checkAutosave],
      ["external change reload", checkExternalReload],
      ["external change conflict", checkExternalConflict],
      ["reading state persistence", checkReadingStatePersists],
      ["per-file preference persistence", checkPreferencesPersist],
      ["project groups", checkProjectGroups],
      ["session restore", checkSessionRestore],
      ["missing files are skipped", checkMissingFilesAreSkipped],
      ["find in document", checkFind],
      ["linked file graph", checkLinkedFileGraph],
      ["recent files", checkRecentFiles],
      ["attention analysis", checkAttentionAnalysis],
      ["attention cancellation", checkAttentionCancellation],
      ["a missing file reports an error", checkMissingFileReportsError]
    ];

    const lines = [];
    let failures = 0;

    for (const [name, check] of checks) {
      try {
        await reset();
        await check();
        lines.push(`  ok    ${name}`);
      } catch (error) {
        failures += 1;
        const detail = error instanceof SelfTestFailure ? error.message : `${error.stack ?? error}`;
        lines.push(`  FAIL  ${name}: ${detail}`);
      }
    }

    lines.push("");
    lines.push(
      failures > 0 ? `${failures} marc self test check(s) failed.` : "All marc self test checks passed."
    );

    window.marc.reportSelfTest({ text: lines.join("\n"), failures });
  }

  return { run };
})();
