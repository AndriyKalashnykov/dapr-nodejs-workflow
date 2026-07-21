# Vendored: C4-PlantUML

Third-party files, copied verbatim — **do not edit them**. Change the diagrams in
`docs/diagrams/*.puml` instead.

|          |                                                                                                                                      |
| -------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| Upstream | <https://github.com/plantuml-stdlib/C4-PlantUML>                                                                                     |
| Version  | `v2.11.0` (pinned as `C4_PLANTUML_VERSION` in the `Makefile`)                                                                        |
| License  | MIT — © Ricardo Niepel and C4-PlantUML contributors ([LICENSE](https://github.com/plantuml-stdlib/C4-PlantUML/blob/v2.11.0/LICENSE)) |
| Files    | `C4.puml` (leaf), `C4_Context.puml`, `C4_Container.puml`                                                                             |

## Why these are vendored rather than `!include`d over HTTPS

A remote `!include https://raw.githubusercontent.com/...` is fetched **on every
render**. GitHub rate-limits shared CI-runner IPs, and an HTTP 429 fails
`make diagrams-check` — which gates `main` through `static-check` → `ci-pass`. That
turns a third-party rate limit into a red default branch on a coin flip. Vendoring
removes the network from the render path entirely.

## The `-DRELATIVE_INCLUDE=.` flag is required

These files guard their own internal includes with:

```
!if %variable_exists("RELATIVE_INCLUDE")
  !include ./C4.puml
!else
  !include https://raw.githubusercontent.com/.../C4.puml
!endif
```

Without the flag they take the `!else` branch and fetch remotely **anyway**, making
the vendoring silently pointless. An in-file `!define RELATIVE_INCLUDE` does _not_
satisfy `%variable_exists` — it must be a `-D` CLI argument, which the `Makefile`
render recipe passes.

Proof it is effective: `make diagrams-offline` renders every diagram under
`docker run --network none`.

## Updating

```bash
# 1. bump C4_PLANTUML_VERSION in the Makefile
make vendor-diagrams   # re-download the pinned closure
make diagrams          # re-render
# 2. commit the vendored sources AND the regenerated PNGs together
```

Deliberately **not** Renovate-tracked: a bump the bot can neither re-vendor nor
re-render would sit as a permanently red PR under this repo's automerge — the same
reasoning that keeps `PLANTUML_VERSION` untracked (see `CLAUDE.md`).

If you add a diagram that uses a C4 level not vendored here (Component, Deployment),
add that file to the list in the `vendor-diagrams` target and re-run it — and check
its `!include` closure first, since each level includes the one below it.
