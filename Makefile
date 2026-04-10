.DEFAULT_GOAL := help

# Ensure tools installed to $HOME/.local/bin (act, trivy, gitleaks) are on PATH
# for every recipe — needed inside the act runner container where this path is
# not preconfigured. Exported so every sub-shell the recipes spawn inherits it.
export PATH := $(HOME)/.local/bin:$(PATH)

APP_NAME       := dapr-nodejs-workflow
CURRENTTAG     := $(shell git describe --tags --abbrev=0 2>/dev/null || echo "dev")
PORT ?= 3000

# --- Pinned tool versions ---
# renovate: datasource=github-releases depName=nvm-sh/nvm
NVM_VERSION      := 0.40.4
# Single source of truth: .nvmrc — see /makefile skill §3 (file-based derivation)
NODE_VERSION     := $(shell cat .nvmrc 2>/dev/null || echo 24)
# renovate: datasource=npm depName=pnpm
PNPM_VERSION     := 10.33.0
# renovate: datasource=github-releases depName=nektos/act
ACT_VERSION      := 0.2.87
# renovate: datasource=github-releases depName=dapr/cli
DAPR_CLI_VERSION := 1.17.1
# renovate: datasource=github-releases depName=aquasecurity/trivy
TRIVY_VERSION    := 0.69.3
# renovate: datasource=github-releases depName=gitleaks/gitleaks
GITLEAKS_VERSION := 8.30.1

# Use --frozen-lockfile in CI for reproducible installs; allow lockfile updates locally.
PNPM_INSTALL := pnpm install $(if $(CI),--frozen-lockfile,)

#help: @ List available tasks
help:
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-22s\033[0m - %s\n", $$1, $$2}'

#deps: @ Check and install required dependencies (node, pnpm, podman, dapr, git)
deps:
	@echo "Checking dependencies..."
	@command -v node >/dev/null 2>&1 || { echo "Installing Node.js via nvm..."; \
		if [ -s "$$HOME/.nvm/nvm.sh" ]; then \
			. "$$HOME/.nvm/nvm.sh" && nvm install $(NODE_VERSION); \
		else \
			echo "Installing nvm..."; \
			curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v$(NVM_VERSION)/install.sh | bash; \
			export NVM_DIR="$$HOME/.nvm"; \
			. "$$NVM_DIR/nvm.sh" && nvm install $(NODE_VERSION); \
		fi; \
	}
	@command -v pnpm >/dev/null 2>&1 || { echo "Installing pnpm..."; \
		if command -v corepack >/dev/null 2>&1; then \
			corepack enable && corepack prepare pnpm@$(PNPM_VERSION) --activate; \
		else \
			npm install -g pnpm@$(PNPM_VERSION); \
		fi; \
	}
	@if [ -z "$$CI" ]; then \
		command -v podman >/dev/null 2>&1 || { \
			echo "ERROR: Podman is required. Install from https://podman.io/getting-started/installation"; exit 1; \
		}; \
		command -v dapr >/dev/null 2>&1 || { echo "Installing Dapr CLI v$(DAPR_CLI_VERSION)..."; \
			if [ "$$(uname)" = "Linux" ]; then \
				wget -q https://raw.githubusercontent.com/dapr/cli/v$(DAPR_CLI_VERSION)/install/install.sh -O - | /bin/bash; \
			elif [ "$$(uname)" = "Darwin" ]; then \
				if command -v brew >/dev/null 2>&1; then \
					brew install dapr/tap/dapr-cli; \
				else \
					curl -fsSL https://raw.githubusercontent.com/dapr/cli/v$(DAPR_CLI_VERSION)/install/install.sh | /bin/bash; \
				fi; \
			else \
				echo "ERROR: Could not install Dapr CLI. Install manually from https://docs.dapr.io/getting-started/install-dapr-cli/"; exit 1; \
			fi; \
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
		if [ "$$(uname)" = "Linux" ]; then \
			curl -fsSL https://raw.githubusercontent.com/nektos/act/v$(ACT_VERSION)/install.sh | bash -s -- -b $$HOME/.local/bin v$(ACT_VERSION); \
		elif [ "$$(uname)" = "Darwin" ]; then \
			if command -v brew >/dev/null 2>&1; then \
				brew install act; \
			else \
				curl -fsSL https://raw.githubusercontent.com/nektos/act/v$(ACT_VERSION)/install.sh | bash -s -- -b $$HOME/.local/bin v$(ACT_VERSION); \
			fi; \
		else \
			echo "ERROR: Could not install act. Install manually from https://github.com/nektos/act"; exit 1; \
		fi; \
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
	@rm -rf node_modules/ dist/

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

#lint: @ Run Prettier check, ESLint, and TypeScript noEmit
lint: install
	@pnpm exec prettier --check .
	@pnpm exec eslint --max-warnings 0 src/
	@pnpm exec tsc --noEmit

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
	@npx --yes depcheck --ignores="@types/*,eslint,prettier,typescript,vitest,vite,ts-node,readline-sync,@eslint/js,typescript-eslint" || true

#deps-prune-check: @ Verify no prunable dependencies (CI gate)
deps-prune-check: install
	@npx --yes depcheck --ignores="@types/*,eslint,prettier,typescript,vitest,vite,ts-node,readline-sync,@eslint/js,typescript-eslint" --quiet \
		|| { echo "ERROR: unused dependencies found. Run 'make deps-prune' to see them."; exit 1; }

#static-check: @ Composite quality gate (lint + vulncheck + secrets + trivy-fs + deps-prune-check)
static-check: lint vulncheck secrets trivy-fs deps-prune-check
	@echo "Static check passed."

#test: @ Run unit tests
test: install
	@pnpm exec vitest run

#test-watch: @ Run unit tests in watch mode
test-watch: install
	@pnpm exec vitest

#test-integration: @ Run integration tests (requires running infrastructure + Dapr sidecar + server)
test-integration: install
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

#check: @ Run full local verification (format-check, static-check, test, build)
check: format-check static-check test build

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
	@dapr init

#start: @ Build and start the API server with Dapr sidecar
start: build
	@DAPR_HOST=localhost DAPR_HTTP_PORT=3500 \
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

# === CI-specific targets ===
# These are CI-only because they assume infrastructure (PostgreSQL service container,
# pre-installed Dapr CLI) provided by GitHub Actions setup actions. The general
# `install`, `build`, `lint`, `test`, `static-check`, `smoke`, `test-integration`
# targets work in CI directly thanks to PNPM_INSTALL using --frozen-lockfile when
# CI=true and the deps target skipping podman/dapr checks when CI=true.

#ci-seed-db: @ Seed PostgreSQL with baseline schema and data (CI only)
ci-seed-db:
	@PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -f db/baseline_ddl.sql
	@PGPASSWORD=postgres psql -h localhost -U postgres -d postgres -f db/baseline_dml.sql

#ci-dapr-start: @ Initialize Dapr and start sidecar with CI components (CI only)
ci-dapr-start:
	@dapr init
	@DAPR_HOST=localhost DAPR_HTTP_PORT=3500 \
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

#ci: @ Run local CI pipeline (format-check, static-check, test, build)
ci: format-check static-check test build
	@echo "Local CI pipeline passed."

#ci-run: @ Run GitHub Actions workflow locally using act
ci-run: deps-act
	@docker container prune -f 2>/dev/null || true
	@act push --container-architecture linux/amd64 \
		--artifact-server-path /tmp/act-artifacts

#renovate: @ Run Renovate locally in dry-run mode
renovate: deps
	@GITHUB_COM_TOKEN="$(GITHUB_TOKEN)" LOG_LEVEL=debug npx renovate --dry-run=full --platform=local --repository-cache=reset

#renovate-validate: @ Validate Renovate configuration
renovate-validate: deps
	@npx --yes renovate --platform=local

.PHONY: help deps deps-act deps-trivy deps-gitleaks clean install build format format-check \
	lint vulncheck secrets trivy-fs deps-prune deps-prune-check static-check \
	test test-watch test-integration smoke check update upgrade \
	up down postgres-start postgres-stop dapr-init start stop start-no-dapr run \
	check-workflow check-db check-version release tag-release \
	ci-seed-db ci-dapr-start ci ci-run renovate renovate-validate
