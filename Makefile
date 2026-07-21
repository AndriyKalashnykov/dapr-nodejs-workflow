.DEFAULT_GOAL := help

# Recipes use `set -euo pipefail` (pipefail is a bash builtin; dash, the default
# /bin/sh on Ubuntu, rejects it). Required by the mermaid-lint target.
SHELL := /bin/bash

# mise itself installs to $HOME/.local/bin/mise via the https://mise.run
# bootstrap; its shims (where act, dapr, gitleaks, hadolint, trivy live) are in
# $HOME/.local/share/mise/shims. Export both so recipes find mise-managed tools
# regardless of whether the user has `mise activate` in their shell — also
# needed inside the act runner container where neither path is preconfigured.
export PATH := $(HOME)/.local/share/mise/shims:$(HOME)/.local/bin:$(PATH)

APP_NAME       := dapr-nodejs-workflow
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")

# Load operator overrides from .env (gitignored) BEFORE the `?=` defaults below,
# so `.env` is authoritative for `make` targets too — not just for compose (which
# auto-loads it). A value set in .env wins; with no .env the `?=` defaults apply.
# Keep .env to simple `KEY=value` lines (copy from .env.example) — no quotes,
# no spaces around `=`, and escape any literal `$` as `$$` (Make expands `$`).
-include .env

# --- Network / hosts ---
# All recipes route through $(HOST); override for non-local targets.
HOST                ?= localhost

# --- Service ports (from the README "Service Ports" table) ---
# Override-friendly so tests / parallel runs can pick alternative ports.
# Note: trailing-comment form (`VAR ?= 3000 # …`) leaks the inline whitespace
# into the value on some make versions — keep comments on separate lines.
PORT                ?= 3000
DAPR_HTTP_PORT      ?= 3500
DAPR_GRPC_PORT      ?= 50001
DAPR_SCHEDULER_PORT ?= 50006
POSTGRES_PORT       ?= 5432
REDIS_PORT          ?= 6379
# Host port the prod image binds for e2e + smoke + DAST.
TEST_HOST_PORT      ?= 3100

# Host ports the compose stack (`make up`) binds; `check-ports` guards them.
COMPOSE_PORTS       := $(POSTGRES_PORT) $(REDIS_PORT)
# Host ports the app + Dapr sidecar bind (`make start`/`start-bg`/`ci-dapr-start`).
RUN_PORTS           := $(PORT) $(DAPR_HTTP_PORT) $(DAPR_GRPC_PORT)
# The set `check-ports` probes; overridable per flow (up → compose ports,
# start → run ports) via `$(MAKE) check-ports CHECK_PORTS="..."`.
CHECK_PORTS         ?= $(COMPOSE_PORTS)

# --- Readiness timeouts / poll cadence (seconds) ---
# Mirror .env.example; `?=` lets the env / `.env` / CI override each knob.
POSTGRES_READY_TIMEOUT  ?= 60
REDIS_READY_TIMEOUT     ?= 30
SERVER_READY_TIMEOUT    ?= 15
DAPR_READY_TIMEOUT      ?= 30
DAPR_GRPC_READY_TIMEOUT ?= 15
# Image boot-marker poll (e2e / smoke / dast): attempts x interval.
BOOT_POLL_ATTEMPTS      ?= 30
BOOT_POLL_INTERVAL      ?= 1
# Boot-marker deadline (docker-smoke-test) and workflow settle wait (check-workflow).
BOOT_MARKER_TIMEOUT     ?= 30
WORKFLOW_SETTLE_SECONDS ?= 5

# --- Identifiers and paths ---
# Dapr app-id (also the `make stop` lookup key).
APP_ID              ?= workflow-api
# Local dev / CI Dapr components.
COMPONENTS_PATH     ?= ./components
CI_COMPONENTS_PATH  ?= ./dapr/ci
# Runtime-rendered component dirs (gitignored). The committed components pin the
# default DB host-ports; `render-components` substitutes $(POSTGRES_PORT)/$(REDIS_PORT)
# into a runtime copy so an operator override (e.g. running alongside another
# Postgres already on 5432) actually reaches the Dapr sidecar. Dapr component
# metadata has no {env:VAR} tag (only {uuid}/{podName}/{namespace}/{appID}), so
# the value must be rendered at `dapr run` time, not referenced.
RUN_COMPONENTS_DIR    := .dapr-run/components
RUN_CI_COMPONENTS_DIR := .dapr-run/ci-components

# --- Pinned tool versions ---
# Language toolchains + CLI tools (node, pnpm, act, dapr, gitleaks, hadolint,
# trivy) live in .mise.toml / .nvmrc — one source of truth, tracked natively by
# Renovate's mise manager. Only Docker-image tags and the Dapr *runtime* version
# (not a mise-installable CLI) are pinned here.
NODE_VERSION     := $(shell cat .nvmrc 2>/dev/null || echo 24)
# renovate: datasource=github-releases depName=dapr/dapr
DAPR_RUNTIME_VERSION := 1.18.1
# renovate: datasource=docker depName=minlag/mermaid-cli
MERMAID_CLI_VERSION := 11.16.0
# PlantUML renderer for the C4 architecture diagrams (docs/diagrams/*.puml).
# Deliberately NOT Renovate-tracked: the committed PNGs are a generated artifact
# guarded by `make diagrams-check`, and the hosted Renovate app cannot run
# `make diagrams` to regenerate them — so under this repo's automerge a bump PR
# would sit permanently RED on the drift gate. Bump manually (see CLAUDE.md
# "Upgrade Backlog"): edit the tag, run `make diagrams`, commit source + PNGs.
PLANTUML_VERSION := 1.2026.6
# ZAP is consumed ONLY as the container image ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION)
# (dast targets), never as a binary — so track the CONSUMED SINK (the ghcr tag)
# via datasource=docker, not github-releases. github-releases can lead the
# registry (release cut before the :2.x.0 image is pushed), opening a bump PR
# whose image 404s. ghcr tags are bare (2.17.0), so no extractVersion is needed.
# renovate: datasource=docker depName=ghcr.io/zaproxy/zaproxy
ZAP_VERSION      := 2.17.0
# renovate: datasource=npm depName=depcheck
DEPCHECK_VERSION := 1.4.7
# Runner image for local `act` runs (ci-run/ci-run-tag). Pins the Ubuntu major so
# act can't silently jump to a new runner OS. catthehacker rebuilds the floating
# act-24.04 tag weekly; versioning=regex tracks ONLY the act-<major>.<minor> form
# (not the dated act-24.04-YYYYMMDD tags), so Renovate bumps it only on a real OS
# change. The Makefile+docker pinDigests:false rule already exempts it from pinning.
# renovate: datasource=docker depName=catthehacker/ubuntu versioning=regex:^act-(?<major>\d+)\.(?<minor>\d+)$
ACT_UBUNTU_VERSION := act-24.04
# Renovate CLI for the local `renovate` / `renovate-validate` dev targets only.
# Pinned here (not in .mise.toml) so `mise install` / `make deps` never eagerly
# fetches its 600+ npm packages; the targets install it lazily via `mise exec`.
# renovate: datasource=npm depName=renovate
RENOVATE_VERSION := 43.263.3

# Container CLI: prefer docker, fall back to podman (local dev uses podman).
DOCKER ?= $(shell command -v docker 2>/dev/null || command -v podman 2>/dev/null || echo docker)
IMAGE_NAME := $(APP_NAME)
IMAGE_TAG  ?= $(CURRENTTAG)
IMAGE      := $(IMAGE_NAME):$(IMAGE_TAG)

# Use --frozen-lockfile in CI for reproducible installs; allow lockfile updates locally.
PNPM_INSTALL := pnpm install $(if $(CI),--frozen-lockfile,)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-28s\033[0m - %s\n", $$1, $$2}'

#deps: @ Check and install required dependencies (mise-managed toolchain + CLIs; podman, git)
deps:
	@echo "Checking dependencies..."
	@# mise bootstraps every pinned tool in one step: Node (from .nvmrc), pnpm,
	@# act, dapr, gitleaks, hadolint, trivy (all from .mise.toml).
	@# CI runners use jdx/mise-action to install mise; local dev bootstraps it here.
	@if [ -z "$$CI" ] && ! command -v mise >/dev/null 2>&1; then \
		echo "Installing mise (no root required, installs to ~/.local/bin)..."; \
		curl -fsSL https://mise.run | sh; \
		echo ""; \
		echo "mise installed. Activate it in your shell, then re-run 'make deps':"; \
		echo "  bash: echo 'eval \"\$$(~/.local/bin/mise activate bash)\"' >> ~/.bashrc"; \
		echo "  zsh:  echo 'eval \"\$$(~/.local/bin/mise activate zsh)\"'  >> ~/.zshrc"; \
		exit 0; \
	fi
	@if command -v mise >/dev/null 2>&1; then \
		mise install; \
	else \
		command -v node >/dev/null 2>&1 || { echo "ERROR: node required but mise is not installed"; exit 1; }; \
		command -v pnpm >/dev/null 2>&1 || { echo "ERROR: pnpm required but mise is not installed"; exit 1; }; \
	fi
	@if [ -z "$$CI" ]; then \
		command -v podman >/dev/null 2>&1 || { \
			echo "ERROR: Podman is required. Install from https://podman.io/getting-started/installation"; exit 1; \
		}; \
	fi
	@command -v git >/dev/null 2>&1 || { \
		echo "ERROR: Git is required. Install from https://git-scm.com/downloads"; exit 1; \
	}
	@# Soft checks — convenience/CI targets use these but each has a graceful fallback.
	@command -v python3 >/dev/null 2>&1 || echo "Note: python3 not found — check-workflow/check-db JSON pretty-printing is skipped (raw output still shown)."
	@command -v nc >/dev/null 2>&1 || echo "Note: nc not found — ci-dapr-start's sidecar readiness probe falls back to a fixed wait."
	@echo "All dependencies checked."

#clean: @ Remove build artifacts and node_modules
clean:
	@rm -rf node_modules/ dist/ zap-output/

#install: @ Install npm dependencies (uses --frozen-lockfile when CI=true)
install: deps
	@$(PNPM_INSTALL)

#build: @ Build TypeScript to dist/
build: install
	@pnpm build

#format: @ Auto-fix formatting with Prettier
format: install
	@pnpm exec prettier --write .

#format-check: @ Check formatting without modifying files
format-check: install
	@pnpm exec prettier --check .

#lint: @ Run Prettier check, ESLint, TypeScript noEmit, and hadolint
lint: install
	@pnpm exec prettier --check .
	@pnpm exec eslint --max-warnings 0 src/
	@pnpm exec tsc --noEmit
	@hadolint Dockerfile

#vulncheck: @ Audit dependencies for known vulnerabilities
vulncheck: install
	@pnpm audit --audit-level=moderate

#secrets: @ Scan for hardcoded secrets with gitleaks
secrets: deps
	@gitleaks detect --source . --verbose --redact --no-banner

#trivy-fs: @ Scan filesystem for vulnerabilities, secrets, and misconfigurations
trivy-fs: deps
	@trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH .

#deps-prune: @ Show unused/redundant Node.js dependencies
deps-prune: install
	@echo "Checking for unused Node.js packages..."
	@npx --yes depcheck@$(DEPCHECK_VERSION) --ignores="@types/*,eslint,prettier,typescript,vitest,vite,@eslint/js,typescript-eslint" || true

#deps-prune-check: @ Verify no prunable dependencies (CI gate)
deps-prune-check: install
	@npx --yes depcheck@$(DEPCHECK_VERSION) --ignores="@types/*,eslint,prettier,typescript,vitest,vite,@eslint/js,typescript-eslint" --quiet \
		|| { echo "ERROR: unused dependencies found. Run 'make deps-prune' to see them."; exit 1; }

# --- Architecture diagrams (PlantUML C4) ---
# C4-PlantUML stdlib version, VENDORED under docs/diagrams/C4-PlantUML/ (not fetched
# at render time). A remote `!include https://raw.githubusercontent.com/...` is pulled
# on EVERY render, and GitHub rate-limits shared CI-runner IPs — an HTTP 429 then fails
# `diagrams-check`, which gates `main` via static-check -> ci-pass. Vendoring removes
# that flake class entirely. Re-download with `make vendor-diagrams` after bumping.
C4_PLANTUML_VERSION := v2.11.0
DIAGRAM_DIR   := docs/diagrams
DIAGRAM_SRC   := $(wildcard $(DIAGRAM_DIR)/*.puml)
DIAGRAM_OUT   := $(patsubst $(DIAGRAM_DIR)/%.puml,$(DIAGRAM_DIR)/out/%.png,$(DIAGRAM_SRC))
# Version-stamped sentinel: a PLANTUML_VERSION bump changes the stamp's NAME, so
# the previous stamp no longer satisfies the prereq and every PNG re-renders.
# Without it, `make diagrams` would no-op on a renderer bump (no .puml changed)
# and diagrams-check would pass on stale PNGs. Gitignored (a trigger, not an artifact).
DIAGRAM_STAMP := $(DIAGRAM_DIR)/out/.plantuml-$(PLANTUML_VERSION).stamp

#diagrams: @ Render PlantUML C4 architecture diagrams (docs/diagrams/*.puml) to PNG
diagrams: $(DIAGRAM_OUT)

$(DIAGRAM_DIR)/out/%.png: $(DIAGRAM_DIR)/%.puml $(DIAGRAM_STAMP)
	@command -v $(DOCKER) >/dev/null 2>&1 || { echo "ERROR: $(DOCKER) is not on PATH (needed to pull plantuml/plantuml)"; exit 1; }
	@mkdir -p $(DIAGRAM_DIR)/out
	@# -DRELATIVE_INCLUDE=. is REQUIRED, not cosmetic. The vendored C4-PlantUML files
	@# guard their own internal includes with `!if %variable_exists("RELATIVE_INCLUDE")`;
	@# without the flag they take the !else branch and fetch C4.puml from
	@# raw.githubusercontent.com anyway, so the vendoring would be silently pointless.
	@# An in-file `!define RELATIVE_INCLUDE` does NOT satisfy %variable_exists — it must
	@# be a -D CLI argument. Proof it works: `make diagrams-offline` renders with no network.
	@# JAVA_TOOL_OPTIONS (standard JVMTI var) over _JAVA_OPTIONS (HotSpot-proprietary);
	@# user.home must be redirected or the JRE writes a font cache into the mounted repo
	@# (the container UID has no /etc/passwd entry, so Java resolves user.home to "?").
	@# PLANTUML_LIMIT_SIZE raises the 4096px canvas ceiling: past it PlantUML SILENTLY
	@# truncates content off the right edge with no error. Widest render today is 1536px,
	@# so this is a backstop against a future wide diagram losing its legend unnoticed.
	$(DOCKER) run --rm -v "$(CURDIR)/$(DIAGRAM_DIR):/work" -w /work \
		--user $$(id -u):$$(id -g) \
		-e HOME=/tmp -e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
		-e PLANTUML_LIMIT_SIZE=16384 \
		plantuml/plantuml:$(PLANTUML_VERSION) \
		-DRELATIVE_INCLUDE=. -tpng -o out $(notdir $<)

#diagrams-offline: @ Prove the vendored C4-PlantUML includes need no network (--network none)
diagrams-offline:
	@rm -f $(DIAGRAM_DIR)/out/*.png
	@for f in $(notdir $(DIAGRAM_SRC)); do \
		$(DOCKER) run --rm --network none -v "$(CURDIR)/$(DIAGRAM_DIR):/work" -w /work \
			--user $$(id -u):$$(id -g) \
			-e HOME=/tmp -e JAVA_TOOL_OPTIONS=-Duser.home=/tmp \
			-e PLANTUML_LIMIT_SIZE=16384 \
			plantuml/plantuml:$(PLANTUML_VERSION) \
			-DRELATIVE_INCLUDE=. -tpng -o out $$f || exit 1; \
	done
	@echo "diagrams-offline: rendered with NO network — vendoring is effective."

#vendor-diagrams: @ Re-download the pinned C4-PlantUML stdlib into docs/diagrams/C4-PlantUML/
vendor-diagrams:
	@# Deliberately NOT Renovate-tracked: a bump the bot cannot re-vendor AND re-render
	@# would be a standing red PR under this repo's automerge (same reasoning as
	@# PLANTUML_VERSION — see CLAUDE.md). Bump C4_PLANTUML_VERSION here, run this, then
	@# `make diagrams` and commit the sources + regenerated PNGs together.
	@mkdir -p $(DIAGRAM_DIR)/C4-PlantUML
	@for f in C4 C4_Context C4_Container; do \
		curl -sfo "$(DIAGRAM_DIR)/C4-PlantUML/$$f.puml" \
			"https://raw.githubusercontent.com/plantuml-stdlib/C4-PlantUML/$(C4_PLANTUML_VERSION)/$$f.puml" \
			|| { echo "ERROR: failed to fetch $$f.puml at $(C4_PLANTUML_VERSION)"; exit 1; }; \
		echo "  vendored $$f.puml"; \
	done

$(DIAGRAM_STAMP):
	@mkdir -p $(DIAGRAM_DIR)/out
	@rm -f $(DIAGRAM_DIR)/out/.plantuml-*.stamp
	@touch $@

#diagrams-clean: @ Remove rendered diagram artefacts
diagrams-clean:
	@rm -rf $(DIAGRAM_DIR)/out

#diagrams-check: @ Verify committed diagrams match current PlantUML source (CI drift gate)
diagrams-check: diagrams
	@# Two-part predicate, NOT `git status --porcelain`. This gate runs inside
	@# static-check -> `make ci`, which the workflow runs BEFORE committing. Porcelain
	@# reports a correctly-staged render as `M `/`A ` = dirty, so it FALSE-FAILS the
	@# normal flow (edit .puml -> make diagrams -> git add both -> make ci -> commit)
	@# with the misleading "not updated/committed" message. Demonstrated: source+render
	@# both staged and matching -> porcelain form exited 2.
	@#   git diff --exit-code   -> RED if the re-render MODIFIED a tracked PNG (stale
	@#                             committed output, incl. a staged-old PNG whose index
	@#                             copy differs from the fresh worktree render).
	@#   git ls-files --others  -> RED if a render is UNTRACKED (new .puml whose PNG was
	@#                             never `git add`ed) — closes the blind spot bare
	@#                             `git diff` has on its own.
	@# A staged render that matches the fresh output is invisible to both => GREEN.
	@git diff --exit-code -- $(DIAGRAM_DIR)/out >/dev/null 2>&1 || { \
		echo "ERROR: committed PNG is stale — run 'make diagrams' and commit."; \
		git diff --stat -- $(DIAGRAM_DIR)/out; \
		exit 1; }
	@U=$$(git ls-files --others --exclude-standard -- $(DIAGRAM_DIR)/out); \
	[ -z "$$U" ] || { \
		echo "ERROR: rendered output not committed/staged:"; \
		echo "$$U"; \
		exit 1; }

#mermaid-lint: @ Validate Mermaid diagrams in README.md and CLAUDE.md via pinned mermaid-cli
mermaid-lint: deps
	@command -v $(DOCKER) >/dev/null 2>&1 || { echo "ERROR: $(DOCKER) is not on PATH (needed to pull minlag/mermaid-cli)"; exit 1; }
	@set -euo pipefail; \
	MD_FILES=$$(grep -lF '```mermaid' README.md CLAUDE.md 2>/dev/null || true); \
	if [ -z "$$MD_FILES" ]; then \
		echo "No Mermaid blocks found — skipping."; \
		exit 0; \
	fi; \
	IMAGE=minlag/mermaid-cli:$(MERMAID_CLI_VERSION); \
	for attempt in 1 2 3; do \
		if $(DOCKER) pull --quiet "$$IMAGE" >/dev/null 2>&1; then break; fi; \
		if [ "$$attempt" -eq 3 ]; then \
			echo "ERROR: $(DOCKER) pull $$IMAGE failed after 3 attempts (registry flake or rate limit)"; \
			exit 1; \
		fi; \
		delay=$$((attempt * 5)); \
		echo "  ! pull failed (attempt $$attempt/3); retrying in $${delay}s..."; \
		sleep "$$delay"; \
	done; \
	FAILED=0; \
	for md in $$MD_FILES; do \
		echo "Validating Mermaid blocks in $$md..."; \
		LOG=$$(mktemp); \
		if $(DOCKER) run --rm -v "$$PWD:/data:ro" \
			"$$IMAGE" \
			-i "/data/$$md" -o "/tmp/$$(basename $$md .md).svg" >"$$LOG" 2>&1; then \
			echo "  ✓ All blocks rendered cleanly."; \
		else \
			echo "  ✗ Parse error in $$md:"; \
			sed 's/^/    /' "$$LOG"; \
			FAILED=$$((FAILED + 1)); \
		fi; \
		rm -f "$$LOG"; \
	done; \
	if [ "$$FAILED" -gt 0 ]; then \
		echo "Mermaid lint: $$FAILED file(s) had parse errors."; \
		exit 1; \
	fi

#components-check: @ Fail if local and CI Dapr component YAMLs drift in structure (password/comments allowed)
components-check:
	@set -eu; fail=0; tmp_local=$$(mktemp); tmp_ci=$$(mktemp); \
	trap 'rm -f "$$tmp_local" "$$tmp_ci"' EXIT; \
	for f in components/*.yaml; do \
		base=$$(basename "$$f"); ci="dapr/ci/$$base"; \
		if [ ! -f "$$ci" ]; then echo "FAIL: $$ci is missing (counterpart of $$f)"; fail=1; continue; fi; \
		sed -E -e 's/#.*$$//' -e 's/[[:space:]]+$$//' -e 's/postgres:[^@]+@/postgres:***@/' "$$f"  | awk 'NF' > "$$tmp_local"; \
		sed -E -e 's/#.*$$//' -e 's/[[:space:]]+$$//' -e 's/postgres:[^@]+@/postgres:***@/' "$$ci" | awk 'NF' > "$$tmp_ci"; \
		if ! cmp -s "$$tmp_local" "$$tmp_ci"; then \
			echo "FAIL: $$f and $$ci differ beyond allowed fields (password / comments)"; \
			diff "$$tmp_local" "$$tmp_ci" || true; \
			fail=1; \
		fi; \
	done; \
	if [ "$$fail" -eq 0 ]; then echo "components-check passed."; fi; \
	exit $$fail

#check-node-alignment: @ Fail if the Node major drifts across .nvmrc, .mise.toml, and Dockerfile
check-node-alignment:
	@set -euo pipefail; \
	ref="$(NODE_VERSION)"; \
	mise=$$(sed -nE 's/^node = "([0-9]+).*/\1/p' .mise.toml); \
	df_slim=$$(sed -nE 's/^FROM node:([0-9]+).*/\1/p' Dockerfile | head -1); \
	df_distroless=$$(sed -nE 's#.*distroless/nodejs([0-9]+).*#\1#p' Dockerfile | head -1); \
	fail=0; \
	for pair in ".mise.toml=$$mise" "Dockerfile(node)=$$df_slim" "Dockerfile(distroless)=$$df_distroless"; do \
		name=$${pair%%=*}; val=$${pair#*=}; \
		if [ "$$val" != "$$ref" ]; then echo "FAIL: Node major in $$name ($$val) != .nvmrc ($$ref)"; fail=1; fi; \
	done; \
	if [ "$$fail" -eq 0 ]; then echo "check-node-alignment: Node major $$ref aligned across .nvmrc, .mise.toml, Dockerfile."; fi; \
	exit $$fail

#static-check: @ Composite quality gate (check-node-alignment + lint + vulncheck + secrets + trivy-fs + deps-prune-check + components-check + render-check + diagrams-check + mermaid-lint)
static-check: check-node-alignment lint vulncheck secrets trivy-fs deps-prune-check components-check render-check diagrams-check mermaid-lint
	@echo "Static check passed."

#test: @ Run unit tests
test: install
	@pnpm exec vitest run

#test-watch: @ Run unit tests in watch mode
test-watch: install
	@pnpm exec vitest

# Locally, auto-provision infra + backgrounded sidecar before the suite. In CI the
# workflow provisions its own PostgreSQL service container + sidecar (ci-dapr-start)
# and podman/compose isn't on the runner, so skip up/start-bg when CI is set.
ifndef CI
integration-test: up start-bg
endif

#integration-test: @ Run integration tests (locally auto-provisions infra + backgrounded Dapr sidecar; CI provisions its own)
integration-test: install
	@pnpm exec vitest run --config vitest.integration.config.ts
	@if [ -z "$$CI" ]; then \
		echo ""; \
		echo "Integration tests done. The backgrounded stack is still up — 'make stop' + 'make down' to clean up."; \
	fi

#smoke: @ HTTP smoke test against built server (no Dapr)
smoke: build
	@$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(PORT)"
	@trap 'kill $$SERVER_PID 2>/dev/null || true' EXIT; \
	node dist/api-server.js & SERVER_PID=$$!; \
	echo "Waiting for server on $(HOST):$(PORT)..."; \
	timeout $(SERVER_READY_TIMEOUT) bash -c 'until curl -sf http://$(HOST):$(PORT)/ > /dev/null; do sleep $(BOOT_POLL_INTERVAL); done' || { echo "Server failed to start"; exit 1; }; \
	echo "Server is up, running smoke tests..."; \
	curl -sf http://$(HOST):$(PORT)/ | grep -q "Dapr Workflow API" || { echo "Health check failed"; exit 1; }; \
	echo "Smoke tests passed"

#check: @ Run full local verification (static-check, test, build) — static-check runs lint which runs prettier --check
check: static-check test build

#update: @ Update dependencies to latest allowed versions
update: deps
	@pnpm update

#upgrade: @ Upgrade dependencies to latest versions (ignoring ranges)
upgrade: deps
	@pnpm upgrade

#check-ports: @ Fail early (naming the offending container) if a bound port would collide (CHECK_PORTS overridable)
check-ports:
	@# bash `/dev/tcp` connect = "something is listening" (SHELL is bash). No `set -e`:
	@# a free port makes the connect fail, which is the expected/normal case.
	@# Default set is the compose ports; `start`/`start-bg`/`ci-dapr-start` override
	@# CHECK_PORTS with the app + sidecar ports ($(RUN_PORTS)).
	@set -uo pipefail; conflict=0; \
	for p in $(CHECK_PORTS); do \
		if (exec 3<>/dev/tcp/$(HOST)/$$p) 2>/dev/null; then \
			exec 3>&- 2>/dev/null || true; \
			holder=$$( { docker ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null; \
			             podman ps --format '{{.Names}}|{{.Ports}}' 2>/dev/null; } \
			           | grep -E ":$$p->" | cut -d'|' -f1 | paste -sd, - ); \
			[ -n "$$holder" ] || holder="a non-container process (see: ss -ltnp 'sport = :$$p')"; \
			echo "ERROR: port $$p is already in use by: $$holder"; \
			conflict=1; \
		fi; \
	done; \
	if [ "$$conflict" -ne 0 ]; then \
		echo ""; \
		echo "Free the port(s) above (e.g. stop that container), or export an"; \
		echo "alternative for the relevant *_PORT to a free value, e.g.:"; \
		echo "    export POSTGRES_PORT=<free> REDIS_PORT=<free>   # compose (make up)"; \
		echo "    export PORT=<free> DAPR_HTTP_PORT=<free> DAPR_GRPC_PORT=<free>  # app+sidecar (make start)"; \
		exit 1; \
	fi; \
	echo "check-ports: ports $(CHECK_PORTS) are free."

#up: @ Start PostgreSQL and Redis via Podman Compose
up:
	@if podman compose ps --format '{{.State}}' 2>/dev/null | grep -q running; then \
		echo "Infrastructure is already running."; \
	else \
		$(MAKE) --no-print-directory check-ports || exit 1; \
		POSTGRES_PORT=$(POSTGRES_PORT) REDIS_PORT=$(REDIS_PORT) podman compose up -d; \
		echo "Waiting for PostgreSQL to accept connections..."; \
		timeout $(POSTGRES_READY_TIMEOUT) bash -c 'until podman compose exec -T postgres pg_isready >/dev/null 2>&1; do sleep $(BOOT_POLL_INTERVAL); done' \
			|| { echo "ERROR: PostgreSQL did not become ready within 60s:"; podman compose ps; exit 1; }; \
		echo "Waiting for Redis to accept connections..."; \
		timeout $(REDIS_READY_TIMEOUT) bash -c 'until [ "$$(podman compose exec -T redis redis-cli ping 2>/dev/null | tr -d "[:space:]")" = PONG ]; do sleep $(BOOT_POLL_INTERVAL); done' \
			|| { echo "ERROR: Redis did not become ready within 30s"; exit 1; }; \
		echo "Infrastructure is ready."; \
	fi

#down: @ Stop infrastructure services and remove containers
down:
	@podman compose down

#postgres-start: @ Start only PostgreSQL via Podman Compose (env-driven; alt to `make up`)
postgres-start:
	@if podman compose ps postgres --format '{{.State}}' 2>/dev/null | grep -q running; then \
		echo "PostgreSQL is already running."; \
	else \
		$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(POSTGRES_PORT)" || exit 1; \
		POSTGRES_PORT=$(POSTGRES_PORT) podman compose up -d postgres; \
		echo "Waiting for PostgreSQL to accept connections..."; \
		timeout $(POSTGRES_READY_TIMEOUT) bash -c 'until podman compose exec -T postgres pg_isready >/dev/null 2>&1; do sleep $(BOOT_POLL_INTERVAL); done' \
			|| { echo "ERROR: PostgreSQL did not become ready within $(POSTGRES_READY_TIMEOUT)s"; podman compose ps; exit 1; }; \
		echo "PostgreSQL is ready on $(HOST):$(POSTGRES_PORT)."; \
	fi

#postgres-stop: @ Stop the PostgreSQL Compose service
postgres-stop:
	@podman compose stop postgres 2>/dev/null || echo "PostgreSQL service is not running."

#dapr-init: @ Initialize Dapr (pinned runtime; locally stops a conflicting Redis on $(REDIS_PORT) first)
dapr-init: deps
	@# `dapr init` brings up its own Redis on :6379. Locally a podman-compose
	@# Redis from `make up` may already hold the port; stop it before init.
	@# Skip in CI (no podman, port unowned).
	@if [ -z "$$CI" ] && podman ps -q --filter "publish=$(REDIS_PORT)" 2>/dev/null | grep -q .; then \
		echo "Stopping container on port $(REDIS_PORT) to free it for dapr init..."; \
		podman stop $$(podman ps -q --filter "publish=$(REDIS_PORT)"); \
	fi
	@# `dapr init` docker-pulls daprio/dapr + redis + zipkin from Docker Hub and
	@# binds FIXED host ports (placement metrics :59090, scheduler :50006/:59091,
	@# redis :6379, zipkin :9411). On CI runners it occasionally fails — an
	@# anonymous Docker Hub pull reset, OR "failed to bind host port for
	@# 0.0.0.0:50006: address already in use" from a dapr_* container leaked by a
	@# prior attempt whose port hadn't released yet. A single retry with a short
	@# sleep is not enough (the port can still be held); use a 3-attempt backoff
	@# with a growing wait after the uninstall + stale-container sweep so the bind
	@# port fully releases between attempts. Locally, run a plain init so a dev's
	@# Dapr is left intact. (Mirrors the ci-dapr-start retry form.)
	@if [ -n "$$CI" ]; then \
		for attempt in 1 2 3; do \
			if dapr init --runtime-version $(DAPR_RUNTIME_VERSION); then break; fi; \
			if [ "$$attempt" -eq 3 ]; then \
				echo "ERROR: dapr init failed after 3 attempts (Docker Hub pull reset or host-port bind race)"; \
				exit 1; \
			fi; \
			delay=$$((attempt * 5)); \
			echo "  ! dapr init failed (attempt $$attempt/3); cleaning up, retrying in $${delay}s..."; \
			dapr uninstall 2>/dev/null || true; \
			docker rm -f $$(docker ps -aq --filter "name=dapr_") 2>/dev/null || true; \
			sleep "$$delay"; \
		done; \
	else \
		dapr init --runtime-version $(DAPR_RUNTIME_VERSION); \
	fi

# $(call render_components,<src-dir>,<dst-dir>) — copy the components, substituting
# the DB host-ports with $(POSTGRES_PORT)/$(REDIS_PORT). Matched by position
# (`@localhost:<port>/` for the Postgres binding url; `value: localhost:<port>` for
# the Redis host) so there is NO hardcoded default-port literal in the substitution.
define render_components
rm -rf "$(2)"; mkdir -p "$(2)"; \
for f in "$(1)"/*.yaml; do \
	sed -e 's#@localhost:[0-9][0-9]*/#@localhost:$(POSTGRES_PORT)/#g' \
	    -e 's#value: localhost:[0-9][0-9]*#value: localhost:$(REDIS_PORT)#g' \
	    "$$f" > "$(2)/$$(basename "$$f")"; \
done
endef

#render-components: @ Render runtime Dapr components with the current $(POSTGRES_PORT)/$(REDIS_PORT)
render-components:
	@$(call render_components,$(COMPONENTS_PATH),$(RUN_COMPONENTS_DIR))

#render-ci-components: @ Render CI Dapr components with the current $(POSTGRES_PORT)/$(REDIS_PORT)
render-ci-components:
	@$(call render_components,$(CI_COMPONENTS_PATH),$(RUN_CI_COMPONENTS_DIR))

#render-check: @ Gate: assert render-components actually substitutes the DB host-port into the Dapr components
render-check:
	@set -eu; tmp=$$(mktemp -d); trap 'rm -rf "$$tmp"' EXIT; fail=0; \
	$(MAKE) --no-print-directory render-components POSTGRES_PORT=15432 REDIS_PORT=16379 RUN_COMPONENTS_DIR="$$tmp" >/dev/null; \
	grep -q '@localhost:15432/' "$$tmp/postgres.yaml" || { echo "FAIL: Postgres host-port not substituted into the binding url"; fail=1; }; \
	grep -q 'value: localhost:16379' "$$tmp/redis.yaml" || { echo "FAIL: Redis host-port not substituted into redisHost"; fail=1; }; \
	grep -q ':daprrulz@' "$$tmp/postgres.yaml" || { echo "FAIL: Postgres password dropped by the render"; fail=1; }; \
	if grep -qE 'localhost:(5432|6379)' "$$tmp"/*.yaml; then echo "FAIL: a default port survived the override render"; fail=1; fi; \
	[ "$$fail" -eq 0 ] && echo "render-check passed (POSTGRES_PORT/REDIS_PORT reach the rendered components)." || { echo "render-check FAILED"; exit 1; }

#start: @ Build and start the API server with Dapr sidecar
start: build render-components
	@$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(RUN_PORTS)"
	@DAPR_HOST=$(HOST) DAPR_GRPC_PORT=$(DAPR_GRPC_PORT) DAPR_HTTP_PORT=$(DAPR_HTTP_PORT) \
	dapr run \
		--app-id $(APP_ID) \
		--app-port $(PORT) \
		--app-protocol http \
		--dapr-grpc-port $(DAPR_GRPC_PORT) \
		--dapr-http-port $(DAPR_HTTP_PORT) \
		--scheduler-host-address $(HOST):$(DAPR_SCHEDULER_PORT) \
		--resources-path $(RUN_COMPONENTS_DIR) \
		-- node dist/api-server.js

#start-bg: @ Build and start the API server + Dapr sidecar in the BACKGROUND (used by integration-test)
start-bg: build render-components
	@# Idempotent: if a sidecar is already answering (e.g. a foreground `make start`
	@# in another terminal), reuse it instead of starting a second one.
	@if curl -sf -m 2 http://$(HOST):$(DAPR_HTTP_PORT)/v1.0/healthz >/dev/null 2>&1; then \
		echo "Dapr sidecar already running on $(HOST):$(DAPR_HTTP_PORT) — reusing it."; \
		exit 0; \
	fi; \
	$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(RUN_PORTS)" || exit 1; \
	DAPR_HOST=$(HOST) DAPR_GRPC_PORT=$(DAPR_GRPC_PORT) DAPR_HTTP_PORT=$(DAPR_HTTP_PORT) \
	nohup dapr run \
		--app-id $(APP_ID) \
		--app-port $(PORT) \
		--app-protocol http \
		--dapr-grpc-port $(DAPR_GRPC_PORT) \
		--dapr-http-port $(DAPR_HTTP_PORT) \
		--scheduler-host-address $(HOST):$(DAPR_SCHEDULER_PORT) \
		--resources-path $(RUN_COMPONENTS_DIR) \
		-- node dist/api-server.js > /tmp/dapr-run-local.log 2>&1 & \
	echo "Waiting for Dapr sidecar on $(HOST):$(DAPR_HTTP_PORT)..."; \
	timeout $(DAPR_READY_TIMEOUT) bash -c 'until curl -sf http://$(HOST):$(DAPR_HTTP_PORT)/v1.0/healthz >/dev/null; do sleep $(BOOT_POLL_INTERVAL); done' \
		|| { echo "ERROR: Dapr sidecar did not become ready. Is Dapr initialized? Run 'make dapr-init' once."; \
		     echo "=== dapr run log ==="; cat /tmp/dapr-run-local.log; exit 1; }; \
	echo "Waiting for API server on $(HOST):$(PORT)..."; \
	timeout $(SERVER_READY_TIMEOUT) bash -c 'until curl -sf http://$(HOST):$(PORT)/ >/dev/null; do sleep $(BOOT_POLL_INTERVAL); done' \
		|| { echo "Server failed to start"; tail -20 /tmp/dapr-run-local.log; exit 1; }; \
	echo "Dapr sidecar and API server are ready."

#stop: @ Stop the Dapr sidecar and API server
stop:
	@RESULT=$$(dapr stop --app-id $(APP_ID) 2>&1); \
	if echo "$$RESULT" | grep -q "couldn't find app id"; then \
		echo "App $(APP_ID) is not running."; \
	else \
		echo "$$RESULT"; \
	fi

#start-no-dapr: @ Build and start the API server without Dapr sidecar
start-no-dapr: build
	@PORT=$(PORT) node dist/api-server.js

#run: @ Build and start the API server without Dapr sidecar (alias for start-no-dapr)
run: start-no-dapr

#check-workflow: @ Trigger a test workflow and print the result
check-workflow:
	@echo "Scheduling workflow..."
	@RESP=$$(curl -s -X POST http://$(HOST):$(PORT)/process-payload \
		-H "Content-Type: application/json" \
		-d '{"name":"Test","data":{"key":"value"}}'); \
	echo "Response: $$RESP"; \
	ID=$$(echo "$$RESP" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); \
	if [ -z "$$ID" ]; then echo "Server not responding on $(HOST):$(PORT) (is it running with Dapr?)"; \
	else \
	echo "Workflow ID: $$ID"; \
	echo "Waiting $(WORKFLOW_SETTLE_SECONDS)s before polling status..."; \
	sleep $(WORKFLOW_SETTLE_SECONDS); \
	STATUS=$$(curl -s "http://$(HOST):$(PORT)/workflow/$$ID/status"); \
	echo "$$STATUS" | python3 -m json.tool 2>/dev/null || echo "$$STATUS"; \
	fi

#check-db: @ Run the database health check endpoint
check-db:
	@RESP=$$(curl -s --connect-timeout 5 http://$(HOST):$(PORT)/db-health); \
	if [ -z "$$RESP" ]; then echo "Server not responding on $(HOST):$(PORT) (is it running with Dapr?)"; \
	else echo "$$RESP" | python3 -m json.tool 2>/dev/null || echo "$$RESP"; fi

#check-version: @ Ensure VERSION variable is set and valid semver (vX.Y.Z)
check-version:
ifndef VERSION
	$(error VERSION is undefined. Usage: make release VERSION=v1.0.0)
endif
	@echo "$(VERSION)" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$$' \
		|| { echo "ERROR: VERSION must match semver format vX.Y.Z (got: $(VERSION))"; exit 1; }
	@echo -n ""

#release: @ Create and push a release tag (requires VERSION=vX.Y.Z)
release: check-version tag-release

#tag-release: @ Create and push a new git tag
tag-release: check-version
	@# Fail BEFORE the commit if the tag already exists locally or on origin —
	@# otherwise `git commit -a` lands a "Cut vX release" commit and the later
	@# `git tag` aborts, leaving a dangling commit and a half-published release.
	@if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1; then \
		echo "ERROR: tag ${VERSION} already exists locally. Pick a new version or delete it:  git tag -d ${VERSION}"; \
		exit 1; \
	fi
	@if git ls-remote --exit-code --tags origin "refs/tags/${VERSION}" >/dev/null 2>&1; then \
		echo "ERROR: tag ${VERSION} already exists on origin. Pick a new version."; \
		exit 1; \
	fi
	@echo -n "Are you sure to create and push ${VERSION} tag? [y/N] " && read ans && [ $${ans:-N} = y ]
	@# Tolerate a clean tree: `git commit -a` exits non-zero on "nothing to
	@# commit", which would abort the release before the tag is ever created.
	@if [ -n "$$(git status --porcelain)" ]; then \
		git commit -a -s -m "Cut ${VERSION} release"; \
	else \
		echo "Working tree clean — tagging current HEAD without a release commit."; \
	fi
	@git tag ${VERSION}
	@git push origin ${VERSION}
	@git push
	@echo "Done."

# === Docker image targets ===

#image-build: @ Build production Docker image (multi-stage)
image-build: build
	@$(DOCKER) build -t $(IMAGE) .

#image-run: @ Run Docker image standalone (no Dapr)
image-run: image-stop
	@$(DOCKER) run --rm -d --name $(IMAGE_NAME) -p $(PORT):3000 $(IMAGE)
	@echo "Container started -> http://$(HOST):$(PORT)"

#image-stop: @ Stop Docker image container
image-stop:
	@$(DOCKER) rm -f $(IMAGE_NAME) >/dev/null 2>&1 || true

#image-structure-test: @ Assert the built image's structure (non-root user, entrypoint, files) via container-structure-test
image-structure-test: image-build
	@container-structure-test test --image $(IMAGE) --config container-structure-test.yaml

#e2e-compose: @ E2E for docker-compose.yaml config: boot the stack, assert Postgres seeded+queryable and Redis round-trips, tear down
e2e-compose:
	@$(MAKE) --no-print-directory check-ports
	@DOCKER="$(DOCKER)" POSTGRES_PORT="$(POSTGRES_PORT)" REDIS_PORT="$(REDIS_PORT)" \
		POSTGRES_READY_TIMEOUT="$(POSTGRES_READY_TIMEOUT)" REDIS_READY_TIMEOUT="$(REDIS_READY_TIMEOUT)" \
		BOOT_POLL_INTERVAL="$(BOOT_POLL_INTERVAL)" ./e2e/e2e-compose.sh

#e2e: @ End-to-end test of the production Docker image
e2e: image-build
	@$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(TEST_HOST_PORT)"
	@SVC=$(IMAGE_NAME)-e2e; \
	trap "$(DOCKER) rm -f $$SVC >/dev/null 2>&1 || true" EXIT; \
	echo "Starting container $$SVC on $(HOST):$(TEST_HOST_PORT)..."; \
	$(DOCKER) run -d --name $$SVC -p $(TEST_HOST_PORT):3000 $(IMAGE) >/dev/null; \
	echo "Waiting for HTTP..."; \
	for i in $$(seq 1 $(BOOT_POLL_ATTEMPTS)); do \
		curl -sf "http://$(HOST):$(TEST_HOST_PORT)/" >/dev/null 2>&1 && break; \
		sleep $(BOOT_POLL_INTERVAL); \
		[ "$$i" -eq $(BOOT_POLL_ATTEMPTS) ] && { echo "Container failed to start:"; $(DOCKER) logs $$SVC; exit 1; }; \
	done; \
	echo ""; \
	echo "[1/3] GET / (health endpoint)"; \
	BODY=$$(curl -sf "http://$(HOST):$(TEST_HOST_PORT)/"); \
	echo "  body: $$BODY"; \
	echo "$$BODY" | grep -q "Dapr Workflow API" || { echo "FAIL: unexpected body"; exit 1; }; \
	echo "  PASS"; \
	echo ""; \
	echo "[2/3] POST /process-payload (expect Dapr unreachable error)"; \
	HTTP=$$(curl -s -o /tmp/e2e-resp.json -w "%{http_code}" -X POST \
		"http://$(HOST):$(TEST_HOST_PORT)/process-payload" \
		-H "Content-Type: application/json" \
		-d '{"name":"e2e-test","data":{"key":"value"}}'); \
	echo "  HTTP $$HTTP"; \
	cat /tmp/e2e-resp.json; echo; \
	echo "$$HTTP" | grep -q '^5' || { echo "FAIL: expected 5xx, got $$HTTP"; exit 1; }; \
	grep -qi "dapr\|sidecar" /tmp/e2e-resp.json || { echo "FAIL: error should mention Dapr sidecar"; exit 1; }; \
	echo "  PASS"; \
	echo ""; \
	echo "[3/3] Container logs sanity"; \
	$(DOCKER) logs $$SVC 2>&1 | grep -q "REST API server running" || { echo "FAIL: server start banner missing"; exit 1; }; \
	echo "  PASS"; \
	echo ""; \
	echo "e2e tests passed"

#e2e-dapr: @ Full-stack e2e: run production image + Dapr sidecar, assert workflow COMPLETED
e2e-dapr: image-build render-components
	@IMAGE=$(IMAGE) DOCKER=$(DOCKER) HOST=$(HOST) RESOURCES_PATH=$(RUN_COMPONENTS_DIR) \
		./e2e/e2e-dapr.sh

#e2e-durability: @ Workflow replay e2e: kill the app mid-flight and assert the workflow still COMPLETES
e2e-durability: image-build render-components
	@IMAGE=$(IMAGE) DOCKER=$(DOCKER) HOST=$(HOST) RESOURCES_PATH=$(RUN_COMPONENTS_DIR) \
		./e2e/e2e-durability.sh

#docker-smoke-test: @ Boot-marker smoke test: start smoke-test container, wait for boot. Leaves container running for DAST (CI)
docker-smoke-test:
	@set -eu; \
	docker run -d --name smoke-test -p $(TEST_HOST_PORT):3000 $(IMAGE_NAME):scan; \
	deadline=$$(($$(date +%s) + $(BOOT_MARKER_TIMEOUT))); \
	while [ $$(date +%s) -lt $$deadline ]; do \
		if docker logs smoke-test 2>&1 | grep -qE 'REST API server running|listening on|started on port'; then \
			echo "PASS: container booted successfully"; \
			exit 0; \
		fi; \
		sleep $(BOOT_POLL_INTERVAL); \
	done; \
	echo "FAIL: container did not boot within $(BOOT_MARKER_TIMEOUT)s"; \
	docker logs smoke-test; \
	exit 1

#dast-scan: @ Run ZAP baseline scan against an already-running container on $(HOST):$(TEST_HOST_PORT) (CI)
dast-scan:
	@set -eu; \
	WORK="$${GITHUB_WORKSPACE:-$$PWD}"; \
	rm -rf "$$WORK/zap-output" 2>/dev/null \
		|| docker run --rm --user 0 -v "$$WORK:/work" -w /work --entrypoint rm ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) -rf zap-output; \
	mkdir -p "$$WORK/zap-output"; \
	chmod 777 "$$WORK/zap-output"; \
	docker run --rm --network host \
		-v "$$WORK/zap-output:/zap/wrk:rw" \
		ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) \
		zap-baseline.py \
			-t http://$(HOST):$(TEST_HOST_PORT) \
			-I \
			-r zap-report.html \
			-J zap-report.json \
			-w zap-report.md

#docker-verify-manifest: @ Assert a published image has linux/amd64 and zero unknown/unknown entries (CI)
docker-verify-manifest:
	@set -eu; \
	test -n "$(IMAGE_REF)" || { echo "ERROR: IMAGE_REF is required (e.g., make docker-verify-manifest IMAGE_REF=ghcr.io/owner/repo:1.0.0)"; exit 1; }; \
	MANIFEST=$$(docker buildx imagetools inspect "$(IMAGE_REF)"); \
	echo "$$MANIFEST"; \
	if echo "$$MANIFEST" | grep -q 'unknown/unknown'; then \
		echo "FAIL: image contains unknown/unknown entries (attestations leaked?)"; \
		exit 1; \
	fi; \
	if docker buildx imagetools inspect "$(IMAGE_REF)" --raw | grep -q '"manifests"'; then \
		PLATFORMS=$$(echo "$$MANIFEST" | grep -oE 'linux/[a-z0-9]+'); \
	else \
		PLATFORMS=$$(docker buildx imagetools inspect "$(IMAGE_REF)" --format '{{.Image.OS}}/{{.Image.Architecture}}'); \
	fi; \
	echo "Platform(s): $$PLATFORMS"; \
	if ! echo "$$PLATFORMS" | grep -q 'linux/amd64'; then \
		echo "FAIL: linux/amd64 platform missing"; \
		exit 1; \
	fi; \
	echo "PASS: image manifest verified (linux/amd64)"

#dast: @ ZAP baseline DAST scan against the built image
dast: image-build
	@$(DOCKER) rm -f $(IMAGE_NAME)-dast 2>/dev/null || true
	@$(MAKE) --no-print-directory check-ports CHECK_PORTS="$(TEST_HOST_PORT)"
	@$(DOCKER) run -d --name $(IMAGE_NAME)-dast -p $(TEST_HOST_PORT):3000 $(IMAGE) >/dev/null
	@echo "Waiting for container to become healthy..."
	@for i in $$(seq 1 $(BOOT_POLL_ATTEMPTS)); do \
		curl -sf http://$(HOST):$(TEST_HOST_PORT)/ >/dev/null 2>&1 && break; \
		sleep $(BOOT_POLL_INTERVAL); \
		[ "$$i" -eq $(BOOT_POLL_ATTEMPTS) ] && { echo "Container failed to start"; $(DOCKER) logs $(IMAGE_NAME)-dast; $(DOCKER) rm -f $(IMAGE_NAME)-dast; exit 1; }; \
	done
	@# ZAP's container writes into the bind mount as root, so a stale zap-output
	@# from a prior run is root-owned — a later `chmod`/`rm` by the host user then
	@# fails with "Operation not permitted". Remove it first (falling back to a
	@# root container when the host user can't), then recreate it user-owned so
	@# `chmod 777` succeeds and `make clean` can delete it later.
	@rm -rf zap-output 2>/dev/null \
		|| $(DOCKER) run --rm --user 0 -v "$(CURDIR):/work" -w /work --entrypoint rm ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) -rf zap-output
	@mkdir -p zap-output && chmod 777 zap-output
	@$(DOCKER) run --rm --network host \
		-v "$$(pwd)/zap-output:/zap/wrk:rw" \
		ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) \
		zap-baseline.py \
			-t http://$(HOST):$(TEST_HOST_PORT) \
			-I \
			-r zap-report.html \
			-J zap-report.json \
			-w zap-report.md \
		; EXIT=$$?; \
		$(DOCKER) rm -f $(IMAGE_NAME)-dast >/dev/null 2>&1 || true; \
		if [ "$$EXIT" -ne 0 ]; then exit $$EXIT; fi
	@echo "DAST report: $$(pwd)/zap-output/zap-report.html"

#ci-run-tag: @ Run GitHub Actions workflow locally with a tag event (exercises docker job)
ci-run-tag: deps
	@docker container prune -f 2>/dev/null || true
	@TAG="$$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"; \
		echo '{"ref":"refs/tags/'"$$TAG"'"}' > /tmp/act-tag-event.json
	@act push \
		-P ubuntu-latest=catthehacker/ubuntu:$(ACT_UBUNTU_VERSION) \
		--eventpath /tmp/act-tag-event.json \
		--container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts || true
	@echo "Note: cosign signing will fail under act (no OIDC) — expected."

# === CI-specific targets ===
# These are CI-only because they assume infrastructure (PostgreSQL service container,
# pre-installed Dapr CLI) provided by GitHub Actions setup actions. The general
# `install`, `build`, `lint`, `test`, `static-check`, `smoke`, `integration-test`
# targets work in CI directly thanks to PNPM_INSTALL using --frozen-lockfile when
# CI=true and the deps target skipping podman/dapr checks when CI=true.

#ci-seed-db: @ Seed PostgreSQL with baseline schema and data (CI only)
ci-seed-db:
	@PGPASSWORD=postgres psql -h $(HOST) -p $(POSTGRES_PORT) -U postgres -d postgres -f db/baseline_ddl.sql
	@PGPASSWORD=postgres psql -h $(HOST) -p $(POSTGRES_PORT) -U postgres -d postgres -f db/baseline_dml.sql

#ci-dapr-start: @ Initialize Dapr and start sidecar with CI components (CI only)
ci-dapr-start: render-ci-components
	@# `dapr init` docker-pulls daprio/dapr + redis + zipkin from Docker Hub, then
	@# binds FIXED control-plane host ports. On shared CI runner IPs, anonymous
	@# Docker Hub pulls intermittently reset ("connection reset by peer") and the
	@# host-port bind can race a leaked dapr_* container from a prior run — a bare
	@# init hard-fails the integration-test job on either transient. Retry up to 3x
	@# with backoff, cleaning control-plane state between attempts (matches the
	@# retry-after-cleanup form in the local `dapr-init` target).
	@for attempt in 1 2 3; do \
		if dapr init --runtime-version $(DAPR_RUNTIME_VERSION); then break; fi; \
		if [ "$$attempt" -eq 3 ]; then \
			echo "ERROR: dapr init failed after 3 attempts (Docker Hub pull reset or host-port bind race)"; \
			exit 1; \
		fi; \
		delay=$$((attempt * 5)); \
		echo "  ! dapr init failed (attempt $$attempt/3); cleaning up, retrying in $${delay}s..."; \
		dapr uninstall 2>/dev/null || true; \
		$(DOCKER) rm -f $$($(DOCKER) ps -aq --filter "name=dapr_") 2>/dev/null || true; \
		sleep "$$delay"; \
	done
	@DAPR_HOST=$(HOST) DAPR_GRPC_PORT=$(DAPR_GRPC_PORT) DAPR_HTTP_PORT=$(DAPR_HTTP_PORT) \
	nohup dapr run \
		--app-id $(APP_ID) \
		--app-port $(PORT) \
		--app-protocol http \
		--dapr-grpc-port $(DAPR_GRPC_PORT) \
		--dapr-http-port $(DAPR_HTTP_PORT) \
		--scheduler-host-address $(HOST):$(DAPR_SCHEDULER_PORT) \
		--resources-path $(RUN_CI_COMPONENTS_DIR) \
		--log-level warn \
		-- node dist/api-server.js > /tmp/dapr-run.log 2>&1 & \
	echo "Waiting for Dapr sidecar on $(HOST):$(DAPR_HTTP_PORT)..." && \
	timeout $(DAPR_READY_TIMEOUT) bash -c \
		'until curl -sf http://$(HOST):$(DAPR_HTTP_PORT)/v1.0/healthz > /dev/null; do sleep $(BOOT_POLL_INTERVAL); done' \
		|| { echo "=== dapr run log ==="; cat /tmp/dapr-run.log; exit 1; } && \
	echo "Waiting for Dapr gRPC on $(HOST):$(DAPR_GRPC_PORT)..." && \
	timeout $(DAPR_GRPC_READY_TIMEOUT) bash -c \
		'until nc -z $(HOST) $(DAPR_GRPC_PORT) 2>/dev/null; do sleep $(BOOT_POLL_INTERVAL); done' \
		|| { echo "gRPC port $(DAPR_GRPC_PORT) not available on $(HOST)"; exit 1; } && \
	echo "Waiting for API server on $(HOST):$(PORT)..." && \
	timeout $(SERVER_READY_TIMEOUT) bash -c \
		'until curl -sf http://$(HOST):$(PORT)/ > /dev/null; do sleep $(BOOT_POLL_INTERVAL); done' \
		|| { echo "Server failed to start"; tail -20 /tmp/dapr-run.log; exit 1; } && \
	echo "Dapr sidecar and API server are ready."

#ci: @ Run local CI pipeline (static-check, test, build) — static-check runs lint which runs prettier --check
ci: static-check test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act (simulates branch push)
ci-run: deps
	@docker container prune -f 2>/dev/null || true
	@# Force a branch-push event so act doesn't pick up a tag on HEAD. Without
	@# this, running `ci-run` on a tagged commit triggers the tag-gated docker
	@# publish path (Log in to GHCR / Build and push / cosign) and can push to
	@# the real registry. Use `ci-run-tag` to explicitly exercise the tag path.
	@# repository.default_branch is required by dorny/paths-filter on push
	@# events — without it, the `changes` job errors with "This action requires
	@# 'base' input to be configured or 'repository.default_branch' to be set".
	@printf '{"ref":"refs/heads/main","repository":{"default_branch":"main","name":"$(APP_NAME)","full_name":"AndriyKalashnykov/$(APP_NAME)"}}' > /tmp/act-push-event.json
	@act push \
		-P ubuntu-latest=catthehacker/ubuntu:$(ACT_UBUNTU_VERSION) \
		--eventpath /tmp/act-push-event.json \
		--container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#renovate: @ Run Renovate locally in dry-run mode (lazily installed via npm:renovate)
renovate: deps
	@# `$$GITHUB_TOKEN` is escaped — Make passes the literal `$GITHUB_TOKEN` to
	@# `sh`, so the shell substitutes it AFTER `execve`; the token never enters
	@# any argv. Same pattern as security.md §"Never put secret VALUES on the
	@# command line" — env-renaming form. LOG_LEVEL stays at default (info).
	@# `mise exec` installs npm:renovate@$(RENOVATE_VERSION) on first use and
	@# caches it per version — kept out of the eager `make deps` toolchain.
	@if [ -n "$$GITHUB_TOKEN" ]; then export GITHUB_COM_TOKEN="$$GITHUB_TOKEN"; fi; \
		mise exec npm:renovate@$(RENOVATE_VERSION) -- \
		renovate --dry-run=full --platform=local --repository-cache=reset

#renovate-validate: @ Validate Renovate configuration
renovate-validate: deps
	@# Export GITHUB_COM_TOKEN (env-rename, not argv — same safe form as `renovate`)
	@# if a token is present, so github-tags/aqua (mise tools) and action-SHA
	@# lookups resolve instead of being silently skipped as github-token-required.
	@# Schema validation runs regardless; the token only deepens dry-run coverage.
	@if [ -n "$$GITHUB_TOKEN" ]; then export GITHUB_COM_TOKEN="$$GITHUB_TOKEN"; fi; \
		mise exec npm:renovate@$(RENOVATE_VERSION) -- renovate --platform=local

.PHONY: help deps clean install build format format-check \
	lint vulncheck secrets trivy-fs deps-prune deps-prune-check static-check \
	test test-watch integration-test smoke check update upgrade \
	check-ports up down postgres-start postgres-stop dapr-init start start-bg stop start-no-dapr run \
	check-workflow check-db check-version release tag-release \
	image-build image-run image-stop image-structure-test e2e-compose e2e e2e-dapr e2e-durability dast docker-smoke-test dast-scan docker-verify-manifest \
	components-check diagrams diagrams-clean diagrams-check check-node-alignment mermaid-lint \
	render-components render-ci-components render-check \
	ci-seed-db ci-dapr-start ci ci-run ci-run-tag renovate renovate-validate
