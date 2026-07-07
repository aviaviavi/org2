# macOS Editor Direction

## Problem

The SwiftUI rendered block editor has been carrying too much responsibility. It is useful as a structured reading, review, and workflow surface, but trying to make every rendered block behave like a full native text editor has produced fragile cursor, selection, autosave, and inline-editing behavior.

Org2's source of truth is still ordinary text files. The macOS app should reinforce that model instead of creating a second editor semantics layer in SwiftUI.

## North Star

The primary writing experience in the macOS app should feel like a fast native text editor with Org2-aware affordances layered on top:

- Source text remains the authoritative editable buffer.
- The editor should use native text editing behavior for cursor movement, selection, undo, keyboard input, and save semantics.
- Org2 semantics should come from the shared parser/runtime wherever practical.
- Rendered views should stay excellent for reading, reviewing, navigation, approvals, agenda actions, folding, and structured mutations.
- Raw/source editing is the full-fidelity escape hatch and should become the default writing surface until the rendered editor is proven reliable.

## Short-Term Plan

Make source editing the normal edit path from rendered views:

- The toolbar Edit command opens the source editor for the current entry or page.
- Editing from a rendered block opens the source editor with the caret near that block's source range.
- Rendered rows select, navigate, fold, and expose actions, but single-click text editing is disabled.
- Direct rendered text editors are disabled for headings, paragraphs, and list items.
- Existing structural commands such as insert, move, delete, TODO changes, planning changes, and property edits continue to mutate source text through the store.
- Keep legacy block editing code available for narrow structural internals and tests while it is being retired from normal UI entry points.

## Medium-Term Plan

Harden the source editor into the first-class writing surface:

- Improve `OrgSyntaxTextEditor` around large files, selection preservation, undo grouping, and incremental syntax highlighting.
- Add source-editor commands for Org2 actions that users expect from org-mode-style editing: heading/list insertion, promote/demote, TODO cycling, planning/property shortcuts, folding, and link insertion.
- Use parser-provided ranges and diagnostics for semantic highlighting, navigation, and structured commands.
- Keep save behavior boring: Command-S writes exactly the visible buffer, autosave never overwrites newer local text, and background reloads never replace active edits.
- Add focused regression tests for source-editor entry from agenda, approvals, rendered rows, and full-page files.

## Longer-Term Options

After the source editor is solid, richer rendering can return as overlays and sidecars rather than as the authoritative text input path:

- Gutter controls for TODOs, priorities, scheduling, backlinks, and block actions.
- Inline previews for links, images, source blocks, citations, and generated artifacts.
- Optional rendered/read mode that remains separate from the active text buffer.
- Selective hybrid widgets only where they do not fight native text editing behavior.
