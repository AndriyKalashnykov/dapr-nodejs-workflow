# syntax=docker/dockerfile:1

# ============================================================================
# Stage 1: Install production + dev dependencies (cached layer)
# ============================================================================
# renovate: datasource=docker depName=node
FROM node:24-bookworm-slim@sha256:b506e7321f176aae77317f99d67a24b272c1f09f1d10f1761f2773447d8da26c AS deps

RUN corepack enable

WORKDIR /app

# Copy only manifests for a cacheable install layer
COPY package.json pnpm-lock.yaml ./

RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile

# ============================================================================
# Stage 2: Compile TypeScript and prune to production deps
# ============================================================================
FROM deps AS builder

COPY tsconfig.json ./
COPY src ./src

RUN pnpm run build

# Re-install production-only deps into a clean directory for the runtime stage.
# This drops devDependencies (typescript, eslint, vitest, etc.) from the image.
RUN --mount=type=cache,target=/root/.local/share/pnpm/store \
    pnpm install --frozen-lockfile --prod --ignore-scripts && \
    pnpm store prune

# ============================================================================
# Stage 3: Distroless runtime — no shell, no package manager, non-root
# ============================================================================
# renovate: datasource=docker depName=gcr.io/distroless/nodejs24-debian12
FROM gcr.io/distroless/nodejs24-debian12:nonroot@sha256:14d42e2511532589a7c7e01a753667a74fcc96266e137e8125006b87b0c32d0a AS runtime

LABEL org.opencontainers.image.title="dapr-nodejs-workflow" \
      org.opencontainers.image.description="Dapr Workflow demo — Express HTTP API with durable workflows" \
      org.opencontainers.image.source="https://github.com/AndriyKalashnykov/dapr-nodejs-workflow" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.authors="Andriy Kalashnykov"

WORKDIR /app

# Copy production node_modules and compiled output only.
# chown to nonroot (uid 65532) — distroless default user.
COPY --from=builder --chown=65532:65532 /app/node_modules ./node_modules
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
