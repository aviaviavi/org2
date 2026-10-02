/**
 * Small, dependency-free syntax highlighter for OpenOrg's rendered views.
 *
 * It covers the common lexical classes (comments, strings, keywords, numbers,
 * literals, types, function calls, decorators, markup tags) of the major
 * languages well enough for reading code, without executing anything or
 * loading a script into the document view. Output is escaped HTML with
 * `org2-tok-*` spans; unknown languages fall back to escaped plain text.
 */

export type CodeTokenKind =
  | "comment"
  | "string"
  | "keyword"
  | "number"
  | "literal"
  | "type"
  | "function"
  | "property"
  | "meta"
  | "tag"
  | "attr"
  | "variable";

export interface CodeToken {
  text: string;
  kind?: CodeTokenKind;
}

interface LanguageSpec {
  lineComments?: string[];
  blockComments?: Array<[string, string]>;
  /** String delimiters, longest first is enforced by the tokenizer. */
  strings?: string[];
  /** Delimiters whose contents may span lines (template/triple strings). */
  multilineStrings?: string[];
  /** Delimiters that ignore backslash escapes. */
  rawStrings?: string[];
  keywords?: string[];
  literals?: string[];
  types?: string[];
  caseInsensitive?: boolean;
  capitalizedTypes?: boolean;
  /** `@name` decorators/annotations/attributes. */
  decorators?: boolean;
  /** `$name` / `${...}` shell-style variables. */
  shellVariables?: boolean;
  /** Identifier or string directly followed by `:` is a key (JSON/YAML). */
  keysBeforeColon?: boolean;
  /** `#[...]`/`#include` style preprocessor lines. */
  preprocessor?: boolean;
  markup?: boolean;
  identifierChars?: RegExp;
}

const words = (value: string) => value.split(/\s+/).filter(Boolean);

const cLike = {
  lineComments: ["//"],
  blockComments: [["/*", "*/"]] as Array<[string, string]>,
  strings: ['"', "'"],
};

const SPECS: Record<string, LanguageSpec> = {
  python: {
    lineComments: ["#"],
    strings: ['"""', "'''", '"', "'"],
    multilineStrings: ['"""', "'''"],
    keywords: words("and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case type"),
    literals: words("True False None self cls"),
    types: words("int float str bool list dict set tuple bytes object Exception"),
    decorators: true,
    capitalizedTypes: true,
  },
  javascript: {
    ...cLike,
    strings: ["`", '"', "'"],
    multilineStrings: ["`"],
    keywords: words("async await break case catch class const continue debugger default delete do else export extends finally for from function get if import in instanceof let new of return set static super switch this throw try typeof var void while with yield"),
    literals: words("true false null undefined NaN Infinity"),
    capitalizedTypes: true,
    decorators: true,
  },
  typescript: {
    ...cLike,
    strings: ["`", '"', "'"],
    multilineStrings: ["`"],
    keywords: words("abstract as asserts async await break case catch class const continue declare default delete do else enum export extends finally for from function get if implements import in infer instanceof interface is keyof let namespace new of private protected public readonly return satisfies set static super switch this throw try type typeof var void while with yield"),
    literals: words("true false null undefined NaN Infinity"),
    types: words("any unknown never string number boolean bigint symbol object void"),
    capitalizedTypes: true,
    decorators: true,
  },
  swift: {
    ...cLike,
    strings: ['"""', '"'],
    multilineStrings: ['"""'],
    keywords: words("actor associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough fileprivate for func guard if import in init inout internal is let mutating nonisolated open operator private protocol public repeat rethrows return some any static struct subscript super switch throw throws try typealias var where while"),
    literals: words("true false nil self Self"),
    capitalizedTypes: true,
    decorators: true,
    preprocessor: true,
  },
  go: {
    ...cLike,
    strings: ["`", '"', "'"],
    multilineStrings: ["`"],
    rawStrings: ["`"],
    keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var"),
    literals: words("true false nil iota"),
    types: words("bool byte complex64 complex128 error float32 float64 int int8 int16 int32 int64 rune string uint uint8 uint16 uint32 uint64 uintptr any"),
    capitalizedTypes: true,
  },
  rust: {
    ...cLike,
    strings: ['"'],
    keywords: words("as async await break const continue crate dyn else enum extern fn for if impl in let loop match mod move mut pub ref return static struct super trait type unsafe use where while"),
    literals: words("true false self Self None Some Ok Err"),
    types: words("i8 i16 i32 i64 i128 isize u8 u16 u32 u64 u128 usize f32 f64 bool char str String Vec Option Result Box"),
    capitalizedTypes: true,
    preprocessor: true,
  },
  java: {
    ...cLike,
    strings: ['"""', '"', "'"],
    multilineStrings: ['"""'],
    keywords: words("abstract assert break case catch class const continue default do else enum extends final finally for goto if implements import instanceof interface native new package private protected public record return sealed static strictfp super switch synchronized this throw throws transient try var void volatile while yield"),
    literals: words("true false null"),
    types: words("boolean byte char double float int long short String Object"),
    capitalizedTypes: true,
    decorators: true,
  },
  kotlin: {
    ...cLike,
    strings: ['"""', '"', "'"],
    multilineStrings: ['"""'],
    keywords: words("as break class companion continue data do else enum fun for if import in interface is internal lateinit object open override package private protected public return sealed super suspend this throw try typealias val var when while"),
    literals: words("true false null"),
    capitalizedTypes: true,
    decorators: true,
  },
  c: {
    ...cLike,
    keywords: words("auto break case const continue default do else enum extern for goto if inline register restrict return sizeof static struct switch typedef union volatile while"),
    literals: words("NULL true false"),
    types: words("char double float int long short signed unsigned void bool size_t"),
    preprocessor: true,
  },
  cpp: {
    ...cLike,
    keywords: words("alignas alignof auto break case catch class const constexpr const_cast continue decltype default delete do dynamic_cast else enum explicit export extern for friend goto if inline mutable namespace new noexcept operator private protected public register reinterpret_cast return sizeof static static_assert static_cast struct switch template this throw try typedef typeid typename union using virtual volatile while"),
    literals: words("true false nullptr NULL"),
    types: words("bool char double float int long short signed unsigned void wchar_t size_t std string vector"),
    capitalizedTypes: true,
    preprocessor: true,
  },
  csharp: {
    ...cLike,
    keywords: words("abstract as async await base break case catch checked class const continue default delegate do else enum event explicit extern finally fixed for foreach goto if implicit in interface internal is lock namespace new operator out override params private protected public readonly record ref return sealed sizeof static struct switch this throw try typeof unchecked unsafe using var virtual void volatile while"),
    literals: words("true false null"),
    types: words("bool byte char decimal double float int long object sbyte short string uint ulong ushort"),
    capitalizedTypes: true,
    preprocessor: true,
  },
  ruby: {
    lineComments: ["#"],
    strings: ['"', "'"],
    keywords: words("alias and begin break case class def defined? do else elsif end ensure for if in module next not or redo rescue retry return super then undef unless until when while yield require require_relative attr_accessor attr_reader"),
    literals: words("true false nil self"),
    capitalizedTypes: true,
  },
  php: {
    lineComments: ["//", "#"],
    blockComments: [["/*", "*/"]],
    strings: ['"', "'"],
    keywords: words("abstract and array as break case catch class clone const continue declare default do echo else elseif empty enum extends final finally fn for foreach function global if implements include interface isset list match namespace new or print private protected public readonly require return static switch throw trait try unset use var while yield"),
    literals: words("true false null TRUE FALSE NULL"),
    capitalizedTypes: true,
    shellVariables: true,
  },
  shell: {
    lineComments: ["#"],
    strings: ['"', "'"],
    rawStrings: ["'"],
    multilineStrings: ['"', "'"],
    keywords: words("if then else elif fi case esac for select while until do done in function time return exit break continue local export readonly declare set unset shift source alias trap eval exec"),
    literals: words("true false"),
    shellVariables: true,
    identifierChars: /[A-Za-z0-9_-]/,
  },
  json: {
    strings: ['"'],
    literals: words("true false null"),
    keysBeforeColon: true,
  },
  yaml: {
    lineComments: ["#"],
    strings: ['"', "'"],
    literals: words("true false null yes no on off ~"),
    keysBeforeColon: true,
    identifierChars: /[A-Za-z0-9_.-]/,
  },
  toml: {
    lineComments: ["#"],
    strings: ['"""', "'''", '"', "'"],
    multilineStrings: ['"""', "'''"],
    rawStrings: ["'''", "'"],
    literals: words("true false"),
    keysBeforeColon: false,
    identifierChars: /[A-Za-z0-9_.-]/,
  },
  sql: {
    lineComments: ["--"],
    blockComments: [["/*", "*/"]],
    strings: ["'", '"'],
    caseInsensitive: true,
    keywords: words("add all alter and as asc begin between by case check column commit constraint create cross database default delete desc distinct drop else end exists foreign from full group having if in index inner insert into is join key left like limit not null offset on or order outer primary references returning right rollback select set table then transaction union unique update using values view when where with"),
    literals: words("true false null"),
    types: words("int integer bigint smallint text varchar char boolean date timestamp timestamptz numeric decimal real float double json jsonb uuid serial"),
  },
  css: {
    blockComments: [["/*", "*/"]],
    strings: ['"', "'"],
    keywords: words("important media supports keyframes import font-face"),
    keysBeforeColon: true,
    identifierChars: /[A-Za-z0-9_-]/,
  },
  haskell: {
    lineComments: ["--"],
    blockComments: [["{-", "-}"]],
    strings: ['"'],
    keywords: words("case class data default deriving do else foreign if import in infix infixl infixr instance let module newtype of then type where forall qualified as hiding"),
    literals: words("True False Nothing Just"),
    capitalizedTypes: true,
    identifierChars: /[A-Za-z0-9_']/,
  },
  scala: {
    ...cLike,
    strings: ['"""', '"', "'"],
    multilineStrings: ['"""'],
    keywords: words("abstract case catch class def do else enum extends final finally for given if implicit import lazy match new object override package private protected return sealed super then throw trait try type using val var while with yield"),
    literals: words("true false null this"),
    capitalizedTypes: true,
    decorators: true,
  },
  lua: {
    lineComments: ["--"],
    blockComments: [["--[[", "]]"]],
    strings: ['"', "'"],
    keywords: words("and break do else elseif end for function goto if in local not or repeat return then until while"),
    literals: words("true false nil self"),
  },
  r: {
    lineComments: ["#"],
    strings: ['"', "'"],
    keywords: words("if else repeat while function for in next break return library require"),
    literals: words("TRUE FALSE NULL NA NaN Inf T F"),
  },
  elixir: {
    lineComments: ["#"],
    strings: ['"""', '"', "'"],
    multilineStrings: ['"""'],
    keywords: words("after alias and case catch cond def defmacro defmodule defp defstruct do else end fn for if import in not or quote raise receive require rescue try unless use when with"),
    literals: words("true false nil"),
    capitalizedTypes: true,
    decorators: true,
  },
  lisp: {
    lineComments: [";"],
    strings: ['"'],
    keywords: words("defun defmacro defvar defcustom defconst let let* lambda if when unless cond progn setq setf require provide interactive ns def defn fn loop recur"),
    literals: words("t nil true false"),
    identifierChars: /[A-Za-z0-9_*+!?<>=/-]/,
  },
  dockerfile: {
    lineComments: ["#"],
    strings: ['"', "'"],
    caseInsensitive: false,
    keywords: words("FROM RUN CMD LABEL EXPOSE ENV ADD COPY ENTRYPOINT VOLUME USER WORKDIR ARG ONBUILD STOPSIGNAL HEALTHCHECK SHELL AS"),
    shellVariables: true,
  },
  makefile: {
    lineComments: ["#"],
    strings: ['"', "'"],
    keywords: words("ifeq ifneq ifdef ifndef else endif include define endef export override"),
    shellVariables: true,
    keysBeforeColon: true,
    identifierChars: /[A-Za-z0-9_.-]/,
  },
  nix: {
    lineComments: ["#"],
    blockComments: [["/*", "*/"]],
    strings: ["''", '"'],
    multilineStrings: ["''"],
    keywords: words("let in with rec inherit if then else assert import"),
    literals: words("true false null"),
    shellVariables: true,
  },
  markup: { markup: true },
  plaintext: {},
};

const ALIASES: Record<string, string> = {
  py: "python", python3: "python", python: "python", ipython: "python",
  js: "javascript", javascript: "javascript", node: "javascript", jsx: "javascript", mjs: "javascript", cjs: "javascript",
  ts: "typescript", typescript: "typescript", tsx: "typescript", mts: "typescript", cts: "typescript",
  swift: "swift",
  go: "go", golang: "go",
  rs: "rust", rust: "rust",
  java: "java",
  kt: "kotlin", kts: "kotlin", kotlin: "kotlin",
  c: "c", h: "c",
  cpp: "cpp", "c++": "cpp", cc: "cpp", cxx: "cpp", hpp: "cpp", hh: "cpp", hxx: "cpp", objc: "cpp", m: "cpp", mm: "cpp",
  cs: "csharp", csharp: "csharp",
  rb: "ruby", ruby: "ruby",
  php: "php",
  sh: "shell", bash: "shell", zsh: "shell", shell: "shell", fish: "shell", ksh: "shell", console: "shell",
  json: "json", jsonc: "json", json5: "json", jsonl: "json", ndjson: "json", "ipynb": "json",
  yaml: "yaml", yml: "yaml",
  toml: "toml", ini: "toml", cfg: "toml", conf: "toml", properties: "toml", env: "shell",
  sql: "sql", psql: "sql", sqlite: "sql", postgresql: "sql", mysql: "sql",
  html: "markup", htm: "markup", xml: "markup", svg: "markup", plist: "markup", xhtml: "markup", vue: "markup",
  css: "css", scss: "css", less: "css", sass: "css",
  hs: "haskell", haskell: "haskell",
  scala: "scala", sc: "scala", sbt: "scala",
  lua: "lua",
  r: "r",
  ex: "elixir", exs: "elixir", elixir: "elixir",
  el: "lisp", "emacs-lisp": "lisp", elisp: "lisp", lisp: "lisp", clj: "lisp", cljs: "lisp", clojure: "lisp", scm: "lisp", scheme: "lisp",
  dockerfile: "dockerfile", docker: "dockerfile", containerfile: "dockerfile",
  makefile: "makefile", make: "makefile", mk: "makefile",
  nix: "nix",
  txt: "plaintext", text: "plaintext", log: "plaintext", plaintext: "plaintext", csv: "plaintext", tsv: "plaintext",
};

/** Canonical highlighter language for a source block language or alias. */
export function normalizeCodeLanguage(language: string | undefined | null): string | null {
  const key = String(language ?? "").trim().toLowerCase();
  if (!key) return null;
  return ALIASES[key] ?? (SPECS[key] ? key : null);
}

/**
 * Highlighter language for a file path that should be shown as code rather
 * than parsed as Org. Org, Markdown, and other document formats return null.
 */
export function codeLanguageForPath(filePath: string | undefined | null): string | null {
  const base = String(filePath ?? "").split(/[\\/]/).pop() ?? "";
  const lower = base.toLowerCase();
  if (!lower) return null;
  if (lower === "dockerfile" || lower.startsWith("dockerfile.") || lower === "containerfile") return "dockerfile";
  if (lower === "makefile" || lower === "gnumakefile") return "makefile";
  if ([".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc"].includes(lower)) return "shell";
  const dot = lower.lastIndexOf(".");
  if (dot <= 0 || dot === lower.length - 1) return null;
  const extension = lower.slice(dot + 1);
  if (["org", "org2", "md", "markdown", "csv", "tsv", "canvas", "pdf"].includes(extension)) return null;
  return ALIASES[extension] ?? null;
}

const HIGHLIGHT_LIMIT = 1_000_000;

/** Tokenize source text. Concatenating every token's text yields the input. */
export function tokenizeCode(source: string, language: string | null | undefined): CodeToken[] {
  const canonical = normalizeCodeLanguage(language);
  const spec = canonical ? SPECS[canonical] : undefined;
  if (!spec || canonical === "plaintext" || source.length > HIGHLIGHT_LIMIT) return source ? [{ text: source }] : [];
  return spec.markup ? tokenizeMarkup(source) : tokenizeWithSpec(source, spec);
}

function tokenizeWithSpec(source: string, spec: LanguageSpec): CodeToken[] {
  const tokens: CodeToken[] = [];
  const push = (text: string, kind?: CodeTokenKind) => {
    if (!text) return;
    const last = tokens[tokens.length - 1];
    if (last && last.kind === kind) last.text += text;
    else tokens.push(kind ? { text, kind } : { text });
  };
  const fold = (value: string) => (spec.caseInsensitive ? value.toLowerCase() : value);
  const keywords = new Set((spec.keywords ?? []).map(fold));
  const literals = new Set((spec.literals ?? []).map(fold));
  const types = new Set((spec.types ?? []).map(fold));
  const strings = [...(spec.strings ?? [])].sort((a, b) => b.length - a.length);
  const multiline = new Set(spec.multilineStrings ?? []);
  const raw = new Set(spec.rawStrings ?? []);
  const identStart = /[A-Za-z_$]/;
  const identChar = spec.identifierChars ?? /[A-Za-z0-9_$]/;
  const length = source.length;
  let lineStart = true;
  let i = 0;

  const nextNonSpace = (from: number) => {
    let j = from;
    while (j < length && (source[j] === " " || source[j] === "\t")) j++;
    return source[j];
  };
  /** `key:` or `key :`, but not `a::b` scope operators. */
  const isKeyColon = (from: number) => {
    let j = from;
    while (j < length && (source[j] === " " || source[j] === "\t")) j++;
    return source[j] === ":" && source[j + 1] !== ":";
  };

  while (i < length) {
    const ch = source[i]!;
    if (ch === "\n") { push(ch); lineStart = true; i++; continue; }
    if (ch === " " || ch === "\t" || ch === "\r") { push(ch); i++; continue; }
    const atLineStart = lineStart;
    lineStart = false;

    const block = spec.blockComments?.find(([open]) => source.startsWith(open, i));
    if (block) {
      const end = source.indexOf(block[1], i + block[0].length);
      const stop = end < 0 ? length : end + block[1].length;
      push(source.slice(i, stop), "comment");
      i = stop;
      continue;
    }
    const line = spec.lineComments?.find((marker) => source.startsWith(marker, i)
      && !(marker === "#" && spec.shellVariables && i > 0 && source[i - 1] === "$"));
    if (line) {
      const end = source.indexOf("\n", i);
      const stop = end < 0 ? length : end;
      push(source.slice(i, stop), "comment");
      i = stop;
      continue;
    }
    if (spec.preprocessor && atLineStart && ch === "#") {
      const end = source.indexOf("\n", i);
      const stop = end < 0 ? length : end;
      push(source.slice(i, stop), "meta");
      i = stop;
      continue;
    }

    const delimiter = strings.find((open) => source.startsWith(open, i));
    if (delimiter) {
      const allowsNewline = multiline.has(delimiter);
      const escapes = !raw.has(delimiter);
      let j = i + delimiter.length;
      while (j < length) {
        if (escapes && source[j] === "\\") { j += 2; continue; }
        if (source.startsWith(delimiter, j)) { j += delimiter.length; break; }
        if (source[j] === "\n" && !allowsNewline) break;
        j++;
      }
      const stop = Math.min(j, length);
      const text = source.slice(i, stop);
      const isKey = spec.keysBeforeColon && isKeyColon(stop);
      push(text, isKey ? "property" : "string");
      i = stop;
      continue;
    }

    if (spec.shellVariables && ch === "$") {
      if (source[i + 1] === "{") {
        const end = source.indexOf("}", i + 2);
        const stop = end < 0 || source.slice(i, end).includes("\n") ? i + 1 : end + 1;
        push(source.slice(i, stop), stop > i + 1 ? "variable" : undefined);
        i = stop;
        continue;
      }
      let j = i + 1;
      while (j < length && /[A-Za-z0-9_@#?*!$-]/.test(source[j]!) && (j === i + 1 || /[A-Za-z0-9_]/.test(source[j]!))) j++;
      push(source.slice(i, j), j > i + 1 ? "variable" : undefined);
      i = j;
      continue;
    }

    if (spec.decorators && ch === "@" && i + 1 < length && identStart.test(source[i + 1]!)) {
      let j = i + 1;
      while (j < length && /[A-Za-z0-9_.]/.test(source[j]!)) j++;
      push(source.slice(i, j), "meta");
      i = j;
      continue;
    }

    const previous = i > 0 ? source[i - 1]! : "";
    if (/[0-9]/.test(ch) || (ch === "." && /[0-9]/.test(source[i + 1] ?? "") && !identChar.test(previous))) {
      if (!identChar.test(previous)) {
        const match = /^(?:0[xX][0-9a-fA-F_]+|0[bB][01_]+|0[oO][0-7_]+|(?:\d[\d_]*)?\.?\d[\d_]*(?:[eE][+-]?\d+)?)[A-Za-z%]*/.exec(source.slice(i, i + 64));
        if (match && match[0]) {
          push(match[0], "number");
          i += match[0].length;
          continue;
        }
      }
    }

    if (identStart.test(ch)) {
      let j = i + 1;
      while (j < length && identChar.test(source[j]!)) j++;
      // A trailing `?` belongs to Ruby predicates such as `defined?`.
      if (source[j] === "?" && keywords.has(fold(source.slice(i, j + 1)))) j++;
      const word = source.slice(i, j);
      const key = fold(word);
      let kind: CodeTokenKind | undefined;
      if (spec.keysBeforeColon && isKeyColon(j)) kind = "property";
      else if (keywords.has(key)) kind = "keyword";
      else if (literals.has(key)) kind = "literal";
      else if (types.has(key)) kind = "type";
      else if (spec.capitalizedTypes && /^[A-Z][A-Za-z0-9_]*[a-z][A-Za-z0-9_]*$/.test(word)) kind = "type";
      else if (nextNonSpace(j) === "(") kind = "function";
      push(word, kind);
      i = j;
      continue;
    }

    push(ch);
    i++;
  }
  return tokens;
}

function tokenizeMarkup(source: string): CodeToken[] {
  const tokens: CodeToken[] = [];
  const push = (text: string, kind?: CodeTokenKind) => { if (text) tokens.push(kind ? { text, kind } : { text }); };
  const length = source.length;
  let i = 0;
  while (i < length) {
    if (source.startsWith("<!--", i)) {
      const end = source.indexOf("-->", i + 4);
      const stop = end < 0 ? length : end + 3;
      push(source.slice(i, stop), "comment");
      i = stop;
      continue;
    }
    if (source.startsWith("<![CDATA[", i)) {
      const end = source.indexOf("]]>", i);
      const stop = end < 0 ? length : end + 3;
      push(source.slice(i, stop), "string");
      i = stop;
      continue;
    }
    if (source[i] === "<" && /[A-Za-z/!?]/.test(source[i + 1] ?? "")) {
      const name = /^<[/!?]?[A-Za-z][\w:.-]*/.exec(source.slice(i, i + 256));
      if (name) {
        push(name[0], "tag");
        i += name[0].length;
        while (i < length && source[i] !== ">" && !(source[i] === "/" && source[i + 1] === ">") && !(source[i] === "?" && source[i + 1] === ">")) {
          const ch = source[i]!;
          if (ch === '"' || ch === "'") {
            const end = source.indexOf(ch, i + 1);
            const stop = end < 0 ? length : end + 1;
            push(source.slice(i, stop), "string");
            i = stop;
          } else if (/[A-Za-z_:@]/.test(ch)) {
            const attr = /^[A-Za-z_:@][\w:.-]*/.exec(source.slice(i, i + 256))![0];
            push(attr, "attr");
            i += attr.length;
          } else {
            push(ch);
            i++;
          }
        }
        const close = source.startsWith("/>", i) || source.startsWith("?>", i) ? 2 : source[i] === ">" ? 1 : 0;
        push(source.slice(i, i + close), "tag");
        i += close;
        continue;
      }
    }
    if (source[i] === "&") {
      const entity = /^&(?:#\d+|#x[0-9a-fA-F]+|[A-Za-z][A-Za-z0-9]*);/.exec(source.slice(i, i + 32));
      if (entity) { push(entity[0], "literal"); i += entity[0].length; continue; }
    }
    let j = i + 1;
    while (j < length && source[j] !== "<" && source[j] !== "&") j++;
    push(source.slice(i, j));
    i = j;
  }
  return tokens;
}

function escapeHtml(value: string): string {
  return value.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

/** Escaped HTML with `org2-tok-*` spans for one highlighted block. */
export function highlightCodeToHtml(source: string, language: string | null | undefined): string {
  return tokenizeCode(source, language)
    .map((token) => (token.kind ? `<span class="org2-tok-${token.kind}">${escapeHtml(token.text)}</span>` : escapeHtml(token.text)))
    .join("");
}

/**
 * Escaped HTML split into one element per source line. Token spans are closed
 * and reopened at line breaks so each line is a self-contained element that
 * can carry `data-org2-start-line` for exact link and search navigation.
 */
export function highlightCodeLinesToHtml(
  source: string,
  language: string | null | undefined,
  lineAttributes: (line: number) => string = () => "",
): string {
  const lines: string[] = [];
  let current = "";
  for (const token of tokenizeCode(source, language)) {
    const parts = token.text.split("\n");
    parts.forEach((part, index) => {
      if (index > 0) { lines.push(current); current = ""; }
      if (part) current += token.kind ? `<span class="org2-tok-${token.kind}">${escapeHtml(part)}</span>` : escapeHtml(part);
    });
  }
  lines.push(current);
  if (lines.length > 1 && lines[lines.length - 1] === "" && source.endsWith("\n")) lines.pop();
  return lines
    .map((line, index) => `<span class="org2-code-line"${lineAttributes(index + 1)}>${line}</span>`)
    .join("\n");
}
