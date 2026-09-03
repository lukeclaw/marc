#!/usr/bin/env node
/*
 * marc-checks — port of Sources/MarcChecks/main.swift.
 *
 * Verifies the structural parser, block identity/revision stability, and the
 * on-demand attention analyzer without launching the UI.
 */
"use strict";

const path = require("path");
const Parser = require("../core/parser.js");
const Attention = require("../core/attention.js");

class CheckFailure extends Error {}

function require_(condition, message) {
  if (!condition) throw new CheckFailure(message);
}

function equal(left, right) {
  return JSON.stringify(left) === JSON.stringify(right);
}

function checkHeadingsAndAncestors() {
  const parsed = Parser.parse(
    ["# Plan", "Intro", "## Steps", "- One", "- Two", "# Result", "Done"].join("\n")
  );

  require_(
    equal(parsed.headings.map((heading) => heading.title), ["Plan", "Steps", "Result"]),
    "Heading titles were not parsed"
  );
  require_(equal(parsed.blocks[1].ancestorHeadingIDs, ["plan"]), "Paragraph ancestor was incorrect");
  require_(equal(parsed.blocks[2].ancestorHeadingIDs, ["plan"]), "Nested heading ancestor was incorrect");
  require_(equal(parsed.blocks[3].ancestorHeadingIDs, ["plan", "steps"]), "List ancestors were incorrect");
  require_(
    equal(parsed.blocks[parsed.blocks.length - 1].ancestorHeadingIDs, ["result"]),
    "Final section ancestor was incorrect"
  );
}

function checkStableUniqueSlugs() {
  const parsed = Parser.parse("# Status\n## Status\n## Status");
  require_(
    equal(parsed.headings.map((heading) => heading.id), ["status", "status-2", "status-3"]),
    "Duplicate heading slugs were not unique"
  );
}

function checkCommonBlocks() {
  const parsed = Parser.parse(
    [
      "> A quote",
      "",
      "- [x] Finished",
      "- [ ] Pending",
      "",
      "1. First",
      "2. Second",
      "",
      "```swift",
      "let value = 1",
      "```"
    ].join("\n")
  );

  require_(parsed.blocks.some((block) => block.kind.type === "blockquote"), "Quote missing");
  require_(
    parsed.blocks.some(
      (block) => block.kind.type === "list" && block.kind.items.some((item) => item.marker.type === "task")
    ),
    "Tasks missing"
  );
  require_(parsed.blocks.some((block) => block.kind.type === "list"), "List missing");
  require_(
    parsed.blocks.some((block) => block.kind.type === "code" && block.kind.language === "swift"),
    "Code fence missing"
  );
}

function checkMultilineNestedLists() {
  const parsed = Parser.parse(
    [
      "1. First acceptance criterion wraps onto",
      "   a second line.",
      "   1. Nested detail also wraps onto",
      "      another line.",
      "   1. Another nested detail.",
      "1. Second top-level criterion."
    ].join("\n")
  );

  const first = parsed.blocks[0];
  require_(first !== undefined && first.kind.type === "list", "Multiline list was split into separate blocks");
  const items = first.kind.items;
  require_(items.length === 4, "Nested list item count was incorrect");
  require_(equal(items.map((item) => item.level), [0, 1, 1, 0]), "Nested list indentation was incorrect");
  require_(items[0].text.includes("a second line."), "Top-level continuation line was lost");
  require_(items[1].text.includes("another line."), "Nested continuation line was lost");
  require_(
    equal(
      items.filter((item) => item.marker.type === "ordered").map((item) => item.marker.number),
      [1, 1, 2, 2]
    ),
    "Ordered list numbering did not advance by nesting level"
  );
}

function checkTables() {
  const parsed = Parser.parse(
    [
      "| Name | Status | Count |",
      "| :--- | :----: | ----: |",
      "| Alpha | **Ready** | 3 |",
      "| Beta | Waiting | 12 |"
    ].join("\n")
  );

  const first = parsed.blocks[0];
  require_(first !== undefined && first.kind.type === "table", "Markdown table was not parsed");
  const table = first.kind.table;
  require_(equal(table.headers, ["Name", "Status", "Count"]), "Table headers were incorrect");
  require_(table.rows.length === 2, "Table rows were incorrect");
  require_(equal(table.alignments, ["leading", "center", "trailing"]), "Table alignment was incorrect");

  const shifted = Parser.parse(
    "Intro\n\n" +
      ["| Name | Status | Count |", "| :--- | :----: | ----: |", "| Alpha | **Ready** | 3 |"].join("\n")
  );
  require_(
    parsed.blocks[0].id === shifted.blocks[shifted.blocks.length - 1].id,
    "Table identity changed when preceding content changed"
  );
}

function checkStableBlockRevisions() {
  const wrapped = Parser.parse("# Title\nA paragraph that is wrapped\nacross two source lines.");
  const reflowed = Parser.parse("# Title\nA paragraph that is wrapped across two source lines.");
  const shifted = Parser.parse(
    "Intro before the section.\n\n# Title\nA paragraph that is wrapped across two source lines."
  );
  const changed = Parser.parse("# Title\nA paragraph with changed content.");

  const wrappedParagraph = wrapped.blocks[1];
  const reflowedParagraph = reflowed.blocks[1];
  const shiftedParagraph = shifted.blocks[shifted.blocks.length - 1];
  const changedParagraph = changed.blocks[1];

  require_(wrappedParagraph.id === reflowedParagraph.id, "Source wrapping changed block identity");
  require_(wrappedParagraph.signature === reflowedParagraph.signature, "Source wrapping changed block revision");
  require_(wrappedParagraph.id === shiftedParagraph.id, "Preceding content changed block identity");
  require_(wrappedParagraph.id !== changedParagraph.id, "Changed prose retained its old block identity");

  const originalTable = Parser.parse("| Key | Value |\n| --- | --- |\n| A | One |").blocks[0];
  const changedTable = Parser.parse("| Key | Value |\n| --- | --- |\n| A | Two |").blocks[0];
  require_(originalTable.id === changedTable.id, "Table row edit changed table identity");
  require_(originalTable.signature !== changedTable.signature, "Table row edit did not change table revision");
}

function checkAttentionAnalysis() {
  const parsed = Parser.parse(
    [
      "# Routine Background",
      "",
      "The document describes the current architecture and normal operating behavior.",
      "",
      "# Active Incident",
      "",
      "A production outage is blocking all users and requires immediate rollback.",
      "",
      "# Proposed Change",
      "",
      "Approval is required before proceeding with this breaking contract change."
    ].join("\n")
  );

  const chunks = Attention.makeChunks(parsed, "incident.md");
  require_(chunks.length === 3, "Attention chunking did not preserve sections");
  require_(
    Attention.documentRevision(parsed) === Attention.documentRevision(parsed),
    "Attention document revision was unstable"
  );

  if (!Attention.isAvailable()) return;

  const observedProgress = [];
  const results = Attention.analyze(chunks, (fraction) => observedProgress.push(fraction));
  require_(observedProgress.length === chunks.length, "Attention progress did not report each section");
  require_(observedProgress[observedProgress.length - 1] === 1, "Attention progress did not finish at 100 percent");
  require_(
    observedProgress.every((value, index) => index === 0 || observedProgress[index - 1] <= value),
    "Attention progress moved backwards"
  );
  require_(results.length <= 9, "Attention results exceeded the category caps");
  require_(
    results.some((result) => result.category === "urgent" && result.breadcrumb === "Active Incident"),
    "Explicit active incident was not ranked urgent"
  );
  require_(
    results.some((result) => result.category === "review" && result.breadcrumb === "Proposed Change"),
    "Explicit approval request was not ranked for review"
  );

  const resolved = Parser.parse(
    [
      "# Historical Test Notes",
      "",
      "The test intentionally verifies an expected failure. The historical production outage was already resolved."
    ].join("\n")
  );
  const resolvedResults = Attention.analyze(Attention.makeChunks(resolved, "history.md"));
  require_(
    resolvedResults
      .filter((result) => result.category === "urgent")
      .every((result) => result.confidence === "relative"),
    "Resolved historical failure received absolute-looking urgency confidence"
  );

  const neutral = Parser.parse(
    [
      "# Overview",
      "",
      "This document explains the current data model and how the components interact.",
      "",
      "# Implementation Details",
      "",
      "The service reads records, applies the configured transformation, and writes the result."
    ].join("\n")
  );
  const neutralResults = Attention.analyze(Attention.makeChunks(neutral, "overview.md"));
  require_(
    neutralResults.some((result) => result.category === "important" || result.category === "review"),
    "Neutral document did not receive relative fallback matches"
  );
  require_(
    neutralResults
      .filter((result) => result.category === "urgent")
      .every((result) => result.confidence === "relative"),
    "Neutral document received absolute-looking urgency confidence"
  );

  const crowdedSource = Array.from({ length: 20 }, (_, offset) =>
    [
      `# Decision ${offset + 1}`,
      "",
      "This architecture decision recommends an important scope change and documents a material tradeoff."
    ].join("\n")
  ).join("\n\n");
  const crowded = Parser.parse(crowdedSource);
  const crowdedResults = Attention.analyze(Attention.makeChunks(crowded, "decisions.md"));
  require_(
    crowdedResults.some((result) => result.category === "important"),
    "Strict important threshold suppressed every explicit decision"
  );
  require_(
    crowdedResults.filter((result) => result.category === "important").length <= 3,
    "Important category exceeded its independent quota"
  );
  require_(
    crowdedResults.filter((result) => result.category === "urgent").length <= 2 &&
      crowdedResults.filter((result) => result.category === "review").length <= 4,
    "Attention category quotas were not enforced"
  );
}

function checkAttentionStability() {
  // Acceptance criterion 8: whitespace-only reflow must not materially alter
  // rankings.
  const source = [
    "# Incident",
    "",
    "A production outage is blocking every customer and requires immediate rollback.",
    "",
    "# Notes",
    "",
    "Approval is required before proceeding with the migration."
  ].join("\n");
  const reflowed = [
    "# Incident",
    "",
    "A production outage is blocking every customer",
    "and requires immediate rollback.",
    "",
    "",
    "# Notes",
    "",
    "Approval is required before proceeding",
    "with the migration."
  ].join("\n");

  const left = Attention.analyze(Attention.makeChunks(Parser.parse(source), "a.md"));
  const right = Attention.analyze(Attention.makeChunks(Parser.parse(reflowed), "a.md"));
  require_(
    equal(
      left.map((result) => `${result.category}:${result.breadcrumb}`),
      right.map((result) => `${result.category}:${result.breadcrumb}`)
    ),
    "Whitespace-only reflow changed attention rankings"
  );
}

function checkAttentionCancellation() {
  const parsed = Parser.parse(
    Array.from({ length: 8 }, (_, offset) => `# Section ${offset + 1}\n\nSome prose about the plan.`).join("\n\n")
  );
  const chunks = Attention.makeChunks(parsed, "cancel.md");
  let seen = 0;
  let threw = false;
  try {
    Attention.analyze(chunks, () => { seen += 1; }, () => seen >= 2);
  } catch (error) {
    threw = error instanceof Attention.AttentionAnalysisError && error.code === "cancelled";
  }
  require_(threw, "Attention analysis did not honor cancellation");
}

function checkReferences() {
  const base = path.join(path.sep === "\\" ? "C:\\tmp" : "/tmp", "notes", "current.md");
  const resolve = (relative) => path.resolve(path.dirname(base), relative);
  const parsed = Parser.parse(
    "See [Plan](plans/plan.md#next) and [[Results|the results]].",
    resolve
  );

  require_(
    equal(parsed.references.map((reference) => reference.label), ["Plan", "the results"]),
    "Reference labels were incorrect"
  );
  require_(
    parsed.references[0].resolvedPath === path.join(path.dirname(base), "plans", "plan.md"),
    "Relative Markdown link did not resolve"
  );
  require_(
    parsed.references[1].resolvedPath === path.join(path.dirname(base), "Results.md"),
    "Wiki link did not resolve"
  );
}

function main() {
  const checks = [
    ["headings and ancestors", checkHeadingsAndAncestors],
    ["stable unique slugs", checkStableUniqueSlugs],
    ["common blocks", checkCommonBlocks],
    ["multiline nested lists", checkMultilineNestedLists],
    ["tables", checkTables],
    ["stable block revisions", checkStableBlockRevisions],
    ["attention analysis", checkAttentionAnalysis],
    ["attention stability", checkAttentionStability],
    ["attention cancellation", checkAttentionCancellation],
    ["references", checkReferences]
  ];

  let failures = 0;
  for (const [name, check] of checks) {
    try {
      check();
      process.stdout.write(`  ok    ${name}\n`);
    } catch (error) {
      failures += 1;
      process.stdout.write(`  FAIL  ${name}: ${error.message}\n`);
    }
  }

  if (failures > 0) {
    process.stdout.write(`\n${failures} marc parser check(s) failed.\n`);
    process.exitCode = 1;
    return;
  }
  process.stdout.write("\nAll marc parser checks passed.\n");
}

main();
