/*
 * marc — inline Markdown rendering.
 *
 * The macOS build renders inline spans with Foundation's
 * AttributedString(markdown:, interpretedSyntax: .inlineOnlyPreservingWhitespace).
 * This is the equivalent: emphasis, strong, strikethrough, code spans, links,
 * and wiki links only. Block syntax is handled by the structural parser, and
 * raw HTML is escaped and shown as text rather than executed.
 */
"use strict";

const MarcInline = (() => {
  function escapeHTML(text) {
    return text
      .replace(/&/gu, "&amp;")
      .replace(/</gu, "&lt;")
      .replace(/>/gu, "&gt;")
      .replace(/"/gu, "&quot;")
      .replace(/'/gu, "&#39;");
  }

  function isMarkdownDestination(destination) {
    const withoutFragment = destination.split("#")[0] ?? destination;
    return /\.(md|markdown|mdown|mkd)$/iu.test(withoutFragment);
  }

  function linkMarkup(label, destination) {
    const safeDestination = escapeHTML(destination);
    if (isMarkdownDestination(destination)) {
      return `<a class="md-link" data-md-link="${safeDestination}" title="${safeDestination}">${label}</a>`;
    }
    if (/^https?:\/\//iu.test(destination)) {
      return `<a class="md-link" data-external="${safeDestination}" title="${safeDestination}">${label}</a>`;
    }
    return `<a class="md-link" data-plain="${safeDestination}" title="${safeDestination}">${label}</a>`;
  }

  /**
   * Render one inline Markdown fragment to HTML.
   *
   * Code spans and links are lifted out into placeholders first so that
   * emphasis markers inside a URL or a code span are never interpreted.
   */
  function render(source) {
    if (source === null || source === undefined) return "";

    const placeholders = [];
    const stash = (html) => {
      placeholders.push(html);
      return `\u0000${placeholders.length - 1}\u0000`;
    };

    let text = escapeHTML(String(source).replace(/\u0000/gu, ""));

    // Code spans.
    text = text.replace(/`([^`\n]+)`/gu, (match, code) => stash(`<code class="md-inline-code">${code}</code>`));

    // Images render as their alt text; marc never loads remote resources.
    text = text.replace(/!\[([^\]]*)\]\(([^)\s]*)[^)]*\)/gu, (match, alt) => escapeHTML(alt));

    // Wiki links: [[target]] or [[target|label]].
    text = text.replace(/\[\[([^\]|#]+)(#[^\]|]+)?(?:\|([^\]]+))?\]\]/gu, (match, target, fragment, label) => {
      const trimmed = target.trim();
      const destination = /\.md$/iu.test(trimmed) ? trimmed : `${trimmed}.md`;
      return stash(linkMarkup(escapeHTML(label === undefined ? trimmed : label), destination));
    });

    // Inline links.
    text = text.replace(/\[([^\]]+)\]\(([^)\s]+)(?:\s+"[^"]*")?\)/gu, (match, label, destination) =>
      stash(linkMarkup(label, destination))
    );

    // Bare autolinks.
    text = text.replace(/<(https?:\/\/[^\s>]+)>/gu, (match, url) => stash(linkMarkup(escapeHTML(url), url)));

    // Emphasis. Strong before emphasis so that *** resolves outermost first.
    text = text.replace(/\*\*\*(?!\s)([\s\S]+?)(?<!\s)\*\*\*/gu, "<strong><em>$1</em></strong>");
    text = text.replace(/\*\*(?!\s)([\s\S]+?)(?<!\s)\*\*/gu, "<strong>$1</strong>");
    text = text.replace(/__(?!\s)([\s\S]+?)(?<!\s)__/gu, "<strong>$1</strong>");
    text = text.replace(/(^|[^\w*])\*(?!\s)([^*\n]+?)(?<!\s)\*(?!\w)/gu, "$1<em>$2</em>");
    text = text.replace(/(^|[^\w_])_(?!\s)([^_\n]+?)(?<!\s)_(?!\w)/gu, "$1<em>$2</em>");
    text = text.replace(/~~([\s\S]+?)~~/gu, "<del>$1</del>");

    return text.replace(/\u0000(\d+)\u0000/gu, (match, index) => placeholders[Number(index)]);
  }

  /** Strip inline markers, for tooltips and plain-text comparisons. */
  function plain(source) {
    if (source === null || source === undefined) return "";
    return String(source)
      .replace(/`([^`\n]+)`/gu, "$1")
      .replace(/!\[([^\]]*)\]\([^)]*\)/gu, "$1")
      .replace(/\[\[([^\]|#]+)(?:#[^\]|]+)?(?:\|([^\]]+))?\]\]/gu, (match, target, label) =>
        label === undefined ? target : label
      )
      .replace(/\[([^\]]+)\]\([^)]*\)/gu, "$1")
      .replace(/\*\*\*|\*\*|__|~~/gu, "")
      .replace(/(^|[^\w*])\*([^*\n]+?)\*(?!\w)/gu, "$1$2")
      .replace(/(^|[^\w_])_([^_\n]+?)_(?!\w)/gu, "$1$2");
  }

  return { render, plain, escapeHTML, isMarkdownDestination };
})();
