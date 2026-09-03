/*
 * marc — structural Markdown parser.
 *
 * Direct port of Sources/MarcCore/MarkdownParser.swift. Block identities and
 * signatures must stay byte-compatible with the macOS build so that reading
 * state and attention results keep the same meaning across platforms.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.MarcParser = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const FNV_OFFSET = 14695981039346656037n;
  const FNV_PRIME = 1099511628211n;
  const UINT64 = (1n << 64n) - 1n;

  // FNV-1a over UTF-8 bytes, rendered as lowercase hex. Matches
  // String(hash, radix: 16) in Swift, which does not zero-pad.
  function stableIdentifier(source) {
    let hash = FNV_OFFSET;
    const bytes = utf8Bytes(source);
    for (let i = 0; i < bytes.length; i += 1) {
      hash ^= BigInt(bytes[i]);
      hash = (hash * FNV_PRIME) & UINT64;
    }
    return hash.toString(16);
  }

  function utf8Bytes(source) {
    if (typeof TextEncoder !== "undefined") return new TextEncoder().encode(source);
    return Buffer.from(source, "utf8");
  }

  const ALPHANUMERIC = /[\p{L}\p{N}]/u;

  function slug(title) {
    const lowered = title.toLowerCase();
    let mapped = "";
    for (const character of lowered) {
      mapped += ALPHANUMERIC.test(character) ? character : "-";
    }
    const compact = mapped.split("-").filter((part) => part.length > 0).join("-");
    return compact.length === 0 ? "section" : compact;
  }

  function normalizedProse(source) {
    return source.split(/\s+/u).filter((part) => part.length > 0).join(" ");
  }

  function indentationWidth(line) {
    let width = 0;
    for (const character of line) {
      if (character === " ") width += 1;
      else if (character === "\t") width += 4;
      else break;
    }
    return width;
  }

  function parseHeading(line) {
    let hashes = 0;
    while (hashes < line.length && line[hashes] === "#") hashes += 1;
    if (hashes < 1 || hashes > 6) return null;
    if (line[hashes] !== " ") return null;
    return { level: hashes, title: line.slice(hashes).trim() };
  }

  function isHorizontalRule(line) {
    const compact = line.split(" ").join("");
    if (compact.length < 3) return false;
    const unique = new Set(compact);
    if (unique.size !== 1) return false;
    const only = compact[0];
    return only === "-" || only === "*" || only === "_";
  }

  const TASK_PREFIXES = [
    "- [ ] ", "* [ ] ", "+ [ ] ",
    "- [x] ", "- [X] ", "* [x] ", "* [X] ", "+ [x] ", "+ [X] "
  ];
  const BULLET_PREFIXES = ["- ", "* ", "+ "];

  function parseListItem(line) {
    const indentation = indentationWidth(line);
    let cut = 0;
    while (cut < line.length && (line[cut] === " " || line[cut] === "\t")) cut += 1;
    const content = line.slice(cut);
    const level = Math.floor(indentation / 3);

    for (const prefix of TASK_PREFIXES) {
      if (content.startsWith(prefix)) {
        return {
          level,
          marker: { type: "task", checked: prefix.toLowerCase().includes("[x]") },
          text: content.slice(prefix.length)
        };
      }
    }

    for (const prefix of BULLET_PREFIXES) {
      if (content.startsWith(prefix)) {
        return { level, marker: { type: "bullet" }, text: content.slice(prefix.length) };
      }
    }

    const dot = content.indexOf(".");
    if (dot < 0) return null;
    const numberText = content.slice(0, dot);
    if (!/^\d+$/u.test(numberText)) return null;
    const number = Number.parseInt(numberText, 10);
    if (!(number > 0)) return null;
    if (content[dot + 1] !== " ") return null;
    return { level, marker: { type: "ordered", number }, text: content.slice(dot + 2) };
  }

  function beginsBlock(line) {
    return (
      parseHeading(line) !== null ||
      line.startsWith("```") ||
      line.startsWith("~~~") ||
      line.startsWith(">") ||
      parseListItem(line) !== null ||
      isHorizontalRule(line)
    );
  }

  function splitTableRow(line) {
    let content = line.trim();
    if (content.startsWith("|")) content = content.slice(1);
    if (content.endsWith("|")) content = content.slice(0, -1);

    const cells = [];
    let current = "";
    let escaped = false;
    for (const character of content) {
      if (escaped) {
        current += character;
        escaped = false;
      } else if (character === "\\") {
        escaped = true;
      } else if (character === "|") {
        cells.push(current.trim());
        current = "";
      } else {
        current += character;
      }
    }
    if (escaped) current += "\\";
    cells.push(current.trim());
    return cells;
  }

  function parseTableHeader(headerLine, separatorLine) {
    if (!headerLine.includes("|") || !separatorLine.includes("|")) return null;
    const headers = splitTableRow(headerLine);
    const separators = splitTableRow(separatorLine);
    if (headers.length === 0 || headers.length !== separators.length) return null;

    const alignments = [];
    for (const separator of separators) {
      const cell = separator.trim();
      const startsWithColon = cell.startsWith(":");
      const endsWithColon = cell.endsWith(":");
      const dashes = cell.replace(/^:+/u, "").replace(/:+$/u, "");
      if (dashes.length < 3) return null;
      if (!/^-+$/u.test(dashes)) return null;
      if (startsWithColon && endsWithColon) alignments.push("center");
      else if (endsWithColon) alignments.push("trailing");
      else alignments.push("leading");
    }
    return { headers, alignments };
  }

  function normalizedTableRow(line, columnCount) {
    const cells = splitTableRow(line);
    while (cells.length < columnCount) cells.push("");
    return cells.slice(0, columnCount);
  }

  function blockType(kind) {
    switch (kind.type) {
      case "heading": return "heading";
      case "paragraph": return "paragraph";
      case "list": return "list";
      case "table": return "table";
      case "blockquote": return "quote";
      case "code": return "code";
      default: return "rule";
    }
  }

  function canonicalBlockContent(kind) {
    switch (kind.type) {
      case "heading":
        return `h${kind.level}:${normalizedProse(kind.title)}`;
      case "paragraph":
        return normalizedProse(kind.text);
      case "list":
        return kind.items
          .map((item) => {
            let marker;
            if (item.marker.type === "bullet") marker = "bullet";
            else if (item.marker.type === "ordered") marker = `ordered:${item.marker.number}`;
            else marker = `task:${item.marker.checked}`;
            return `${item.level}:${marker}:${normalizedProse(item.text)}`;
          })
          .join("\n");
      case "table":
        return [kind.table.headers, ...kind.table.rows]
          .map((row) => row.map(normalizedProse).join("|"))
          .join("\n");
      case "blockquote":
        return normalizedProse(kind.text);
      case "code":
        return `${kind.language === null || kind.language === undefined ? "" : kind.language}\n${kind.content}`;
      default:
        return "horizontal-rule";
    }
  }

  const INLINE_LINK_PATTERN =
    /\[([^\]]+)\]\(([^)\s]+(?:\.md|\.markdown)(?:#[^)]*)?)\)/giu;
  const WIKI_LINK_PATTERN = /\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]/gu;

  function decodeDestination(destination) {
    try {
      return decodeURIComponent(destination);
    } catch (error) {
      return destination;
    }
  }

  function addReference(label, destination, resolve, results, seen) {
    const decoded = decodeDestination(destination);
    const path = decoded.split("#")[0] ?? decoded;
    if (path.length === 0 || seen.has(path)) return;
    seen.add(path);
    results.push({
      id: path,
      label,
      destination,
      resolvedPath: resolve ? resolve(path) : null
    });
  }

  function references(source, resolve) {
    const results = [];
    const seen = new Set();

    INLINE_LINK_PATTERN.lastIndex = 0;
    let match = INLINE_LINK_PATTERN.exec(source);
    while (match !== null) {
      addReference(match[1], match[2], resolve, results, seen);
      match = INLINE_LINK_PATTERN.exec(source);
    }

    WIKI_LINK_PATTERN.lastIndex = 0;
    match = WIKI_LINK_PATTERN.exec(source);
    while (match !== null) {
      const target = match[1].trim();
      const label = match[2] === undefined ? target : match[2];
      const destination = target.toLowerCase().endsWith(".md") ? target : `${target}.md`;
      addReference(label, destination, resolve, results, seen);
      match = WIKI_LINK_PATTERN.exec(source);
    }

    return results;
  }

  /**
   * Parse Markdown into structural blocks, headings, and outgoing references.
   *
   * @param {string} source raw Markdown text
   * @param {(relativePath: string) => string} [resolveReference] maps a
   *   reference destination to an absolute path; omitted when link resolution
   *   is not needed (parser checks, embedding input).
   */
  function parse(source, resolveReference) {
    const normalized = source.replace(/\r\n/gu, "\n");
    const lines = normalized.split("\n");
    const blocks = [];
    const headings = [];
    const headingStack = [];
    const slugCounts = new Map();
    const tableIDCounts = new Map();
    const blockIDCounts = new Map();
    let index = 0;

    const ancestors = () => headingStack.map((entry) => entry.id);

    function append(kind, forcedID) {
      const signature = stableIdentifier(canonicalBlockContent(kind));
      let blockID;
      if (forcedID !== undefined) {
        blockID = forcedID;
      } else {
        const baseID = `${blockType(kind)}-${signature}`;
        const count = (blockIDCounts.get(baseID) ?? 0) + 1;
        blockIDCounts.set(baseID, count);
        blockID = count === 1 ? baseID : `${baseID}-${count}`;
      }
      blocks.push({ id: blockID, signature, kind, ancestorHeadingIDs: ancestors() });
    }

    while (index < lines.length) {
      const line = lines[index];
      const trimmed = line.trim();

      if (trimmed.length === 0) {
        index += 1;
        continue;
      }

      if (trimmed.startsWith("```") || trimmed.startsWith("~~~")) {
        const fence = trimmed.slice(0, 3);
        const language = trimmed.slice(3).trim();
        const codeLines = [];
        index += 1;
        while (index < lines.length && !lines[index].trim().startsWith(fence)) {
          codeLines.push(lines[index]);
          index += 1;
        }
        if (index < lines.length) index += 1;
        append({
          type: "code",
          language: language.length === 0 ? null : language,
          content: codeLines.join("\n")
        });
        continue;
      }

      const heading = parseHeading(trimmed);
      if (heading !== null) {
        while (headingStack.length > 0 && headingStack[headingStack.length - 1].level >= heading.level) {
          headingStack.pop();
        }
        const baseSlug = slug(heading.title);
        const count = slugCounts.get(baseSlug) ?? 0;
        slugCounts.set(baseSlug, count + 1);
        const id = count === 0 ? baseSlug : `${baseSlug}-${count + 1}`;
        const kind = { type: "heading", level: heading.level, title: heading.title };
        blocks.push({
          id,
          signature: stableIdentifier(canonicalBlockContent(kind)),
          kind,
          ancestorHeadingIDs: ancestors()
        });
        headings.push({ id, level: heading.level, title: heading.title });
        headingStack.push({ level: heading.level, id });
        index += 1;
        continue;
      }

      if (index + 1 < lines.length) {
        const tableHeader = parseTableHeader(lines[index], lines[index + 1]);
        if (tableHeader !== null) {
          const baseTableID = `table-${stableIdentifier(tableHeader.headers.join("|"))}`;
          const tableCount = (tableIDCounts.get(baseTableID) ?? 0) + 1;
          tableIDCounts.set(baseTableID, tableCount);
          const tableID = tableCount === 1 ? baseTableID : `${baseTableID}-${tableCount}`;
          const rows = [];
          index += 2;
          while (index < lines.length) {
            const candidate = lines[index];
            if (candidate.trim().length === 0 || !candidate.includes("|")) break;
            rows.push(normalizedTableRow(candidate, tableHeader.headers.length));
            index += 1;
          }
          append(
            {
              type: "table",
              table: {
                headers: tableHeader.headers,
                alignments: tableHeader.alignments,
                rows
              }
            },
            tableID
          );
          continue;
        }
      }

      if (isHorizontalRule(trimmed)) {
        append({ type: "horizontalRule" });
        index += 1;
        continue;
      }

      if (trimmed.startsWith(">")) {
        const quoteLines = [];
        while (index < lines.length) {
          const candidate = lines[index].trim();
          if (!candidate.startsWith(">")) break;
          quoteLines.push(candidate.slice(1).trim());
          index += 1;
        }
        append({ type: "blockquote", text: quoteLines.join("\n") });
        continue;
      }

      if (parseListItem(line) !== null) {
        const items = [];
        let orderedCounters = new Map();

        while (index < lines.length) {
          const item = parseListItem(lines[index]);
          if (item !== null) {
            const trimmedCounters = new Map();
            for (const [key, value] of orderedCounters) {
              if (key <= item.level) trimmedCounters.set(key, value);
            }
            orderedCounters = trimmedCounters;

            if (item.marker.type === "ordered") {
              const existing = orderedCounters.get(item.level);
              const number = existing === undefined ? item.marker.number : existing + 1;
              orderedCounters.set(item.level, number);
              item.marker = { type: "ordered", number };
            } else {
              orderedCounters.delete(item.level);
            }
            items.push(item);
            index += 1;
            continue;
          }

          const continuation = lines[index];
          const continuationText = continuation.trim();
          if (continuationText.length === 0) {
            if (index + 1 < lines.length && parseListItem(lines[index + 1]) !== null) {
              index += 1;
              continue;
            }
            break;
          }

          if (
            items.length === 0 ||
            !(indentationWidth(continuation) > items[items.length - 1].level * 3) ||
            beginsBlock(continuationText)
          ) {
            break;
          }
          items[items.length - 1].text += `\n${continuationText}`;
          index += 1;
        }

        append({ type: "list", items });
        continue;
      }

      const paragraph = [trimmed];
      index += 1;
      while (index < lines.length) {
        const next = lines[index].trim();
        if (next.length === 0) {
          index += 1;
          break;
        }
        if (beginsBlock(next)) break;
        paragraph.push(next);
        index += 1;
      }
      append({ type: "paragraph", text: paragraph.join("\n") });
    }

    return {
      blocks,
      headings,
      references: references(normalized, resolveReference)
    };
  }

  return {
    parse,
    stableIdentifier,
    slug,
    normalizedProse,
    canonicalBlockContent,
    parseListItem,
    parseTableHeader,
    splitTableRow,
    isHorizontalRule
  };
});
