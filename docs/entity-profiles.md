# Entity profiles and alias resolution

`org2 compile corpus` builds first-class entity profiles alongside the node, backlink, relation, and lookup indexes.

An entity is any file or heading with either:

- `:ORG2_ENTITY_TYPE:` / `:ENTITY_TYPE:` property, or
- a `:type_person:`, `:type_company:`, `:type_project:`, etc. tag.

Aliases come from `#+ROAM_ALIASES:` and `:ROAM_ALIASES:`. Wiki links such as `[[Sonatype Inc]]` resolve through the canonical title and aliases when the alias maps to exactly one entity.

## CLI

```sh
org2 entity show "Sonatype" --dir notes --recursive
org2 entity show "Sonatype Inc" --dir notes --format json
```

Profiles include:

- canonical name, type, aliases, and backing node keys
- backlinks and alias mentions with file/line provenance
- relationship edges from explicit `ORG2_RELATION_*` properties and supported source-agnostic inference
- durable facts from properties with provenance
- `reviewNeeded` entries for conflicting facts or ambiguous aliases

Conflicting facts are not silently overwritten. If two backing nodes assert different values for the same fact key, both values are preserved and the profile reports a `conflicting-fact` review item.

Agent context packs include matching entity profile summaries when a selected note belongs to an entity or when the query exactly matches an entity alias.
