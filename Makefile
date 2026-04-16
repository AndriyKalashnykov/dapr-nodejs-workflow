.DEFAULT_GOAL := help

# Ensure tools installed to $HOME/.local/bin (act, trivy, gitleaks) are on PATH
# for every recipe — needed inside the act runner container where this path is
# not preconfigured. Exported so every sub-shell the recipes spawn inherits it.
export PATH := $(HOME)/.local/bin:$(PATH)

APP_NAME       := dapr-nodejs-workflow
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")
PORT ?= 3000

# --- Pinned tool versions ---
# Node + pnpm are managed by mise (see .mise.toml and .nvmrc).
# Single source of truth: .nvmrc — see /makefile skill §3 (file-based derivation).
# mise reads .nvmrc natively for Node and .mise.toml for pnpm; no NVM_VERSION
# pin or nvm install branch — per skill §"Version Manager Policy (BLOCKING)".
NODE_VERSION     := $(shell cat .nvmrc 2>/dev/null || echo 24)
# renovate: datasource=github-releases depName=nektos/act
ACT_VERSION      := 0.2.87
# renovate: datasource=github-releases depName=dapr/cli
DAPR_CLI_VERSION := 1.17.1
# renovate: datasource=github-releases depName=dapr/dapr
DAPR_RUNTIME_VERSION := 1.17.5
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION    := 0.69.3
# renovate: datasource=github-releases depName=gitleaks/gitleaks
GITLEAKS_VERSION := 8.30.1
# renovate: datasource=github-releases depName=hadolint/hadolint
HADOLINT_VERSION := 2.14.0

# renovate: datasource=github-releases depName=zaproxy/zaproxy extractVersion=^v(?<version>.*)$
ZAP_VERSION      := 2.17.0

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

#deps: @ Check and install required dependencies (node + pnpm via mise; podman, dapr, git)
deps:
	@echo "Checking dependencies..."
	@# mise bootstraps Node (from .nvmrc) + pnpm (from .mise.toml) in one step.
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
		command -v dapr >/dev/null 2>&1 || { echo "Installing Dapr CLI v$(DAPR_CLI_VERSION)..."; \
			curl -fsSL https://raw.githubusercontent.com/dapr/cli/v$(DAPR_CLI_VERSION)/install/install.sh | /bin/bash -s $(DAPR_CLI_VERSION); \
		}; \
	fi
	@command -v git >/dev/null 2>&1 || { \
		echo "ERROR: Git is required. Install from https://git-scm.com/downloads"; exit 1; \
	}
	@echo "All dependencies checked."

#deps-act: @ Install act for local CI (GitHub Actions runner)
deps-act: deps
	@command -v act >/dev/null 2>&1 || { echo "Installing act v$(ACT_VERSION)..."; \
		mkdir -p $$HOME/.local/bin; \
		curl -fsSL https://raw.githubusercontent.com/nektos/act/v$(ACT_VERSION)/install.sh | bash -s -- -b $$HOME/.local/bin v$(ACT_VERSION); \
	}

#deps-hadolint: @ Install hadolint for Dockerfile linting
deps-hadolint:
	@command -v hadolint >/dev/null 2>&1 || { echo "Installing hadolint v$(HADOLINT_VERSION)..."; \
		mkdir -p $$HOME/.local/bin; \
		OS=$$(uname | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$OS-$$ARCH" in \
			linux-x86_64)  SUFFIX=Linux-x86_64 ;; \
			linux-aarch64) SUFFIX=Linux-arm64 ;; \
			darwin-x86_64) SUFFIX=Darwin-x86_64 ;; \
			darwin-arm64)  SUFFIX=Darwin-x86_64 ;; \
			*) echo "ERROR: unsupported platform $$OS-$$ARCH"; exit 1 ;; \
		esac; \
		curl -sSfL -o /tmp/hadolint "https://github.com/hadolint/hadolint/releases/download/v$(HADOLINT_VERSION)/hadolint-$$SUFFIX"; \
		install -m 755 /tmp/hadolint $$HOME/.local/bin/hadolint; \
		rm -f /tmp/hadolint; \
	}

#deps-trivy: @ Install Trivy for filesystem security scanning
deps-trivy:
	@command -v trivy >/dev/null 2>&1 || { echo "Installing trivy v$(TRIVY_VERSION)..."; \
		mkdir -p $$HOME/.local/bin; \
		curl -sfL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh | sh -s -- -b $$HOME/.local/bin v$(TRIVY_VERSION); \
	}

#deps-gitleaks: @ Install gitleaks for secret scanning
deps-gitleaks:
	@command -v gitleaks >/dev/null 2>&1 || { echo "Installing gitleaks v$(GITLEAKS_VERSION)..."; \
		mkdir -p $$HOME/.local/bin; \
		OS=$$(uname | tr '[:upper:]' '[:lower:]'); \
		ARCH=$$(uname -m); \
		case "$$ARCH" in x86_64) ARCH=x64;; aarch64|arm64) ARCH=arm64;; esac; \
		curl -sfL -o /tmp/gitleaks.tar.gz "https://github.com/gitleaks/gitleaks/releases/download/v$(GITLEAKS_VERSION)/gitleaks_$(GITLEAKS_VERSION)_$${OS}_$${ARCH}.tar.gz" && \
		tar -xzf /tmp/gitleaks.tar.gz -C /tmp gitleaks && \
		install -m 755 /tmp/gitleaks $$HOME/.local/bin/gitleaks && \
		rm -f /tmp/gitleaks.tar.gz /tmp/gitleaks; \
	}

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
lint: install deps-hadolint
	@pnpm exec prettier --check .
	@pnpm exec eslint --max-warnings 0 src/
	@pnpm exec tsc --noEmit
	@hadolint Dockerfile

#vulncheck: @ Audit dependencies for known vulnerabilities
vulncheck: install
	@pnpm audit --audit-level=moderate

#secrets: @ Scan for hardcoded secrets with gitleaks
secrets: deps-gitleaks
	@gitleaks detect --source . --verbose --redact --no-banner

#trivy-fs: @ Scan filesystem for vulnerabilities, secrets, and misconfigurations
trivy-fs: deps-trivy
	@trivy fs --scanners vuln,secret,misconfig --severity CRITICAL,HIGH .

#deps-prune: @ Show unused/redundant Node.js dependencies
deps-prune: install
	@echo "Checking for unused Node.js packages..."
	@npx --yes depcheck --ignores="@types/*,eslint,prettier,typescript,vitest,vite,@eslint/js,typescript-eslint" || true

#deps-prune-check: @ Verify no prunable dependencies (CI gate)
deps-prune-check: install
	@npx --yes depcheck --ignores="@types/*,eslint,prettier,typescript,vitest,vite,@eslint/js,typescript-eslint" --quiet \
		|| { echo "ERROR: unused dependencies found. Run 'make deps-prune' to see them."; exit 1; }

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

#static-check: @ Composite quality gate (lint + vulncheck + secrets + trivy-fs + deps-prune-check + components-check)
static-check: lint vulncheck secrets trivy-fs deps-prune-check components-check
	@echo "Static check passed."

#test: @ Run unit tests
test: install
	@pnpm exec vitest run

#test-watch: @ Run unit tests in watch mode
test-watch: install
	@pnpm exec vitest

#integration-test: @ Run integration tests (requires running infrastructure + Dapr sidecar + server)
integration-test: install
	@pnpm exec vitest run --config vitest.integration.config.ts

#smoke: @ HTTP smoke test against built server (no Dapr)
smoke: build
	@trap 'kill $$SERVER_PID 2>/dev/null || true' EXIT; \
	node dist/api-server.js & SERVER_PID=$$!; \
	echo "Waiting for server on port $(PORT)..."; \
	timeout 10 bash -c 'until curl -sf http://localhost:$(PORT)/ > /dev/null; do sleep 1; done' || { echo "Server failed to start"; exit 1; }; \
	echo "Server is up, running smoke tests..."; \
	curl -sf http://localhost:$(PORT)/ | grep -q "Dapr Workflow API" || { echo "Health check failed"; exit 1; }; \
	echo "Smoke tests passed"

#check: @ Run full local verification (static-check, test, build) — static-check runs lint which runs prettier --check
check: static-check test build

#update: @ Update dependencies to latest allowed versions
update: deps
	@pnpm update

#upgrade: @ Upgrade dependencies to latest versions (ignoring ranges)
upgrade: deps
	@pnpm upgrade

#up: @ Start PostgreSQL and Redis via Podman Compose
up:
	@if podman compose ps --format '{{.State}}' 2>/dev/null | grep -q running; then \
		echo "Infrastructure is already running."; \
	else \
		podman compose up -d; \
		echo "Waiting for services to be healthy..."; \
		timeout 30 bash -c 'until podman compose ps --format "{{.Status}}" 2>/dev/null | grep -q healthy; do sleep 1; done' || true; \
	fi

#down: @ Stop infrastructure services and remove containers
down:
	@podman compose down

#postgres-start: @ Start PostgreSQL in Podman
postgres-start:
	@if podman ps -q --filter "name=dapr-nodejs-postgres" | grep -q .; then \
		echo "PostgreSQL container is already running."; \
	else \
		./run-postgres.sh; \
	fi

#postgres-stop: @ Stop PostgreSQL Podman container
postgres-stop:
	@podman stop dapr-nodejs-postgres 2>/dev/null || echo "PostgreSQL container is not running."

#dapr-init: @ Initialize Dapr in local environment (stops conflicting Redis if needed)
dapr-init: deps
	@if podman ps -q --filter "publish=6379" | grep -q .; then \
		echo "Stopping container on port 6379 to free it for dapr init..."; \
		podman stop $$(podman ps -q --filter "publish=6379"); \
	fi
	@dapr init --runtime-version $(DAPR_RUNTIME_VERSION)

#start: @ Build and start the API server with Dapr sidecar
start: build
	@DAPR_HOST=localhost DAPR_GRPC_PORT=50001 DAPR_HTTP_PORT=3500 \
	dapr run \
		--app-id workflow-api \
		--app-port $(PORT) \
		--app-protocol http \
		--dapr-grpc-port 50001 \
		--dapr-http-port 3500 \
		--scheduler-host-address localhost:50006 \
		--resources-path ./components \
		-- node dist/api-server.js

#stop: @ Stop the Dapr sidecar and API server
stop:
	@RESULT=$$(dapr stop --app-id workflow-api 2>&1); \
	if echo "$$RESULT" | grep -q "couldn't find app id"; then \
		echo "App workflow-api is not running."; \
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
	@RESP=$$(curl -s -X POST http://localhost:$(PORT)/process-payload \
		-H "Content-Type: application/json" \
		-d '{"name":"Test","data":{"key":"value"}}'); \
	echo "Response: $$RESP"; \
	ID=$$(echo "$$RESP" | grep -o '"id":"[^"]*"' | cut -d'"' -f4); \
	if [ -z "$$ID" ]; then echo "Server not responding on port $(PORT) (is it running with Dapr?)"; \
	else \
	echo "Workflow ID: $$ID"; \
	echo "Waiting 5s before polling status..."; \
	sleep 5; \
	STATUS=$$(curl -s "http://localhost:$(PORT)/workflow/$$ID/status"); \
	echo "$$STATUS" | python3 -m json.tool 2>/dev/null || echo "$$STATUS"; \
	fi

#check-db: @ Run the database health check endpoint
check-db:
	@RESP=$$(curl -s --connect-timeout 5 http://localhost:$(PORT)/db-health); \
	if [ -z "$$RESP" ]; then echo "Server not responding on port $(PORT) (is it running with Dapr?)"; \
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
	@echo -n "Are you sure to create and push ${VERSION} tag? [y/N] " && read ans && [ $${ans:-N} = y ]
	@git commit -a -s -m "Cut ${VERSION} release"
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
	@echo "Container started -> http://localhost:$(PORT)"

#image-stop: @ Stop Docker image container
image-stop:
	@$(DOCKER) rm -f $(IMAGE_NAME) >/dev/null 2>&1 || true

#e2e: @ End-to-end test of the production Docker image
e2e: image-build
	@SVC=$(IMAGE_NAME)-e2e; \
	HOST_PORT=3100; \
	trap "$(DOCKER) rm -f $$SVC >/dev/null 2>&1 || true" EXIT; \
	echo "Starting container $$SVC on port $$HOST_PORT..."; \
	$(DOCKER) run -d --name $$SVC -p $$HOST_PORT:3000 $(IMAGE) >/dev/null; \
	echo "Waiting for HTTP..."; \
	for i in $$(seq 1 30); do \
		curl -sf "http://localhost:$$HOST_PORT/" >/dev/null 2>&1 && break; \
		sleep 1; \
		[ "$$i" -eq 30 ] && { echo "Container failed to start:"; $(DOCKER) logs $$SVC; exit 1; }; \
	done; \
	echo ""; \
	echo "[1/3] GET / (health endpoint)"; \
	BODY=$$(curl -sf "http://localhost:$$HOST_PORT/"); \
	echo "  body: $$BODY"; \
	echo "$$BODY" | grep -q "Dapr Workflow API" || { echo "FAIL: unexpected body"; exit 1; }; \
	echo "  PASS"; \
	echo ""; \
	echo "[2/3] POST /process-payload (expect Dapr unreachable error)"; \
	HTTP=$$(curl -s -o /tmp/e2e-resp.json -w "%{http_code}" -X POST \
		"http://localhost:$$HOST_PORT/process-payload" \
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
e2e-dapr: image-build
	@IMAGE=$(IMAGE) DOCKER=$(DOCKER) RESOURCES_PATH=./components \
		./e2e/e2e-dapr.sh

#e2e-durability: @ Workflow replay e2e: kill the app mid-flight and assert the workflow still COMPLETES
e2e-durability: image-build
	@IMAGE=$(IMAGE) DOCKER=$(DOCKER) RESOURCES_PATH=./components \
		./e2e/e2e-durability.sh

#docker-smoke-test: @ Boot-marker smoke test: start smoke-test container, wait for boot. Leaves container running for DAST (CI)
docker-smoke-test:
	@set -eu; \
	docker run -d --name smoke-test -p 3100:3000 $(IMAGE_NAME):scan; \
	deadline=$$(($$(date +%s) + 30)); \
	while [ $$(date +%s) -lt $$deadline ]; do \
		if docker logs smoke-test 2>&1 | grep -qE 'REST API server running|listening on|started on port'; then \
			echo "PASS: container booted successfully"; \
			exit 0; \
		fi; \
		sleep 2; \
	done; \
	echo "FAIL: container did not boot within 30s"; \
	docker logs smoke-test; \
	exit 1

#dast-scan: @ Run ZAP baseline scan against an already-running container on localhost:3100 (CI)
dast-scan:
	@set -eu; \
	WORK="$${GITHUB_WORKSPACE:-$$PWD}"; \
	mkdir -p "$$WORK/zap-output"; \
	chmod 777 "$$WORK/zap-output"; \
	docker run --rm --network host \
		-v "$$WORK/zap-output:/zap/wrk:rw" \
		ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) \
		zap-baseline.py \
			-t http://localhost:3100 \
			-I \
			-r zap-report.html \
			-J zap-report.json \
			-w zap-report.md

#docker-verify-manifest: @ Assert a published multi-arch image has linux/amd64 + linux/arm64 and zero unknown/unknown entries (CI)
docker-verify-manifest:
	@set -eu; \
	test -n "$(IMAGE_REF)" || { echo "ERROR: IMAGE_REF is required (e.g., make docker-verify-manifest IMAGE_REF=ghcr.io/owner/repo:1.0.0)"; exit 1; }; \
	MANIFEST=$$(docker buildx imagetools inspect "$(IMAGE_REF)"); \
	echo "$$MANIFEST"; \
	if echo "$$MANIFEST" | grep -q 'unknown/unknown'; then \
		echo "FAIL: image index contains unknown/unknown entries (attestations leaked?)"; \
		exit 1; \
	fi; \
	if ! echo "$$MANIFEST" | grep -q 'linux/amd64'; then \
		echo "FAIL: linux/amd64 platform missing"; \
		exit 1; \
	fi; \
	if ! echo "$$MANIFEST" | grep -q 'linux/arm64'; then \
		echo "FAIL: linux/arm64 platform missing"; \
		exit 1; \
	fi; \
	echo "PASS: multi-arch manifest verified"

#dast: @ ZAP baseline DAST scan against the built image
dast: image-build
	@$(DOCKER) rm -f $(IMAGE_NAME)-dast 2>/dev/null || true
	@$(DOCKER) run -d --name $(IMAGE_NAME)-dast -p 3100:3000 $(IMAGE) >/dev/null
	@echo "Waiting for container to become healthy..."
	@for i in $$(seq 1 30); do \
		curl -sf http://localhost:3100/ >/dev/null 2>&1 && break; \
		sleep 1; \
		[ "$$i" -eq 30 ] && { echo "Container failed to start"; $(DOCKER) logs $(IMAGE_NAME)-dast; $(DOCKER) rm -f $(IMAGE_NAME)-dast; exit 1; }; \
	done
	@mkdir -p zap-output && chmod 777 zap-output
	@$(DOCKER) run --rm --network host \
		-v "$$(pwd)/zap-output:/zap/wrk:rw" \
		ghcr.io/zaproxy/zaproxy:$(ZAP_VERSION) \
		zap-baseline.py \
			-t http://localhost:3100 \
			-I \
			-r zap-report.html \
			-J zap-report.json \
			-w zap-report.md \
		; EXIT=$$?; \
		$(DOCKER) rm -f $(IMAGE_NAME)-dast >/dev/null 2>&1 || true; \
		if [ "$$EXIT" -ne 0 ]; then exit $$EXIT; fi
	@echo "DAST report: $$(pwd)/zap-output/zap-report.html"

#ci-run-tag: @ Run GitHub Actions workflow locally with a tag event (exercises docker job)
ci-run-tag: deps-act
	@docker container prune -f 2>/dev/null || true
	@TAG="$$(git describe --tags --abbrev=0 2>/dev/null || echo v0.0.0)"; \
		echo '{"ref":"refs/tags/'"$$TAG"'"}' > /tmp/act-tag-event.json
	@act push \
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
	@PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -f db/baseline_ddl.sql
	@PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -f db/baseline_dml.sql

#ci-dapr-start: @ Initialize Dapr and start sidecar with CI components (CI only)
ci-dapr-start:
	@dapr init --runtime-version $(DAPR_RUNTIME_VERSION)
	@DAPR_HOST=localhost DAPR_GRPC_PORT=50001 DAPR_HTTP_PORT=3500 \
	nohup dapr run \
		--app-id workflow-api \
		--app-port 3000 \
		--app-protocol http \
		--dapr-grpc-port 50001 \
		--dapr-http-port 3500 \
		--scheduler-host-address localhost:50006 \
		--resources-path ./dapr/ci \
		--log-level warn \
		-- node dist/api-server.js > /tmp/dapr-run.log 2>&1 & \
	echo "Waiting for Dapr sidecar on :3500..." && \
	timeout 30 bash -c \
		'until curl -sf http://localhost:3500/v1.0/healthz > /dev/null; do sleep 1; done' \
		|| { echo "=== dapr run log ==="; cat /tmp/dapr-run.log; exit 1; } && \
	echo "Waiting for Dapr gRPC on :50001..." && \
	timeout 15 bash -c \
		'until nc -z localhost 50001 2>/dev/null; do sleep 1; done' \
		|| { echo "gRPC port 50001 not available"; exit 1; } && \
	echo "Waiting for API server on :3000..." && \
	timeout 15 bash -c \
		'until curl -sf http://localhost:3000/ > /dev/null; do sleep 1; done' \
		|| { echo "Server failed to start"; tail -20 /tmp/dapr-run.log; exit 1; } && \
	echo "Dapr sidecar and API server are ready."

#ci: @ Run local CI pipeline (static-check, test, build) — static-check runs lint which runs prettier --check
ci: static-check test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act (simulates branch push)
ci-run: deps-act
	@docker container prune -f 2>/dev/null || true
	@# Force a branch-push event so act doesn't pick up a tag on HEAD. Without
	@# this, running `ci-run` on a tagged commit triggers the tag-gated docker
	@# publish path (Log in to GHCR / Build and push / cosign) and can push to
	@# the real registry. Use `ci-run-tag` to explicitly exercise the tag path.
	@echo '{"ref":"refs/heads/main"}' > /tmp/act-push-event.json
	@act push \
		--eventpath /tmp/act-push-event.json \
		--container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#renovate: @ Run Renovate locally in dry-run mode
renovate: deps
	@GITHUB_COM_TOKEN="$(GITHUB_TOKEN)" LOG_LEVEL=debug npx renovate --dry-run=full --platform=local --repository-cache=reset

#renovate-validate: @ Validate Renovate configuration
renovate-validate: deps
	@npx --yes renovate --platform=local

.PHONY: help deps deps-act deps-trivy deps-gitleaks deps-hadolint clean install build format format-check \
	lint vulncheck secrets trivy-fs deps-prune deps-prune-check static-check \
	test test-watch integration-test smoke check update upgrade \
	up down postgres-start postgres-stop dapr-init start stop start-no-dapr run \
	check-workflow check-db check-version release tag-release \
	image-build image-run image-stop e2e e2e-dapr e2e-durability dast docker-smoke-test dast-scan docker-verify-manifest \
	components-check \
	ci-seed-db ci-dapr-start ci ci-run ci-run-tag renovate renovate-validate
