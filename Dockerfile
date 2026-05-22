# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

# ============================================================================
# Stage 1: Install production + dev dependencies (cached layer)
# ============================================================================
# renovate: datasource=docker depName=node
FROM node:24-trixie-slim@sha256:05c08ce4291e9a58f59456a7985176defb12cdd42271f35ff81a3e167ea61d4c AS deps

RUN corepack enable

WORKDIR /app

# Copy only manifests for a cacheable install layer
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./

RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# ============================================================================
# Stage 2: Compile TypeScript
# ============================================================================
FROM deps AS builder

COPY tsconfig.json ./
COPY src ./src

RUN pnpm run build

# ============================================================================
# Stage 2b: Production-only dependencies (clean node_modules, no devDeps)
# ============================================================================
FROM deps AS prod-deps

# Delete the full node_modules from the deps stage and reinstall with --prod.
# This ensures devDependencies (typescript, eslint, vitest, vite, etc.) are
# completely removed — pnpm --prod on an existing install may leave artifacts.
RUN rm -rf node_modules
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prod --ignore-scripts

# ============================================================================
# Stage 3: Distroless runtime — no shell, no package manager, non-root
# ============================================================================
# renovate: datasource=docker depName=gcr.io/distroless/nodejs24-debian13
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:4c11c00f9d72bbe5d42fbcab421229b3c046d949f4e0a8e2d50e88a9b319a9e2 AS runtime

WORKDIR /app

# Copy production node_modules (from prod-deps, no devDeps) and compiled output.
# chown to nonroot (uid 65532) — distroless default user.
COPY --from=prod-deps --chown=65532:65532 /app/node_modules ./node_modules
COPY --from=builder --chown=65532:65532 /app/dist ./dist
COPY --from=builder --chown=65532:65532 /app/package.json ./

ENV NODE_ENV=production
ENV PORT=3000

EXPOSE 3000

# Distroless nodejs images run as nonroot (uid 65532) by default.
# Explicit USER ensures Kubernetes runAsNonRoot: true passes admission.
USER 65532

# Distroless nodejs ENTRYPOINT is ["/nodejs/bin/node"]
CMD ["dist/api-server.js"]
