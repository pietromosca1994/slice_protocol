# Build context must be the repository root (one level above api/).
# docker-compose sets this automatically; for manual builds use:
#   docker build -f api/Dockerfile -t securitization-api ..

# URL to the pre-built iota CLI binary for the target platform.
# Find the correct URL at https://github.com/iotaledger/iota/releases
ARG IOTA_CLI_URL=https://github.com/iotaledger/iota/releases/latest/download/iota-linux-x86_64

# ── Stage 1: build ────────────────────────────────────────────────────────────
FROM node:20-slim AS builder

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
      curl ca-certificates libssl3 && \
    rm -rf /var/lib/apt/lists/* && \
    curl -sL "${IOTA_CLI_URL}" -o /usr/local/bin/iota && \
    chmod +x /usr/local/bin/iota

# Non-root user for security
RUN groupadd -r appgroup && useradd -r -g appgroup appuser

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
