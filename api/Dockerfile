# Build context must be the repository root (one level above api/).
# docker-compose sets this automatically; for manual builds use:
#   docker build -f api/Dockerfile -t securitization-api ..

# URL to the pre-built iota CLI binary for the target platform.
# Find the correct URL at https://github.com/iotaledger/iota/releases
ARG IOTA_CLI_URL=https://github.com/iotaledger/iota/releases/download/v1.19.1/iota-v1.19.1-linux-x86_64.tgz

# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM node:20-slim AS builder

# Install build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git-all cmake gcc libssl-dev pkg-config libclang-dev build-essential && \
    rm -rf /var/lib/apt/lists/*
    
WORKDIR /app

COPY api/package*.json ./
RUN npm ci

COPY api/tsconfig.json ./
COPY api/src ./src

RUN npm run build

# Prune dev dependencies
RUN npm ci --omit=dev

# ── Stage 2: runtime ──────────────────────────────────────────────────────────
FROM node:20-slim AS runtime

ARG IOTA_CLI_URL

# Install runtime system dependencies and the iota CLI binary
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates libssl3 tar libpq5 git && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sL "${IOTA_CLI_URL}" -o /tmp/iota.tgz && \
    tar -xzf /tmp/iota.tgz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/iota && \
    rm /tmp/iota.tgz

# Non-root user for security — create home dir and writable cache dirs for iota CLI
RUN groupadd -r appgroup && useradd -r -g appgroup -m -d /home/appuser appuser && \
    mkdir -p /home/appuser/.move /home/appuser/.iota/iota_config && \
    chown -R appuser:appgroup /home/appuser

ENV HOME=/home/appuser

# Pre-initialise the iota CLI as appuser so `iota move build` never hits the
# interactive first-run wizard. Generates a throw-away ed25519 keypair pointed
# at testnet. The keypair is only used for compilation — all actual signing uses
# the app's own key management.
RUN su appuser -c "printf 'testnet\n0\n' | iota client --yes 2>&1 || true"

WORKDIR /app

# Copy Move packages (needed at runtime for per-pool package compilation)
COPY --chown=appuser:appgroup packages ./packages

COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app/dist         ./dist
COPY --from=builder --chown=appuser:appgroup /app/package.json ./package.json

# Tell the API where to find the packages directory
ENV PACKAGES_PATH=/app/packages

USER appuser

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
