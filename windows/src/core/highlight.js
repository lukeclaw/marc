/*
 * marc — fenced code syntax highlighting.
 *
 * Direct port of Sources/MarcCore/SyntaxHighlighter.swift. Span offsets are
 * UTF-16 code unit offsets in both builds — NSString on macOS, JavaScript
 * strings here — so the two produce identical spans for identical input.
 *
 * Lexical only: one pass, no grammar, no dependencies, and no execution of the
 * code being highlighted.
 */
(function (root, factory) {
  const api = factory();
  if (typeof module === "object" && module.exports) module.exports = api;
  root.MarcHighlight = api;
})(typeof globalThis !== "undefined" ? globalThis : this, function () {
  "use strict";

  const TOKEN_KINDS = [
    "comment",
    "string",
    "number",
    "keyword",
    "type",
    "function",
    "property",
    "annotation",
    "literal",
    "operatorSymbol"
  ];

  /* ------------------------------------------------- character predicates */

  // Swift's Character.isLetter / .isNumber are Unicode aware, so these are too.
  const LETTER = /\p{L}/u;
  const NUMBER = /\p{N}/u;
  const LOWERCASE = /\p{Ll}/u;
  const UPPERCASE = /\p{Lu}/u;
  const WHITESPACE = /\s/u;
  const HEX_DIGIT = /[0-9A-Fa-f]/u;
  const OPERATOR_CHARACTERS = "+-*/%=!<>?&|^~:";
  const NUMBER_PREFIX_CHARACTERS = "([{,:;=";

  function isLetter(character) {
    return character !== "" && LETTER.test(character);
  }

  function isNumber(character) {
    return character !== "" && NUMBER.test(character);
  }

  function isWhitespace(character) {
    return character !== "" && WHITESPACE.test(character);
  }

  function isHexDigit(character) {
    return character !== "" && HEX_DIGIT.test(character);
  }

  function isIdentifierStart(character) {
    return character === "_" || character === "$" || isLetter(character);
  }

  function isIdentifierBody(character) {
    return isIdentifierStart(character) || isNumber(character);
  }

  function isNumberBody(character) {
    return isHexDigit(character) || character === "_" || character === ".";
  }

  function isOperator(character) {
    return character !== "" && OPERATOR_CHARACTERS.includes(character);
  }

  /* -------------------------------------------------------------- scanner */

  class Scanner {
    constructor(source, definition) {
      this.source = source;
      this.definition = definition;
      this.length = source.length;
    }

    character(index) {
      return index >= 0 && index < this.length ? this.source[index] : "";
    }

    hasPrefix(prefix, index) {
      if (index + prefix.length > this.length) return false;
      return this.source.startsWith(prefix, index);
    }

    scan() {
      if (this.length === 0) return [];
      const spans = [];
      let index = 0;

      while (index < this.length) {
        let span = this.comment(index);
        if (span === null) span = this.string(index);
        if (span === null) span = this.annotation(index);
        if (span === null && this.isNumberStart(index)) span = this.number(index);
        if (span !== null) {
          spans.push(span);
          index = span.location + span.length;
          continue;
        }

        if (isIdentifierStart(this.character(index))) {
          const identifier = this.identifier(index);
          // An unclassified identifier produces no span but is still consumed.
          if (identifier !== null) spans.push(identifier);
          index = this.identifierEnd(index);
          continue;
        }

        if (isOperator(this.character(index))) {
          const end = this.operatorEnd(index);
          spans.push({ location: index, length: end - index, kind: "operatorSymbol" });
          index = end;
          continue;
        }

        index += 1;
      }

      return spans;
    }

    comment(index) {
      const definition = this.definition;
      if (definition === null) return null;

      for (const marker of definition.lineComments) {
        if (!this.hasPrefix(marker, index)) continue;
        const end = this.lineEnd(index);
        return { location: index, length: end - index, kind: "comment" };
      }

      for (const pair of definition.blockComments) {
        if (!this.hasPrefix(pair.open, index)) continue;
        const searchStart = index + pair.open.length;
        const closeIndex = this.source.indexOf(pair.close, searchStart);
        const end = closeIndex < 0 ? this.length : closeIndex + pair.close.length;
        return { location: index, length: end - index, kind: "comment" };
      }

      return null;
    }

    string(index) {
      const quote = this.character(index);
      if (quote !== '"' && quote !== "'" && quote !== "`") return null;

      const triple = this.hasPrefix(quote + quote + quote, index);
      let cursor = index + (triple ? 3 : 1);

      while (cursor < this.length) {
        if (this.character(cursor) === "\\") {
          cursor = Math.min(this.length, cursor + 2);
          continue;
        }
        if (triple && this.hasPrefix(quote + quote + quote, cursor)) {
          cursor += 3;
          break;
        }
        if (!triple && this.character(cursor) === quote) {
          cursor += 1;
          break;
        }
        cursor += 1;
      }

      // In JSON and YAML a quoted token followed by a colon is a key, not a value.
      let kind = "string";
      if (this.definition !== null && this.definition.isDataLanguage) {
        const next = this.nextNonWhitespace(cursor);
        if (next < this.length && this.character(next) === ":") kind = "property";
      }
      return { location: index, length: cursor - index, kind };
    }

    annotation(index) {
      if (this.character(index) !== "@" || index + 1 >= this.length) return null;
      if (!isIdentifierStart(this.character(index + 1))) return null;
      const end = this.identifierEnd(index + 1);
      return { location: index, length: end - index, kind: "annotation" };
    }

    number(index) {
      let cursor = index;
      if (this.character(cursor) === "-") cursor += 1;
      if (cursor >= this.length) return null;

      if (
        cursor + 1 < this.length &&
        this.character(cursor) === "0" &&
        ["x", "X", "b", "B", "o", "O"].includes(this.character(cursor + 1))
      ) {
        cursor += 2;
        while (cursor < this.length && isNumberBody(this.character(cursor))) cursor += 1;
      } else {
        while (cursor < this.length && (isNumber(this.character(cursor)) || this.character(cursor) === "_")) {
          cursor += 1;
        }
        if (cursor < this.length && this.character(cursor) === ".") {
          cursor += 1;
          while (cursor < this.length && (isNumber(this.character(cursor)) || this.character(cursor) === "_")) {
            cursor += 1;
          }
        }
        if (cursor < this.length && (this.character(cursor) === "e" || this.character(cursor) === "E")) {
          cursor += 1;
          if (cursor < this.length && (this.character(cursor) === "+" || this.character(cursor) === "-")) {
            cursor += 1;
          }
          while (cursor < this.length && (isNumber(this.character(cursor)) || this.character(cursor) === "_")) {
            cursor += 1;
          }
        }
        while (cursor < this.length && "fFdDlLuU".includes(this.character(cursor))) cursor += 1;
      }

      if (cursor <= index) return null;
      return { location: index, length: cursor - index, kind: "number" };
    }

    identifier(index) {
      const definition = this.definition;
      const end = this.identifierEnd(index);
      const token = this.source.slice(index, end);
      const lookup = definition !== null && definition.caseInsensitive ? token.toLowerCase() : token;

      if (definition !== null && definition.literals.has(lookup)) {
        return { location: index, length: end - index, kind: "literal" };
      }
      if (definition !== null && definition.keywords.has(lookup)) {
        return { location: index, length: end - index, kind: "keyword" };
      }
      if ((definition !== null && definition.types.has(lookup)) || this.looksLikeType(token, index)) {
        return { location: index, length: end - index, kind: "type" };
      }

      const next = this.nextNonWhitespace(end);
      if (next < this.length && this.character(next) === "(") {
        return { location: index, length: end - index, kind: "function" };
      }

      const previous = this.previousNonWhitespace(index);
      if (previous >= 0 && this.character(previous) === ".") {
        return { location: index, length: end - index, kind: "property" };
      }
      if (
        definition !== null &&
        definition.isDataLanguage &&
        next < this.length &&
        (this.character(next) === ":" || this.character(next) === "=")
      ) {
        return { location: index, length: end - index, kind: "property" };
      }
      return null;
    }

    /* A CamelCase word that is not a member access reads as a type name. */
    looksLikeType(token, index) {
      if (this.definition === null || !this.definition.capitalizedTypes) return false;
      if (token.length <= 1) return false;
      if (!UPPERCASE.test(token[0])) return false;
      const previous = this.previousNonWhitespace(index);
      if (previous >= 0 && this.character(previous) === ".") return false;
      return LOWERCASE.test(token);
    }

    identifierEnd(index) {
      let cursor = index;
      while (cursor < this.length && isIdentifierBody(this.character(cursor))) cursor += 1;
      return cursor;
    }

    operatorEnd(index) {
      let cursor = index;
      while (cursor < this.length && isOperator(this.character(cursor))) cursor += 1;
      return cursor;
    }

    lineEnd(index) {
      let cursor = index;
      while (cursor < this.length && this.character(cursor) !== "\n") cursor += 1;
      return cursor;
    }

    nextNonWhitespace(index) {
      let cursor = index;
      while (cursor < this.length && isWhitespace(this.character(cursor))) cursor += 1;
      return cursor;
    }

    previousNonWhitespace(index) {
      let cursor = index - 1;
      while (cursor >= 0 && isWhitespace(this.character(cursor))) cursor -= 1;
      return cursor;
    }

    /*
     * A minus sign only opens a number where a value can start, so that "1-2"
     * stays three tokens rather than one number and one negative number.
     */
    isNumberStart(index) {
      const current = this.character(index);
      if (isNumber(current)) return true;
      if (current !== "-" || index + 1 >= this.length) return false;
      if (!isNumber(this.character(index + 1))) return false;
      const previous = this.previousNonWhitespace(index);
      if (previous < 0) return true;
      const before = this.character(previous);
      return isOperator(before) || NUMBER_PREFIX_CHARACTERS.includes(before);
    }
  }

  /* -------------------------------------------------- language definitions */

  const COMMON_LITERALS = new Set(["true", "false", "null", "nil", "none", "undefined"]);

  function words(source, lowercased) {
    const parts = source.split(" ").filter((word) => word.length > 0);
    return new Set(lowercased ? parts.map((word) => word.toLowerCase()) : parts);
  }

  function define(displayName, options) {
    const caseInsensitive = options.caseInsensitive === true;
    return {
      displayName,
      keywords: words(options.keywords ?? "", caseInsensitive),
      types: words(options.types ?? "", caseInsensitive),
      literals: COMMON_LITERALS,
      lineComments: options.lineComments ?? [],
      blockComments: (options.blockComments ?? []).map(([open, close]) => ({ open, close })),
      caseInsensitive,
      capitalizedTypes: options.capitalizedTypes === true,
      isDataLanguage: options.isDataLanguage === true
    };
  }

  function withDisplayName(definition, displayName) {
    return { ...definition, displayName };
  }

  const SWIFT = define("SWIFT", {
    keywords:
      "actor any as associatedtype async await borrowing break case catch class consuming continue convenience copy default defer deinit didSet distributed do dynamic each else enum extension fallthrough fileprivate final for func get guard if import indirect init in infix internal isolated lazy let macro mutating nonisolated open operator optional override package postfix precedencegroup prefix private protocol public repeat required rethrows return self some static struct subscript super switch throws throwing try typealias unowned var weak where while willSet",
    types:
      "Any AnyObject Array Bool Character Data Date Dictionary Double Error Float Int Optional Result Set String UInt URL UUID Void",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const KOTLIN = define("KOTLIN", {
    keywords:
      "as break by catch class companion const constructor continue crossinline data delegate do dynamic else enum expect external false field file final finally for fun get if import in infix init inline inner interface internal is lateinit noinline null object open operator out override package param private property protected public receiver reified return sealed set setparam suspend tailrec this throw true try typealias typeof val var vararg when where while",
    types: "Any Boolean Byte Char Double Float Int List Long Map Nothing Pair Result Set Short String Unit",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const JAVA = define("JAVA", {
    keywords:
      "abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public record return sealed short static strictfp super switch synchronized this throw throws transient try var void volatile while yield",
    types:
      "BigDecimal BigInteger Boolean Byte Character Class Double Exception Float Integer List Long Map Object Optional Set Short String StringBuilder Throwable UUID",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const JAVASCRIPT = define("JAVASCRIPT", {
    keywords:
      "async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield",
    types: "Array BigInt Boolean Date Error Function Map Number Object Promise RegExp Set String Symbol",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const TYPESCRIPT = define("TYPESCRIPT", {
    keywords:
      "abstract any as asserts async await boolean break case catch class const constructor continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let module namespace never new of private protected public readonly require return set static string super switch symbol this throw try type typeof undefined unique unknown var void while with yield",
    types: "Array BigInt Boolean Date Error Function Map Number Object Promise Record RegExp Set String Symbol",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const PYTHON = define("PYTHON", {
    keywords:
      "and as assert async await break case class continue def del elif else except finally for from global if import in is lambda match nonlocal not or pass raise return try while with yield",
    types: "Any Callable Dict Exception Iterable List Optional Protocol Set Tuple Type Union",
    lineComments: ["#"],
    blockComments: [],
    capitalizedTypes: true
  });

  const GO = define("GO", {
    keywords:
      "break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var",
    types:
      "any bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const RUST = define("RUST", {
    keywords:
      "as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self static struct super trait true type unsafe use where while",
    types: "Box Option Result Self String Vec bool char f32 f64 i8 i16 i32 i64 i128 isize str u8 u16 u32 u64 u128 usize",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const C_FAMILY = define("C / C++", {
    keywords:
      "alignas alignof asm auto break case catch class const constexpr continue default delete do else enum explicit export extern for friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast return signed sizeof static struct switch template this throw try typedef typename union unsigned using virtual volatile while",
    types: "bool char double float int int16_t int32_t int64_t long size_t string uint16_t uint32_t uint64_t void wchar_t",
    lineComments: ["//"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const SQL = define("SQL", {
    keywords:
      "all alter and any as asc begin between by case cast check column commit constraint create database default delete desc distinct drop else end exists false foreign from full grant group having in index inner insert intersect into is join left like limit not null on or order outer primary references right rollback row select set table then true union unique update values view when where with",
    types:
      "bigint binary boolean char date decimal double float int integer interval json numeric real smallint text timestamp varchar",
    lineComments: ["--"],
    blockComments: [["/*", "*/"]],
    caseInsensitive: true
  });

  const SHELL = define("SHELL", {
    keywords:
      "case do done elif else esac export fi for function if in local readonly return set shift then time trap unset until while",
    types: "",
    lineComments: ["#"],
    blockComments: []
  });

  const JSON_LANGUAGE = define("JSON", {
    keywords: "",
    types: "",
    lineComments: [],
    blockComments: [],
    isDataLanguage: true
  });

  const YAML = define("YAML", {
    keywords: "",
    types: "",
    lineComments: ["#"],
    blockComments: [],
    isDataLanguage: true
  });

  const MARKUP = define("HTML / XML", {
    keywords:
      "doctype html head body script style div span section article header footer main nav table tr td th a img form input button",
    types: "",
    lineComments: [],
    blockComments: [["<!--", "-->"]],
    isDataLanguage: true
  });

  const CSS = define("CSS", {
    keywords:
      "color background border display position width height margin padding font grid flex block inline absolute relative fixed inherit initial unset",
    types: "",
    lineComments: [],
    blockComments: [["/*", "*/"]],
    isDataLanguage: true
  });

  const GENERIC = define("CODE", {
    keywords: "class enum function func import let new return struct type var",
    types: "",
    lineComments: ["//", "#"],
    blockComments: [["/*", "*/"]],
    capitalizedTypes: true
  });

  const ALIASES = [
    [["swift"], SWIFT],
    [["kt", "kotlin", "kts"], KOTLIN],
    [["java"], JAVA],
    [["js", "javascript", "jsx", "node"], JAVASCRIPT],
    [["ts", "tsx", "typescript"], TYPESCRIPT],
    [["py", "python", "python3"], PYTHON],
    [["go", "golang"], GO],
    [["rs", "rust"], RUST],
    [["c", "cc", "cpp", "c++", "h", "hpp", "objc", "objective-c"], C_FAMILY],
    [["sql", "mysql", "postgres", "postgresql", "trino"], SQL],
    [["bash", "console", "fish", "shell", "sh", "zsh"], SHELL],
    [["json", "json5", "jsonc"], JSON_LANGUAGE],
    [["yaml", "yml"], YAML],
    [["html", "htm", "xml", "svg"], MARKUP],
    [["css", "less", "scss", "sass"], CSS]
  ].map(([names, definition]) => [new Set(names), definition]);

  function resolve(rawLanguage) {
    if (rawLanguage === null || rawLanguage === undefined) return null;

    const first = rawLanguage.toLowerCase().trim().split(/\s+/u)[0] ?? "";
    const language = first.replace(/^[{}.]+/u, "").replace(/[{}.]+$/u, "");

    for (const [names, definition] of ALIASES) {
      if (names.has(language)) return definition;
    }
    return withDisplayName(GENERIC, language.length === 0 ? "CODE" : language.toUpperCase());
  }

  /*
   * Inference for unlabeled blocks, deliberately conservative: a wrong guess is
   * worse than no highlighting, so each rule needs a strong, specific signal.
   */
  function infer(source) {
    const lowered = source.toLowerCase();
    const trimmed = source.trim();

    if (trimmed.startsWith("{") || trimmed.startsWith("[")) {
      try {
        JSON.parse(source);
        return JSON_LANGUAGE;
      } catch (error) {
        // Not JSON after all; fall through to the remaining rules.
      }
    }
    if (lowered.includes("select ") && lowered.includes(" from ")) return SQL;
    if ((lowered.includes("import foundation") || lowered.includes("func ")) && lowered.includes("let ")) {
      return SWIFT;
    }
    if (lowered.includes("package main") || lowered.includes("func main(")) return GO;
    if (lowered.includes("fn main(") || lowered.includes("let mut ")) return RUST;
    if ((lowered.includes("fun main(") || lowered.includes("val ")) && lowered.includes("package ")) {
      return KOTLIN;
    }
    if (lowered.includes("public class ") || lowered.includes("system.out.")) return JAVA;
    if (lowered.includes("def ") && lowered.includes(":")) return PYTHON;
    if (
      lowered.includes("interface ") ||
      lowered.includes(": string") ||
      lowered.includes(": number")
    ) {
      return TYPESCRIPT;
    }
    if (lowered.includes("const ") || lowered.includes("=>")) return JAVASCRIPT;
    if (trimmed.startsWith("#!") || lowered.includes("set -e")) return SHELL;
    // Matched against the original case, as the macOS build does. An uppercase
    // <!DOCTYPE therefore falls through here too; fix it on macOS first.
    if (trimmed.startsWith("<!doctype") || trimmed.startsWith("<html") || trimmed.startsWith("<?xml")) {
      return MARKUP;
    }
    return GENERIC;
  }

  /* ---------------------------------------------------------------- entry */

  function highlight(source, language) {
    const definition = resolve(language) ?? infer(source);
    return {
      languageName: definition.displayName,
      spans: new Scanner(source, definition).scan()
    };
  }

  return { highlight, tokenKinds: TOKEN_KINDS };
});
