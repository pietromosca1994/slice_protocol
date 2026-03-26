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

# Install runtime system dependencies and the iota CLI binary.
# git is required by `iota move build` to fetch the Iota framework git dependency.
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl ca-certificates libssl3 tar libpq5 git && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sL "${IOTA_CLI_URL}" -o /tmp/iota.tgz && \
    tar -xzf /tmp/iota.tgz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/iota && \
    rm /tmp/iota.tgz

# Non-root user for security
RUN groupadd -r appgroup && useradd -r -m -g appgroup appuser

WORKDIR /app

# Copy Move packages (needed at runtime for per-pool package compilation)
COPY --chown=appuser:appgroup packages ./packages

COPY --from=builder --chown=appuser:appgroup /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appgroup /app/dist         ./dist
COPY --from=builder --chown=appuser:appgroup /app/package.json ./package.json

# Switch to appuser before the cache step so the Move dependency cache lands in
# /home/appuser/.move — the same HOME that the API process will use at runtime.
USER appuser

# Create a minimal iota client config so the CLI does not prompt for interactive
# first-time setup (network + key scheme) when invoked non-interactively.
# Without this, `iota move build` crashes with "Key Conversion Error: Invalid key scheme".
RUN mkdir -p /home/appuser/.iota/iota_config && \
    printf '%s\n' '[]' \
      > /home/appuser/.iota/iota_config/iota.keystore && \
    printf 'keystore:\n  File: /home/appuser/.iota/iota_config/iota.keystore\nenvs:\n  - alias: testnet\n    rpc: "https://api.testnet.iota.cafe"\n    ws: ~\n    basic_auth: ~\nactive_env: testnet\nactive_address: ~\n' \
      > /home/appuser/.iota/iota_config/client.yaml

# Pre-cache the Iota framework git dependency at image build time.
# Without this, every POST /pools triggers a full git clone from GitHub.
# The build output is discarded; only the ~/.move cache matters here.
RUN iota move build --dump-bytecode-as-base64 --path /app/packages/securitization > /dev/null || true

# Tell the API where to find the packages directory
ENV PACKAGES_PATH=/app/packages

EXPOSE 3000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD curl -sf http://localhost:3000/health || exit 1

CMD ["node", "dist/index.js"]
