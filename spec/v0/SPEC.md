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
- `title`: an array of inline nodes (v0: a single `Text` node containing the title string).

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
