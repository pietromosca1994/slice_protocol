#!/usr/bin/env bash
# =============================================================================
#  IOTA Securitization Protocol — Deployment Script
#  Usage: ./scripts/deploy.sh [testnet|mainnet]
# =============================================================================

set -euo pipefail

NETWORK=${1:-testnet}

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║   IOTA Securitization Protocol — Deploying to       ║"
echo "║   Network: ${NETWORK}                               ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Validate prerequisites ────────────────────────────────────────────────────

if ! command -v iota &> /dev/null; then
    echo "ERROR: iota CLI not found. Install from https://docs.iota.org/developer/getting-started/install-iota"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "ERROR: jq not found. Install with: apt-get install jq / brew install jq"
    exit 1
fi

# ── Environment ───────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
DEPLOY_DIR="$PROJECT_ROOT/deployments"
TIMESTAMP=$(date -u +"%Y%m%dT%H%M%SZ")
DEPLOY_FILE="$DEPLOY_DIR/${NETWORK}_${TIMESTAMP}.json"

mkdir -p "$DEPLOY_DIR"

echo "Project root : $PROJECT_ROOT"
echo "Deployment   : $DEPLOY_FILE"
echo ""

# ── Configure IOTA CLI network ────────────────────────────────────────────────

if [ "$NETWORK" = "mainnet" ]; then
    iota client switch --env mainnet 2>/dev/null || \
        iota client new-env --alias mainnet --rpc https://api.mainnet.iota.cafe:443
    iota client switch --env mainnet
elif [ "$NETWORK" = "testnet" ]; then
    iota client switch --env testnet 2>/dev/null || \
        iota client new-env --alias testnet --rpc https://api.testnet.iota.cafe:443
    iota client switch --env testnet
else
    echo "ERROR: Unknown network '$NETWORK'. Use 'testnet' or 'mainnet'."
    exit 1
fi

ACTIVE_ADDRESS=$(iota client active-address)
echo "Deploying from address: $ACTIVE_ADDRESS"
echo ""

# ── Build ─────────────────────────────────────────────────────────────────────

echo "► Building securitization package..."
cd "$PROJECT_ROOT/packages/securitization"
iota move build --silence-warnings
echo "  Build successful."
echo ""

# ── Publish ───────────────────────────────────────────────────────────────────

echo "► Publishing securitization package to $NETWORK..."
PUBLISH_OUTPUT=$(iota client publish \
    --gas-budget 200000000 \
    --json \
    2>&1)

echo "$PUBLISH_OUTPUT" | jq '.' > /tmp/publish_raw.json 2>/dev/null || {
    echo "ERROR: Publish failed. Output:"
    echo "$PUBLISH_OUTPUT"
    exit 1
}

# Extract package ID and object IDs from publish output
PACKAGE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r '.objectChanges[] | select(.type == "published") | .packageId')
echo "  Package ID: $PACKAGE_ID"

# Extract shared objects (PoolState, TrancheRegistry, etc.)
POOL_STATE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("pool_contract::PoolState")) | .objectId')
TRANCHE_REG_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("tranche_factory::TrancheRegistry")) | .objectId')
ISSUANCE_STATE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("issuance_contract::IssuanceState")) | .objectId' 2>/dev/null || echo "")
WATERFALL_STATE_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("waterfall_engine::WaterfallState")) | .objectId')
COMPLIANCE_REG_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("compliance_registry::ComplianceRegistry")) | .objectId')

# Extract capability objects
ADMIN_CAP_ID=$(echo "$PUBLISH_OUTPUT" | jq -r \
    '.objectChanges[] | select(.objectType? | contains("pool_contract::AdminCap")) | .objectId')

echo ""
echo "── Deployed Objects ──────────────────────────────────"
echo "  PoolState:           $POOL_STATE_ID"
echo "  TrancheRegistry:     $TRANCHE_REG_ID"
echo "  WaterfallState:      $WATERFALL_STATE_ID"
echo "  ComplianceRegistry:  $COMPLIANCE_REG_ID"
echo "  AdminCap:            $ADMIN_CAP_ID"
echo ""

# ── Save deployment manifest ──────────────────────────────────────────────────

cat > "$DEPLOY_FILE" <<EOF
{
  "network":             "$NETWORK",
  "deployedAt":         "$TIMESTAMP",
  "deployedBy":         "$ACTIVE_ADDRESS",
  "packageId":          "$PACKAGE_ID",
  "sharedObjects": {
    "PoolState":          "$POOL_STATE_ID",
    "TrancheRegistry":    "$TRANCHE_REG_ID",
    "WaterfallState":     "$WATERFALL_STATE_ID",
    "ComplianceRegistry": "$COMPLIANCE_REG_ID"
  },
  "capabilityObjects": {
    "AdminCap":           "$ADMIN_CAP_ID"
  }
}
EOF

echo "✓ Deployment manifest saved to: $DEPLOY_FILE"
echo ""

# ── Post-deploy checklist ─────────────────────────────────────────────────────

echo "╔══════════════════════════════════════════════════════╗"
echo "║  POST-DEPLOY SETUP REQUIRED (manual PTB calls):      ║"
echo "╟──────────────────────────────────────────────────────╢"
echo "║  1. pool_contract::set_contracts(...)                ║"
echo "║     Set TrancheFactory, IssuanceContract, Waterfall  ║"
echo "║     and Oracle addresses.                            ║"
echo "║                                                      ║"
echo "║  2. pool_contract::initialise_pool(...)              ║"
echo "║     Provide pool parameters and asset hash.          ║"
echo "║                                                      ║"
echo "║  3. tranche_factory::create_tranches(...)            ║"
echo "║     Set supply caps and IssuanceContract address.    ║"
echo "║                                                      ║"
echo "║  4. payment_vault::create_vault<STABLECOIN>(...)     ║"
echo "║     Create the vault for the chosen stablecoin type. ║"
echo "║                                                      ║"
echo "║  5. payment_vault::authorise_depositor(...)          ║"
echo "║     Grant deposit rights to IssuanceContract.        ║"
echo "║                                                      ║"
echo "║  6. pool_contract::activate_pool(...)                ║"
echo "║     Transition pool to Active status.                ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "Deployment complete."
