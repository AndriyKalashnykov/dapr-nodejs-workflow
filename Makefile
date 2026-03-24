.DEFAULT_GOAL := help

PORT ?= 3000

#help: @ List available tasks
help:
	@clear
	@echo "Usage: make COMMAND"
	@echo "Commands :"
	@grep -E '[a-zA-Z\.\-]+:.*?@ .*$$' $(MAKEFILE_LIST)| tr -d '#' | awk 'BEGIN {FS = ":.*?@ "}; {printf "\033[32m%-16s\033[0m - %s\n", $$1, $$2}'

#deps: @ Check and install required dependencies (node, pnpm, podman, dapr, git)
deps:
	@echo "Checking dependencies..."
	@command -v node >/dev/null 2>&1 || { echo "Installing Node.js via nvm..."; \
		if [ -s "$$HOME/.nvm/nvm.sh" ]; then \
			. "$$HOME/.nvm/nvm.sh" && nvm install $$(cat .nvmrc); \
		else \
			echo "Installing nvm..."; \
			curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash; \
			export NVM_DIR="$$HOME/.nvm"; \
			. "$$NVM_DIR/nvm.sh" && nvm install $$(cat .nvmrc); \
		fi; \
	}
	@command -v pnpm >/dev/null 2>&1 || { echo "Installing pnpm..."; \
		if command -v corepack >/dev/null 2>&1; then \
			corepack enable && corepack prepare pnpm@latest --activate; \
		else \
			npm install -g pnpm; \
		fi; \
	}
	@command -v podman >/dev/null 2>&1 || { echo "Installing Podman..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update && sudo apt-get install -y podman; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y podman; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install podman; \
		else \
			echo "ERROR: Could not install podman. Install manually from https://podman.io/getting-started/installation"; exit 1; \
		fi; \
	}
	@command -v dapr >/dev/null 2>&1 || { echo "Installing Dapr CLI..."; \
		if [ "$$(uname)" = "Linux" ]; then \
			wget -q https://raw.githubusercontent.com/dapr/cli/master/install/install.sh -O - | /bin/bash; \
		elif [ "$$(uname)" = "Darwin" ]; then \
			if command -v brew >/dev/null 2>&1; then \
				brew install dapr/tap/dapr-cli; \
			else \
				curl -fsSL https://raw.githubusercontent.com/dapr/cli/master/install/install.sh | /bin/bash; \
			fi; \
		else \
			echo "ERROR: Could not install dapr CLI. Install manually from https://docs.dapr.io/getting-started/install-dapr-cli/"; exit 1; \
		fi; \
	}
	@command -v git >/dev/null 2>&1 || { echo "Installing git..."; \
		if command -v apt-get >/dev/null 2>&1; then \
			sudo apt-get update && sudo apt-get install -y git; \
		elif command -v dnf >/dev/null 2>&1; then \
			sudo dnf install -y git; \
		elif command -v brew >/dev/null 2>&1; then \
			brew install git; \
		else \
			echo "ERROR: Could not install git. Install manually from https://git-scm.com/downloads"; exit 1; \
		fi; \
	}
	@echo "All dependencies checked."

#clean: @ Remove build artifacts and node_modules
clean:
	@rm -rf node_modules/ dist/

#install: @ Install npm dependencies
install: deps
	pnpm install

#build: @ Build TypeScript to dist/
build: install
	pnpm build

#update: @ Update dependencies to latest allowed versions
update: deps
	pnpm update

#upgrade: @ Upgrade dependencies to latest versions (ignoring ranges)
upgrade: deps
	pnpm upgrade

#postgres-start: @ Start PostgreSQL in Docker
postgres-start:
	@if docker ps -q --filter "name=dapr-nodejs-postgres" | grep -q .; then \
		echo "PostgreSQL container is already running."; \
	else \
		./run-postgres.sh; \
	fi

#postgres-stop: @ Stop PostgreSQL Docker container
postgres-stop:
	@docker stop dapr-nodejs-postgres 2>/dev/null || echo "PostgreSQL container is not running."

#dapr-init: @ Initialize Dapr in local environment (stops conflicting Redis if needed)
dapr-init:
	@command -v dapr >/dev/null 2>&1 || { echo "ERROR: dapr CLI not found. Run 'make deps' first."; exit 1; }
	@if docker ps -q --filter "publish=6379" | grep -q .; then \
		echo "Stopping container on port 6379 to free it for dapr init..."; \
		docker stop $$(docker ps -q --filter "publish=6379"); \
	fi
	dapr init

#start: @ Build and start the API server with Dapr sidecar
start: build
	DAPR_HOST=localhost DAPR_HTTP_PORT=3500 \
	dapr run \
		--app-id workflow-api \
		--app-port $(PORT) \
		--app-protocol http \
		--dapr-grpc-port 50001 \
		--dapr-http-port 3500 \
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
	PORT=$(PORT) node dist/api-server.js

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

#check-version: @ Ensure VERSION variable is set
check-version:
ifndef VERSION
	$(error VERSION is undefined. Usage: make release VERSION=v1.0.0)
endif
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

#ci-install: @ Install dependencies with frozen lockfile (CI only, skips system deps)
ci-install:
	pnpm install --frozen-lockfile

#ci-build: @ Build TypeScript in CI (frozen lockfile, no system deps)
ci-build: ci-install
	pnpm build

#audit: @ Audit dependencies for known vulnerabilities
audit:
	pnpm audit --audit-level=high

#ci: @ Run CI pipeline locally using act (requires Docker)
ci:
	@command -v act >/dev/null 2>&1 || { echo "ERROR: act not found. Install from https://github.com/nektos/act"; exit 1; }
	act push --job ci

#renovate: @ Run Renovate locally in dry-run mode
renovate: deps
	@LOG_LEVEL=debug npx renovate --dry-run=full --platform=local --repository-cache=reset --token=$(GITHUB_TOKEN)
