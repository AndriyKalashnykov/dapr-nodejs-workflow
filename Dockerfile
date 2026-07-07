# syntax=docker/dockerfile:1@sha256:87999aa3d42bdc6bea60565083ee17e86d1f3339802f543c0d03998580f9cb89

# ============================================================================
# Stage 1: Install production + dev dependencies (cached layer)
# ============================================================================
# renovate: datasource=docker depName=node
FROM node:24-trixie-slim@sha256:366fdef91728b1b7fa18c84fba63b6e79ed77b7e10cc206878e9705da4d7b169 AS deps

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
FROM gcr.io/distroless/nodejs24-debian13:nonroot@sha256:ed5e65a1036b505c9e5abf0d0412ce0f70be1b812630bbbbaf49ce47edc7a513 AS runtime

# Externalized so a consumer can override per-base without editing the Dockerfile.
# Defaults match the distroless nonroot user (uid/gid 65532) and the app listen
# port — so the built image is byte-for-byte unchanged unless overridden.
ARG APP_UID=65532
ARG APP_GID=65532
ARG APP_INTERNAL_PORT=3000

WORKDIR /app

# Copy production node_modules (from prod-deps, no devDeps) and compiled output,
# chowned to the nonroot user.
COPY --from=prod-deps --chown=${APP_UID}:${APP_GID} /app/node_modules ./node_modules
COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/dist ./dist
COPY --from=builder --chown=${APP_UID}:${APP_GID} /app/package.json ./

ENV NODE_ENV=production
ENV PORT=${APP_INTERNAL_PORT}

EXPOSE ${APP_INTERNAL_PORT}

# Distroless nodejs images run as nonroot (uid 65532) by default.
# Explicit USER ensures Kubernetes runAsNonRoot: true passes admission.
USER ${APP_UID}:${APP_GID}

# Liveness probe. Distroless has no shell/curl, so use node's net module to TCP-
# connect to the app's listen port. 127.0.0.1 (not localhost) avoids IPv6-first
# resolution; the CMD body reads $PORT at runtime, but the flag durations MUST be
# literal — HEALTHCHECK flags are parsed at build time and are NOT variable-expanded.
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
    CMD ["/nodejs/bin/node", "-e", "const s=require('net').connect(Number(process.env.PORT||3000),'127.0.0.1',()=>{s.end();process.exit(0)});s.on('error',()=>process.exit(1))"]

# Distroless nodejs ENTRYPOINT is ["/nodejs/bin/node"]
CMD ["dist/api-server.js"]
