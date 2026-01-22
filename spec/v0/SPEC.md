# Org2 Specification v0 (Draft)

This is the initial, intentionally-scoped Org2 specification.

The primary goal of v0 is to define a **lossless, round-trippable parse** of Org-like documents into a **canonical AST**.

## Scope

**In scope (normative)**
- Input text → canonical AST
- Canonical AST schema and invariants
- Normative fixtures: `.org` input → `.json` AST output

**Out of scope (explicit, non-normative for v0)**
- TODO workflow semantics (syntax may be parsed, semantics are out of scope)
- Agenda behavior
- Clocking
- Property inheritance
- Export rules
- Editor behavior / UI

## Specification Model

Org2 is specified in layers:

### Layer 1: Syntax → Canonical AST (normative)

A compliant implementation MUST:
- Parse a document into the **canonical AST** described by `canonical-ast.schema.json`.
- Preserve enough information to **round-trip** to the original bytes (modulo a future, explicitly-defined normalization layer).

The authoritative definition of correctness is:
- The **canonical AST schema**: `canonical-ast.schema.json`
- The **normative fixtures** in `tests/`

A grammar (Tree-sitter, PEG, etc.) is recommended, but is not itself authoritative; it is an implementation detail as long as it produces the canonical AST.

### Layer 2: Semantic modules (future, normative, scoped)

Semantics are defined as independent modules that operate on the canonical AST.

Examples (not yet specified):
- `org2-sem-todo`
- `org2-sem-time`
- `org2-sem-properties`
- `org2-sem-links`

An implementation may support any subset of modules, but MUST be explicit about which modules (and which versions) it supports.

## Versioning

- This directory is `spec/v0/`.
- Additive, backwards-compatible changes MAY be made within v0 as patch revisions.
- Breaking changes MUST be done in a new spec version directory (e.g. `spec/v1/`).

## Normative fixtures

Fixtures live in `tests/`:
- `NNNN-*.org` is the input
- `NNNN-*.json` is the canonical AST output

Implementations SHOULD run these fixtures as golden tests.

## Headlines (subheadings)

### Headline syntax

A **headline line** is a line that matches:

- One or more `*` characters at the start of the line.
- Exactly one space after the `*` run.
- A non-empty title string after that space.

A headline line produces a `Headline` node with:

- `level`: the number of `*` characters.
- `title`: an array of inline nodes, parsed using the same inline rules as paragraphs (timestamps, links, emphasis, etc.).

### TODO keywords (syntax only)

A headline title MAY begin with a TODO keyword.

In v0, the only supported TODO keyword is `TODO`.

Example:
- `* TODO Fix bug` produces a `Headline` with `todo: "TODO"` and `title: "Fix bug"`.

TODO workflow semantics are out of scope for v0.

### Tags (syntax only)

A headline title MAY end with a tag group:
- tag group syntax is `:tag1:tag2:`
- it MUST appear at the end of the headline
- tags MUST NOT contain whitespace

Example:
- `* Plan release :ops:launch:` produces `tags: ["ops", "launch"]` and `title: "Plan release"`.

### Headline nesting

Headlines form a tree via their `children` arrays.

When a headline of level `L` is parsed:

- It becomes a child of the nearest preceding headline whose level is **strictly less than** `L`.
- If there is no preceding headline with level `< L`, the headline becomes a direct child of the `Document`.
- All subsequent non-headline nodes (e.g. paragraphs) attach to the most recent headline (at any level) until a new headline changes the current container.

### Level skips

Level skips are allowed and deterministic.

For example, a level-3 headline (`***`) immediately after a level-1 headline (`*`) becomes a child of that level-1 headline; no implicit level-2 headline nodes are created.

## Property drawers (syntax only)

Property drawers are supported as a structural syntax element.

Property inheritance and other property semantics are out of scope for v0.

## Generic drawers

Generic drawers are supported as a structural syntax element.

A **drawer** begins with a line of the form `:NAME:` (where `NAME` contains no whitespace or `:`) and ends with a line exactly equal to `:END:`.

Generic drawers MUST be represented as `Drawer` nodes and preserved losslessly.

### Property drawer syntax

A property drawer is a block consisting of:

- A start line exactly equal to `:PROPERTIES:`
- Zero or more property lines
- An end line exactly equal to `:END:`

Property drawers produce a `PropertyDrawer` node.

### Property line syntax

A property line MUST match:

- A leading `:`
- A non-empty key (no whitespace, no `:`)
- A `:`
- Optionally a single space
- The value (possibly empty)

Example:

- `:ID: abc123` produces `{ key: "ID", value: "abc123" }`

Property drawers may appear as children of `Headline` nodes (and implementations MAY also support them at document level).

## Directives (unknown #+... lines)

Org2 v0 supports preserving directive lines that begin with `#+` but are not otherwise recognized as:
- keyword lines (`#+KEY: VALUE`), or
- structural blocks (e.g. `#+begin_src` ... `#+end_src`)

Such lines MUST be represented as `DirectiveLine` nodes and preserved losslessly.

## Comment lines

A **comment line** is any line that begins with `#` but does not begin with `#+`.

Comment lines MUST be represented as `CommentLine` nodes and preserved losslessly.

## Comment blocks

Comment blocks are supported as a block syntax element.

A **comment block** begins with `#+begin_comment` and ends with `#+end_comment`.

Comment blocks MUST be represented as `Block` nodes with `kind: "comment"` and preserved losslessly.

## SOURCE blocks (#+begin_src / #+end_src)

Source blocks are supported as a structural syntax element.

Executing source blocks and interpreting header args (babel semantics) are out of scope for v0.

## Tables (pipe tables)

Org2 v0 supports Org-mode style **pipe tables**.

### Table row syntax

A **table row line** is a line that:

- Begins with `|` (optionally after indentation spaces), and
- Ends with `|` (ignoring trailing whitespace).

The bytes between pipes are treated as **raw cell strings**.

A table row line produces a `TableRow` node with:

- `cells`: an array of strings, where each string is the raw byte sequence between separators.

Examples:

- `|a|b|` → `cells: ["a", "b"]`
- `| a | b |` → `cells: [" a ", " b "]`
- `||` → `cells: [""]`
- `|a||b|` → `cells: ["a", "", "b"]`

### Hline row syntax

A **table hline row line** is a table row line where, after trimming leading/trailing whitespace, the line matches:

- `|` followed by one or more `-` or `+` characters, followed by `|`

Example:
- `|---+---|` produces a `TableHline` node.

### Table grouping and termination

A `Table` node spans one or more consecutive table row lines and/or hline row lines.

The parser MUST terminate a `Table` at the first subsequent line that is not a table row line.

### SOURCE block syntax

A source block is a block consisting of:

- A begin line matching `#+begin_src` (case-insensitive), with optional indentation.
- Zero or more body lines (treated as raw text).
- An end line matching `#+end_src` (case-insensitive), with optional indentation.

The parser MUST treat the body as raw text until it encounters an end marker line.

### Lossless capture

A `SrcBlock` node MUST capture enough information to reproduce the exact original bytes of:

- The begin marker line (indentation, keyword spelling, and all bytes after the keyword).
- The block body (all bytes between the end of the begin marker line and the start of the end marker line).
- The end marker line (indentation, keyword spelling, and all bytes after the keyword).

In v0, the canonical AST captures begin/end marker lines as:

- `begin.indent`, `begin.keywordRaw`, `begin.afterKeywordRaw`
- `end.indent`, `end.keywordRaw`, `end.afterKeywordRaw`

### Unterminated blocks

If a begin marker is not terminated by a matching end marker before end-of-file, the parser MUST emit a `SrcBlock` node with:

- `terminated: false`
- `end` omitted
- `bodyRaw` containing all remaining bytes until end-of-file

## Timestamps (dates)

Org2 v0 supports capturing Org-mode timestamp/date syntax in a **lossless** form.

Timestamp semantics (agenda scheduling, recurrence evaluation, and normalizing day-of-week strings) are out of scope for v0.

### Timestamp syntax

A **timestamp** is an inline construct with one of two delimiters:

- **Active**: `<...>`
- **Inactive**: `[...]`

A timestamp MUST begin (inside the delimiters) with a date prefix:

- `YYYY-MM-DD` (exactly 4 digits, `-`, 2 digits, `-`, 2 digits)

All bytes inside the delimiters after the date prefix are treated as raw content (may include day-of-week, time, repeaters, warnings, etc.).

Examples:

- `<2026-01-16 Fri>`
- `[2026-01-16 Fri]`
- `<2026-01-16 Fri 13:45>`
- `<2026-01-16 Fri 10:00-11:00>`
- `<2026-01-16 Fri +1w -2d>`

### Timestamp ranges

Org supports expressing ranges between two timestamps.

In v0, a **timestamp range** is captured as a single inline node containing:

- `start`: a `Timestamp`
- `separatorRaw`: the exact bytes between the end of the start timestamp and the beginning of the end timestamp
- `end`: a `Timestamp`

The reference parser recognizes ranges when two timestamps are separated by `--`, optionally with spaces.

Examples:

- `<2026-01-16 Fri>--<2026-01-18 Sun>`
- `<2026-01-16 Fri> -- <2026-01-18 Sun>`

## Inline emphasis (bold/italic/underline/strike/verbatim/code)

Org2 v0 supports a limited, “80% coverage” subset of Org inline emphasis.

### Markers

The following emphasis markers are recognized:

- `*...*` → `kind: "bold"`
- `/.../` → `kind: "italic"`
- `_..._` → `kind: "underline"`
- `+...+` → `kind: "strike"`
- `=...=` → `kind: "verbatim"`
- `~...~` → `kind: "code"`

Each emphasized span produces an `Emphasis` inline node:

- `type: "Emphasis"`
- `kind`: one of the above
- `marker`: the opening/closing marker character
- `content`: the raw inner bytes (v0: a string; no inline children)

### Boundary rules (v0)

Emphasis is only recognized when it is bounded such that it is unlikely to match “inside words”.

An emphasis span starting at byte index `i` with marker `M` is valid iff:

- Opening marker `M` is preceded by a boundary (start-of-string, whitespace, or non-word character).
- The byte after opening marker is not whitespace.
- A matching closing marker `M` exists later on the same line.
- The byte before the closing marker is not whitespace.
- The byte after the closing marker is a boundary (end-of-string, whitespace, or non-word character).

For v0, “word character” means ASCII `[A-Za-z0-9]`.

### Nesting

Nesting is not supported in v0. Any marker bytes inside `content` are treated as plain text.

## Links (v0)

Org2 v0 supports a limited subset of Org links as inline nodes.

### Bracket links

A **bracket link** is an inline construct with the form:

- `[[TARGET]]`
- `[[TARGET][DESCRIPTION]]`

The canonical AST emits a `Link` inline node with:

- `format: "bracket"`
- `raw`: the exact matched bytes (including brackets)
- `targetRaw`: the raw target payload
- `descriptionRaw` (optional): the raw description payload

### Plain URLs

A **plain URL** is recognized when it begins with `http://` or `https://` and extends until the next whitespace.

To reduce accidental captures, the reference parser trims common trailing punctuation characters from the URL.

### Parsing order (deterministic disambiguation)

When parsing inline content, the parser applies transformations in a deterministic order to avoid ambiguities:

1. **Timestamps** are recognized first (both active and inactive)
2. **Bracket links** are recognized next (before emphasis)
3. **Plain URLs** are recognized (before emphasis)
4. **Emphasis** markers are recognized last, respecting boundary rules

This order ensures that:
- Links take precedence over emphasis (e.g., `[[url][*text*]]` parses as a link, not emphasis within a link)
- URLs are not split by emphasis markers
- Timestamps are not confused with emphasis markers
- Boundary rules are consistently applied

Within emphasis parsing, all marker types (`*`, `/`, `_`, `+`, `=`, `~`) are processed with equal priority, processing left-to-right as they appear on the line.

## Keyword lines (#+KEY: VALUE)

Org2 v0 supports capturing file-level keyword/metadata lines as explicit nodes.

A **keyword line** matches:

- Optional indentation
- `#+`
- a key token (captured as `keyRaw`)
- `:`
- the remainder of the line (captured as `valueRaw`, including any leading space)

Keyword lines produce a `KeywordLine` node with a lossless `raw` field.

## Planning lines (SCHEDULED:/DEADLINE:/CLOSED:)

Org2 v0 recognizes planning lines as explicit nodes:

- `SCHEDULED: ...`
- `DEADLINE: ...`
- `CLOSED: ...`

Planning lines produce a `Planning` node with:

- `kind`: `SCHEDULED`, `DEADLINE`, or `CLOSED`
- `raw`: the exact original line
- `timestamp` (optional): the first timestamp or timestamp range found in the remainder

Planning semantics are out of scope for v0.

## Common blocks (example/quote/verse/center)

Org2 v0 supports parsing common block types as a lossless structural node.

Recognized begin/end pairs (case-insensitive keyword matching is NOT required in v0 for these blocks):

- `#+begin_example` / `#+end_example`
- `#+begin_quote` / `#+end_quote`
- `#+begin_verse` / `#+end_verse`
- `#+begin_center` / `#+end_center`

Each produces a `Block` node with:

- `kind`: one of `example|quote|verse|center`
- `terminated`: whether a matching end marker was found
- `begin` / `end`: captured as `indent`, `keywordRaw`, `afterKeywordRaw`
- `bodyRaw`: raw bytes between begin and end lines
