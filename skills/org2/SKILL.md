---
name: org2
description: Work safely with an Org2 or OpenOrg corpus using its installed CLI or MCP server. Use for corpus search and context, Org/Org2 document edits, agenda and TODO work, durable runs and workflows, approvals, publishing, or corpus health checks.
---

# Org2

Treat ordinary `.org` and `.org2` files as the source of truth. Derived indexes, views, app state, run projections, and generated artifacts are secondary.

## Start with discovery

1. Identify the authorized corpus root. Do not infer access to another corpus from app history or nearby folders.
2. Run `org2 agent capabilities` before relying on remembered commands.
3. Read the nearest `org2.json` for corpus identity, agenda selection, ignored paths, publishing projects, and other declared behavior.
4. Prefer MCP resources and typed tools when the harness already exposes the Org2 MCP server. Start retrieval with `org2_search`, `org2_fetch`, or `org2_context`; their results are bounded and preserve citations. Use bounded CLI JSON for capabilities that MCP does not expose.

For retrieval, start with `org2 agent search`, `org2 agent context`, or `org2 agent fetch`. Keep file paths, line ranges, IDs, provenance, and uncertainty in the result.

## Native tooling and capability gaps

Use Org2's native CLI by default for Org/Org2 operations such as search, agenda, TODOs, links, tables, export, and validation. Prefer exposed Org2 workspace/MCP tools for operations they support; client-required effective-text reads and reviewed writes take precedence over shell access. Discover commands with `org2 agent capabilities` and `org2 COMMAND --help` before choosing a workaround. Org2 is an independent runtime: a .org file does not imply GNU Org semantics or an Emacs dependency.

Do not invoke `emacs`, `emacsclient`, batch Emacs Lisp, or an Emacs Org exporter as an implicit fallback. Do not assume Emacs is installed, probe for it, or install it for ordinary Org2 work. Use Emacs only when the user explicitly requests an Emacs-specific task. This does not prohibit other tools for work outside Org2's scope.

If a native operation appears missing or broken, check the installed version, capabilities, and relevant help first. Distinguish a missing executable, permission restriction, or unavailable tool from a confirmed Org2 capability gap; do not bypass access or review boundaries. State the exact limitation and use a small, supported, reviewable alternative when available. Never silently substitute GNU Org behavior or execute preserved unsupported formulas or source blocks. If this is authorized OpenOrg/Org2 development with repository access, reproduce and fix the shortcoming and add a focused regression test. Otherwise, suggest opening an issue at https://github.com/aviaviavi/org2/issues and prepare a sanitized report with the version, command/tool, minimal input, expected and actual behavior, and workaround. Do not publish an issue or private corpus content without the user's authorization. If shell execution is unavailable, use the exposed tools and explain any remaining limitation rather than inventing command results.

## Make reviewable changes

- Preserve Org syntax and make the smallest useful plaintext edit.
- New human-authored documents use `.org`; existing `.org2` files remain supported and should not be renamed implicitly.
- Do not write generated Backlinks sections. Backlinks are computed views.
- Preview mutating commands first. Add `--apply` only after inspecting the exact target and proposed change.
- Keep raw imports under `raw/` and generated or review-required work under `views/` or `compiled/` until it is promoted deliberately.
- Preserve stable `ID`, `AGENT_REF`, `GOAL_REF`, source citations, hashes, review state, and approval identity. Never guess a portable agent or goal reference.
- Never store credentials or secret values in corpus files. Configuration may name an environment variable or machine-local profile, not its value.

Use `org2 run` for delegated work that must be resumable, reviewable, or auditable. Attach artifacts and validations, stop at approval boundaries, and complete a run with a concise reviewer-facing summary. Use `org2 workflow` only when a successful process should become reusable.

## Validate proportionally

After edits, run a focused check such as:

```sh
org2 lint --dir /path/to/corpus --recursive --format json
org2 graph audit --dir /path/to/corpus --recursive --format json
```

Use command-specific JSON or a targeted preview when a full lint or graph audit would be disproportionate. Report the files changed, the validation performed, and anything still awaiting review.
