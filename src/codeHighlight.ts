/**
 * Small, dependency-free syntax highlighter for Celorga's rendered views.
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
  /**
   * Rules tried at the first non-blank character of a line. The match is
   * highlighted and tokenizing continues after it (Markdown headings, diff
   * hunks, INI sections).
   */
  lineRules?: Array<{ pattern: RegExp; kind: CodeTokenKind }>;
  /** Anchored rules tried at every position before identifiers (links, LaTeX commands). */
  inlineRules?: Array<{ pattern: RegExp; kind: CodeTokenKind }>;
  /** Prose-like formats: no number, identifier, or call highlighting. */
  plainWords?: boolean;
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
  markdown: {
    strings: ["`"],
    plainWords: true,
    lineRules: [
      { pattern: /^#{1,6}(?:\s.*)?$/, kind: "keyword" },
      { pattern: /^>.*$/, kind: "comment" },
      { pattern: /^(?:```|~~~).*$/, kind: "meta" },
      { pattern: /^(?:-{3,}|\*{3,}|_{3,})\s*$/, kind: "meta" },
      { pattern: /^(?:[-*+]|\d+[.)])(?=\s)/, kind: "keyword" },
    ],
    inlineRules: [
      { pattern: /!?\[[^\]\n]*\]\([^)\n]*\)/, kind: "function" },
      { pattern: /\*\*[^*\n]+\*\*|__[^_\n]+__/, kind: "type" },
      { pattern: /<https?:\/\/[^>\s]+>/, kind: "function" },
    ],
  },
  diff: {
    plainWords: true,
    lineRules: [
      { pattern: /^(?:diff|index|similarity|rename|new file|deleted file)\b.*$/, kind: "keyword" },
      { pattern: /^(?:\+\+\+|---)(?:\s.*)?$/, kind: "keyword" },
      { pattern: /^@@.*$/, kind: "meta" },
      { pattern: /^\+.*$/, kind: "string" },
      { pattern: /^-.*$/, kind: "variable" },
    ],
  },
  ini: {
    lineComments: [";", "#"],
    strings: ['"', "'"],
    literals: words("true false yes no on off null"),
    identifierChars: /[A-Za-z0-9_.-]/,
    lineRules: [
      { pattern: /^\[[^\]\n]*\]/, kind: "type" },
      { pattern: /^[A-Za-z0-9_.@-][A-Za-z0-9_.@ -]*?(?=\s*[=:])/, kind: "property" },
    ],
  },
  graphql: {
    lineComments: ["#"],
    strings: ['"""', '"'],
    multilineStrings: ['"""'],
    keywords: words("query mutation subscription fragment on type interface union enum scalar input extend schema directive implements repeatable"),
    literals: words("true false null"),
    types: words("Int Float String Boolean ID"),
    decorators: true,
    shellVariables: true,
    capitalizedTypes: true,
  },
  protobuf: {
    ...cLike,
    keywords: words("syntax edition package import option message enum service rpc returns stream oneof map reserved extensions extend optional required repeated public weak to max struct union exception namespace include typedef const throws"),
    literals: words("true false"),
    types: words("double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes i8 i16 i32 i64 binary list set void"),
    capitalizedTypes: true,
  },
  hcl: {
    lineComments: ["#", "//"],
    blockComments: [["/*", "*/"]],
    strings: ['"'],
    keywords: words("resource data variable output locals module provider terraform backend required_providers for_each count depends_on lifecycle dynamic content for in if else endif endfor"),
    literals: words("true false null"),
    types: words("string number bool list map set object tuple any"),
    identifierChars: /[A-Za-z0-9_-]/,
    shellVariables: true,
  },
  zig: {
    lineComments: ["//"],
    strings: ['"', "'"],
    keywords: words("addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline noalias nosuspend noinline opaque or orelse packed pub resume return linksection struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while"),
    literals: words("true false null undefined"),
    types: words("i8 u8 i16 u16 i32 u32 i64 u64 i128 u128 isize usize f16 f32 f64 f80 f128 bool void noreturn type anyerror anyopaque comptime_int comptime_float"),
    decorators: true,
    capitalizedTypes: true,
  },
  dart: {
    ...cLike,
    strings: ['"""', "'''", '"', "'"],
    multilineStrings: ['"""', "'''"],
    keywords: words("abstract as assert async await base break case catch class const continue covariant default deferred do dynamic else enum export extends extension external factory final finally for function get hide if implements import in interface is late library mixin new of on operator part required rethrow return sealed set show static super switch sync this throw try typedef var void when while with yield"),
    literals: words("true false null"),
    types: words("int double num String bool List Map Set Future Stream Object dynamic"),
    decorators: true,
    capitalizedTypes: true,
  },
  julia: {
    lineComments: ["#"],
    blockComments: [["#=", "=#"]],
    strings: ['"""', '"'],
    multilineStrings: ['"""'],
    keywords: words("abstract baremodule begin break catch const continue do else elseif end export finally for function global if import let local macro module mutable primitive quote return struct try type using where while"),
    literals: words("true false nothing missing NaN Inf"),
    types: words("Int Int8 Int16 Int32 Int64 UInt8 Float32 Float64 Bool String Char Vector Matrix Array Dict Tuple Any Nothing"),
    decorators: true,
    capitalizedTypes: true,
  },
  perl: {
    lineComments: ["#"],
    strings: ['"', "'", "`"],
    rawStrings: ["'"],
    keywords: words("my our local sub package use no require if elsif else unless while until for foreach do last next redo return and or not eq ne lt gt le ge cmp print printf die warn eval BEGIN END"),
    literals: words("undef"),
    shellVariables: true,
  },
  ocaml: {
    blockComments: [["(*", "*)"]],
    strings: ['"'],
    keywords: words("and as assert begin class constraint do done downto else end exception external for fun function functor if in include inherit initializer lazy let match method module mutable new nonrec object of open or private rec sig struct then to try type val virtual when while with"),
    literals: words("true false"),
    types: words("int float bool char string unit list array option ref"),
    identifierChars: /[A-Za-z0-9_']/,
    capitalizedTypes: true,
  },
  fsharp: {
    lineComments: ["//"],
    blockComments: [["(*", "*)"]],
    strings: ['"""', '"'],
    multilineStrings: ['"""'],
    keywords: words("abstract and as assert base begin class default delegate do done downcast downto elif else end exception extern for fun function global if in inherit inline interface internal lazy let match member module mutable namespace new not of open or override private public rec return static struct then to try type upcast use val void when while with yield"),
    literals: words("true false null"),
    types: words("int float bool char string unit list array option seq decimal int64 byte"),
    identifierChars: /[A-Za-z0-9_']/,
    capitalizedTypes: true,
  },
  erlang: {
    lineComments: ["%"],
    strings: ['"'],
    keywords: words("after and andalso band begin bnot bor bsl bsr bxor case catch cond div end fun if let not of or orelse receive rem try when xor"),
    literals: words("true false undefined ok error"),
    capitalizedTypes: true,
  },
  powershell: {
    lineComments: ["#"],
    blockComments: [["<#", "#>"]],
    strings: ['"', "'"],
    rawStrings: ["'"],
    keywords: words("begin break catch class continue data define do dynamicparam else elseif end enum exit filter finally for foreach from function if in param process return switch throw trap try until using var while workflow"),
    caseInsensitive: true,
    shellVariables: true,
    identifierChars: /[A-Za-z0-9_-]/,
  },
  batch: {
    lineComments: ["::", "REM ", "rem ", "@rem ", "@REM "],
    strings: ['"'],
    keywords: words("call cd chdir cls copy del dir echo else endlocal errorlevel exist exit for goto if in md mkdir move not pause popd pushd rd rem ren rmdir set setlocal shift start title type"),
    caseInsensitive: true,
    inlineRules: [{ pattern: /%[A-Za-z0-9_~:]+%|%%?[A-Za-z0-9]/, kind: "variable" }],
  },
  latex: {
    lineComments: ["%"],
    plainWords: true,
    inlineRules: [
      { pattern: /\\(?:begin|end)\{[^}\n]*\}/, kind: "keyword" },
      { pattern: /\\[A-Za-z@]+\*?|\\./, kind: "function" },
      { pattern: /\$\$?[^$\n]*\$\$?/, kind: "string" },
    ],
  },
  groovy: {
    ...cLike,
    strings: ['"""', "'''", '"', "'"],
    multilineStrings: ['"""', "'''"],
    keywords: words("abstract as assert break case catch class const continue def default do else enum extends final finally for goto if implements import in instanceof interface native new package private protected public return static super switch synchronized this throw throws trait transient try var void volatile while"),
    literals: words("true false null"),
    decorators: true,
    capitalizedTypes: true,
  },
  solidity: {
    ...cLike,
    keywords: words("pragma solidity import contract interface library abstract is function modifier event emit struct enum mapping public private internal external pure view payable constant immutable override virtual returns return if else for while do break continue new delete using memory storage calldata require revert assert try catch constructor fallback receive unchecked"),
    literals: words("true false wei gwei ether seconds minutes hours days weeks"),
    types: words("address bool string bytes byte int uint int256 uint256 uint8 bytes32"),
  },
  asm: {
    lineComments: [";", "#", "//"],
    strings: ['"', "'"],
    keywords: words("mov add sub mul div inc dec push pop call ret jmp je jne jz jnz jg jl cmp test and or xor not shl shr lea nop int syscall ldr str b bl bx cbz cbnz section global extern db dw dd dq resb"),
    types: words("rax rbx rcx rdx rsi rdi rbp rsp eax ebx ecx edx esi edi ebp esp r8 r9 r10 r11 r12 r13 r14 r15 x0 x1 x2 x3 sp lr pc"),
    caseInsensitive: true,
    identifierChars: /[A-Za-z0-9_.]/,
  },
  fortran: {
    lineComments: ["!"],
    strings: ['"', "'"],
    keywords: words("program end module use implicit none integer real double precision complex logical character dimension parameter allocatable intent in out inout subroutine function call return if then else elseif endif do enddo while select case contains type interface print write read stop"),
    caseInsensitive: true,
  },
  matlab: {
    lineComments: ["%"],
    blockComments: [["%{", "%}"]],
    strings: ['"', "'"],
    keywords: words("break case catch classdef continue else elseif end for function global if otherwise parfor persistent return spmd switch try while"),
    literals: words("true false pi inf NaN eps"),
  },
  crystal: {
    lineComments: ["#"],
    strings: ['"', "`"],
    keywords: words("abstract alias as begin break case class def do else elsif end ensure enum extend for fun if in include lib macro module next of out private protected require rescue return select struct super then type union unless until when while with yield"),
    literals: words("true false nil self"),
    capitalizedTypes: true,
    decorators: true,
  },
  nim: {
    lineComments: ["#"],
    blockComments: [["#[", "]#"]],
    strings: ['"""', '"', "'"],
    multilineStrings: ['"""'],
    keywords: words("addr and as asm bind block break case cast concept const continue converter defer discard distinct div do elif else end enum except export finally for from func if import in include interface is isnot iterator let macro method mixin mod nil not notin object of or out proc ptr raise ref return shl shr static template try tuple type using var when while xor yield"),
    literals: words("true false nil"),
    types: words("int int8 int16 int32 int64 uint float float32 float64 bool char string seq array set"),
    capitalizedTypes: true,
  },
  cmake: {
    lineComments: ["#"],
    strings: ['"'],
    keywords: words("if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return set unset option project cmake_minimum_required add_executable add_library target_link_libraries target_include_directories include find_package message install add_subdirectory"),
    literals: words("ON OFF TRUE FALSE YES NO"),
    caseInsensitive: true,
    shellVariables: true,
  },
  nginx: {
    lineComments: ["#"],
    strings: ['"', "'"],
    keywords: words("server location upstream http events listen server_name root index proxy_pass proxy_set_header return rewrite include error_page access_log error_log ssl_certificate ssl_certificate_key try_files add_header gzip worker_processes"),
    literals: words("on off"),
    shellVariables: true,
  },
  gitignore: {
    lineComments: ["#"],
    plainWords: true,
    lineRules: [{ pattern: /^!.*$/, kind: "keyword" }],
  },
  prisma: {
    lineComments: ["//"],
    strings: ['"'],
    keywords: words("model enum datasource generator type view"),
    literals: words("true false null"),
    types: words("String Boolean Int BigInt Float Decimal DateTime Json Bytes Unsupported"),
    decorators: true,
  },
  coffeescript: {
    lineComments: ["#"],
    blockComments: [["###", "###"]],
    strings: ['"""', "'''", '"', "'"],
    multilineStrings: ['"""', "'''"],
    keywords: words("and break by catch class continue delete do else extends finally for if in instanceof is isnt loop new not of or return super switch then this throw try typeof unless until when while yield"),
    literals: words("true false null undefined yes no on off"),
    decorators: true,
  },
  elm: {
    lineComments: ["--"],
    blockComments: [["{-", "-}"]],
    strings: ['"""', '"'],
    multilineStrings: ['"""'],
    keywords: words("module exposing import as type alias port case of if then else let in"),
    literals: words("True False"),
    capitalizedTypes: true,
  },
  verilog: {
    ...cLike,
    keywords: words("module endmodule input output inout wire reg logic always always_ff always_comb assign begin end if else case endcase for while parameter localparam function endfunction task endtask generate endgenerate initial posedge negedge integer typedef struct enum package endpackage interface endinterface"),
    preprocessor: true,
  },
  vhdl: {
    lineComments: ["--"],
    strings: ['"'],
    keywords: words("library use entity architecture is begin end port map signal variable constant process if then else elsif case when others for loop generate component in out inout of type subtype array record function procedure return wait until"),
    types: words("std_logic std_logic_vector integer boolean natural unsigned signed bit"),
    caseInsensitive: true,
  },
  visualbasic: {
    lineComments: ["'", "REM "],
    strings: ['"'],
    keywords: words("and as boolean byval byref case catch class const dim do each else elseif end enum exit for function get if implements imports in inherits integer interface is loop me module namespace new next not nothing of or private property protected public return select set shared static string structure sub then throw to try until while with"),
    literals: words("true false nothing"),
    caseInsensitive: true,
  },
  jsonnet: {
    ...cLike,
    lineComments: ["//", "#"],
    strings: ["|||", '"', "'"],
    multilineStrings: ["|||"],
    keywords: words("assert else error for function if import importstr importbin in local tailstrict then self super"),
    literals: words("true false null"),
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
  toml: "toml", ini: "ini", cfg: "ini", conf: "ini", properties: "ini", env: "shell",
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
  md: "markdown", markdown: "markdown", mdx: "markdown", mkd: "markdown", rmd: "markdown", qmd: "markdown",
  diff: "diff", patch: "diff", rej: "diff",
  graphql: "graphql", gql: "graphql", graphqls: "graphql",
  proto: "protobuf", protobuf: "protobuf", thrift: "protobuf",
  tf: "hcl", tfvars: "hcl", hcl: "hcl", terraform: "hcl", nomad: "hcl",
  zig: "zig", dart: "dart",
  jl: "julia", julia: "julia",
  pl: "perl", pm: "perl", perl: "perl",
  ml: "ocaml", mli: "ocaml", ocaml: "ocaml", re: "ocaml", rei: "ocaml", reason: "ocaml",
  fs: "fsharp", fsx: "fsharp", fsi: "fsharp", fsharp: "fsharp",
  erl: "erlang", hrl: "erlang", erlang: "erlang",
  ps1: "powershell", psm1: "powershell", psd1: "powershell", powershell: "powershell", pwsh: "powershell",
  bat: "batch", cmd: "batch", batch: "batch",
  tex: "latex", latex: "latex", sty: "latex", cls: "latex", bib: "latex", bibtex: "latex",
  groovy: "groovy", gradle: "groovy", gvy: "groovy", jenkinsfile: "groovy",
  sol: "solidity", solidity: "solidity",
  asm: "asm", s: "asm", nasm: "asm", assembly: "asm",
  f: "fortran", f90: "fortran", f95: "fortran", f03: "fortran", for: "fortran", fortran: "fortran",
  matlab: "matlab", octave: "matlab",
  cr: "crystal", crystal: "crystal",
  nim: "nim", nims: "nim", nimble: "nim",
  cmake: "cmake", nginx: "nginx", nginxconf: "nginx",
  gitignore: "gitignore", dockerignore: "gitignore", npmignore: "gitignore", gitattributes: "gitignore", ignore: "gitignore",
  prisma: "prisma",
  coffee: "coffeescript", coffeescript: "coffeescript", litcoffee: "coffeescript",
  elm: "elm", purs: "haskell", purescript: "haskell", idr: "haskell", agda: "haskell",
  v: "verilog", sv: "verilog", svh: "verilog", verilog: "verilog", systemverilog: "verilog",
  vhd: "vhdl", vhdl: "vhdl",
  vb: "visualbasic", vbs: "visualbasic", bas: "visualbasic", vba: "visualbasic", visualbasic: "visualbasic",
  jsonnet: "jsonnet", libsonnet: "jsonnet",
  bzl: "python", star: "python", starlark: "python", bazel: "python", pyi: "python", pyw: "python", gyp: "python", sage: "python",
  rake: "ruby", gemspec: "ruby", podspec: "ruby", erb: "ruby", ru: "ruby",
  tcsh: "shell", csh: "shell", bats: "shell", envrc: "shell",
  sqlx: "sql", ddl: "sql", hql: "sql", cql: "sql", pgsql: "sql",
  svelte: "markup", astro: "markup", hbs: "markup", handlebars: "markup", mustache: "markup", ejs: "markup", njk: "markup", jinja: "markup", jinja2: "markup", liquid: "markup",
  xsd: "markup", xsl: "markup", xslt: "markup", wsdl: "markup", rss: "markup", atom: "markup", csproj: "markup", fsproj: "markup", vbproj: "markup", props: "markup", targets: "markup", storyboard: "markup", xib: "markup", xaml: "markup", resx: "markup", kml: "markup", gpx: "markup", opml: "markup",
  styl: "css", stylus: "css", pcss: "css", postcss: "css",
  geojson: "json", webmanifest: "json", har: "json", avsc: "json", babelrc: "json", eslintrc: "json", prettierrc: "json", jsonld: "json", topojson: "json",
  cff: "yaml",
  cljc: "lisp", edn: "lisp", ss: "lisp", rkt: "lisp", racket: "lisp", cl: "lisp", lsp: "lisp", fnl: "lisp", fennel: "lisp", wat: "lisp", wast: "lisp", hy: "lisp",
  objectivec: "cpp", "objective-c": "cpp", cu: "cpp", cuh: "cpp", cuda: "cpp", ino: "cpp", glsl: "cpp", vert: "cpp", frag: "cpp", hlsl: "cpp", metal: "cpp", wgsl: "cpp", d: "cpp", hx: "cpp", haxe: "cpp",
  editorconfig: "ini", gitconfig: "ini", npmrc: "ini", desktop: "ini", service: "ini",
  rst: "plaintext", adoc: "plaintext", asciidoc: "plaintext", srt: "plaintext", vtt: "plaintext",
  txt: "plaintext", text: "plaintext", log: "plaintext", plaintext: "plaintext", csv: "plaintext", tsv: "plaintext",
};

/** Languages identified by a whole file name rather than an extension. */
const FILENAME_LANGUAGES: Record<string, string> = {
  "cmakelists.txt": "cmake",
  "nginx.conf": "nginx",
  ".gitignore": "gitignore", ".dockerignore": "gitignore", ".npmignore": "gitignore", ".gitattributes": "gitignore", ".prettierignore": "gitignore", ".eslintignore": "gitignore",
  ".editorconfig": "ini", ".gitconfig": "ini", ".gitmodules": "ini", ".npmrc": "ini", ".pylintrc": "ini", "setup.cfg": "ini", "tox.ini": "ini",
  ".babelrc": "json", ".eslintrc": "json", ".prettierrc": "json", ".swcrc": "json",
  gemfile: "ruby", rakefile: "ruby", podfile: "ruby", vagrantfile: "ruby", brewfile: "ruby", guardfile: "ruby", fastfile: "ruby",
  jenkinsfile: "groovy",
  build: "python", "build.bazel": "python", workspace: "python", "workspace.bazel": "python", tiltfile: "python", snakefile: "python",
  procfile: "yaml",
  "go.mod": "go",
  "cargo.lock": "toml", "poetry.lock": "toml", pipfile: "toml",
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
  if (lower === "makefile" || lower === "gnumakefile" || lower === "justfile" || lower === ".justfile") return "makefile";
  if ([".bashrc", ".zshrc", ".profile", ".bash_profile", ".zprofile", ".envrc", ".bash_aliases", ".zshenv", ".zlogin", "pkgbuild", "apkbuild"].includes(lower)
    || lower === ".env" || lower.startsWith(".env.")) return "shell";
  const byName = FILENAME_LANGUAGES[lower];
  if (byName) return byName;
  const dot = lower.lastIndexOf(".");
  if (dot <= 0 || dot === lower.length - 1) return null;
  const extension = lower.slice(dot + 1);
  if (["org", "org2", "md", "markdown", "csv", "tsv", "canvas", "pdf"].includes(extension)) return null;
  return ALIASES[extension] ?? null;
}

/**
 * Highlighter language for editing a file as source text. Unlike
 * `codeLanguageForPath`, Markdown counts as source here; Org documents keep
 * their own editor semantics and return null.
 */
export function sourceLanguageForPath(filePath: string | undefined | null): string | null {
  const base = String(filePath ?? "").split(/[\\/]/).pop() ?? "";
  const lower = base.toLowerCase();
  const extension = lower.includes(".") ? lower.slice(lower.lastIndexOf(".") + 1) : "";
  if (["org", "org2"].includes(extension)) return null;
  if (["md", "markdown", "mdx", "mkd", "rmd", "qmd"].includes(extension)) return "markdown";
  return codeLanguageForPath(filePath);
}

/** Every canonical language the highlighter supports. */
export function supportedCodeLanguages(): string[] {
  return Object.keys(SPECS).sort();
}

export interface CodeLanguageTableEntry {
  lineComments?: string[];
  blockComments?: Array<[string, string]>;
  strings?: string[];
  multilineStrings?: string[];
  rawStrings?: string[];
  keywords?: string[];
  literals?: string[];
  types?: string[];
  caseInsensitive?: boolean;
  capitalizedTypes?: boolean;
  decorators?: boolean;
  shellVariables?: boolean;
  keysBeforeColon?: boolean;
  preprocessor?: boolean;
  markup?: boolean;
  plainWords?: boolean;
  identifierChars?: string;
  lineRules?: Array<{ pattern: string; kind: CodeTokenKind }>;
  inlineRules?: Array<{ pattern: string; kind: CodeTokenKind }>;
}

export interface CodeLanguageTable {
  schema: "org2:code-language-table:v1";
  languages: Record<string, CodeLanguageTableEntry>;
  aliases: Record<string, string>;
  filenames: Record<string, string>;
}

/**
 * The language definitions as JSON, so native editors tokenize with the same
 * vocabulary as the shared renderer. Regular expressions are exported as
 * ICU-compatible pattern strings.
 */
export function codeLanguageTable(): CodeLanguageTable {
  const languages: Record<string, CodeLanguageTableEntry> = {};
  for (const name of Object.keys(SPECS).sort()) {
    const spec = SPECS[name]!;
    const entry: CodeLanguageTableEntry = {};
    for (const key of ["lineComments", "blockComments", "strings", "multilineStrings", "rawStrings", "keywords", "literals", "types"] as const) {
      const value = spec[key];
      if (value && value.length) (entry as Record<string, unknown>)[key] = value;
    }
    for (const key of ["caseInsensitive", "capitalizedTypes", "decorators", "shellVariables", "keysBeforeColon", "preprocessor", "markup", "plainWords"] as const) {
      if (spec[key]) entry[key] = true;
    }
    if (spec.identifierChars) entry.identifierChars = spec.identifierChars.source;
    if (spec.lineRules?.length) entry.lineRules = spec.lineRules.map(({ pattern, kind }) => ({ pattern: anchored(pattern).source, kind }));
    if (spec.inlineRules?.length) entry.inlineRules = spec.inlineRules.map(({ pattern, kind }) => ({ pattern: pattern.source, kind }));
    languages[name] = entry;
  }
  return {
    schema: "org2:code-language-table:v1",
    languages,
    aliases: Object.fromEntries(Object.entries(ALIASES).sort(([a], [b]) => a.localeCompare(b))),
    filenames: Object.fromEntries(Object.entries(FILENAME_LANGUAGES).sort(([a], [b]) => a.localeCompare(b))),
  };
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
  const lineRules = (spec.lineRules ?? []).map(({ pattern, kind }) => ({ pattern: anchored(pattern), kind }));
  const inlineRules = (spec.inlineRules ?? []).map(({ pattern, kind }) => ({ pattern: sticky(pattern), kind }));
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

    if (atLineStart && lineRules.length) {
      const end = source.indexOf("\n", i);
      const rest = source.slice(i, end < 0 ? length : end);
      const rule = lineRules.find(({ pattern }) => pattern.test(rest));
      if (rule) {
        const match = rule.pattern.exec(rest)![0];
        if (match) {
          push(match, rule.kind);
          i += match.length;
          continue;
        }
      }
    }
    if (inlineRules.length) {
      let matched = false;
      for (const rule of inlineRules) {
        rule.pattern.lastIndex = i;
        const match = rule.pattern.exec(source);
        if (match && match[0]) {
          push(match[0], rule.kind);
          i += match[0].length;
          matched = true;
          break;
        }
      }
      if (matched) continue;
    }

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

    if (spec.plainWords) {
      let j = i + 1;
      while (j < length && /[A-Za-z0-9_]/.test(source[j - 1]!) && /[A-Za-z0-9_]/.test(source[j]!)) j++;
      push(source.slice(i, j));
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

function anchored(pattern: RegExp): RegExp {
  const source = pattern.source.startsWith("^") ? pattern.source : `^(?:${pattern.source})`;
  return new RegExp(source, pattern.flags.replace(/[gy]/g, ""));
}

function sticky(pattern: RegExp): RegExp {
  return new RegExp(pattern.source, `${pattern.flags.replace(/[gy]/g, "")}y`);
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
