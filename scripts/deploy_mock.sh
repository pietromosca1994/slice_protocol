#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration
############################################

NETWORK_ARG=${1:-${NETWORK:-}}
NETWORK=${NETWORK_ARG:-localnet}
PACKAGE_PATH=${PACKAGE_PATH:-./packages/mock}
OUTPUT_DIR=${OUTPUT_DIR:-deployments}

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RAW_OUTPUT_FILE="$OUTPUT_DIR/publish_mock_${NETWORK}_${TIMESTAMP}.json"
MANIFEST_FILE="$OUTPUT_DIR/manifest_mock_${NETWORK}_${TIMESTAMP}.json"

############################################
# Helpers
############################################

log()     { echo "  $*"; }
section() { echo; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }
ok()      { echo "  ✓ $*"; }
fail()    { echo "  ✗ $*" >&2; exit 1; }

print_id() {
    local label="$1" value="$2"
    if [[ -n "$value" ]]; then
        ok "$(printf '%-30s %s' "$label" "$value")"
    else
        echo "  ⚠ $(printf '%-30s %s' "$label" "(not found — set manually)")"
    fi
}

############################################
# Network selection
############################################

case "$NETWORK" in
    mainnet)  RPC="https://api.mainnet.iota.cafe:443" ;;
    testnet)  RPC="https://api.testnet.iota.cafe:443" ;;
    localnet) RPC="http://127.0.0.1:9000" ;;
    *)
        fail "Unknown network '$NETWORK'. Use: mainnet | testnet | localnet"
        ;;
esac

############################################
# Configure IOTA client
############################################

section "Network Setup"

iota client switch --env "$NETWORK" >/dev/null 2>&1 || \
    iota client new-env --alias "$NETWORK" --rpc "$RPC" >/dev/null 2>&1
iota client switch --env "$NETWORK" >/dev/null 2>&1

ACTIVE_ADDRESS=$(iota client active-address)

log "Network:        $NETWORK"
log "RPC:            $RPC"
log "Active address: $ACTIVE_ADDRESS"

if [[ "$NETWORK" == "localnet" || "$NETWORK" == "testnet" ]]; then
    log "Requesting faucet funds..."
    iota client faucet >/dev/null 2>&1 || true
    ok "Faucet done"
fi

############################################
# Publish package
############################################

section "Publishing Mock Package"
log "Path: $PACKAGE_PATH"

set +e
PUBLISH_OUTPUT=$(iota client publish "$PACKAGE_PATH" --json 2>&1)
PUBLISH_EXIT=$?
set -e

if [[ $PUBLISH_EXIT -ne 0 ]]; then
    echo "$PUBLISH_OUTPUT"
    fail "Publish command failed (exit code $PUBLISH_EXIT)"
fi

# Strip any leading non-JSON lines
JSON_OUTPUT=$(echo "$PUBLISH_OUTPUT" | awk 'BEGIN{json=0} /^\{/{json=1} json')

if ! echo "$JSON_OUTPUT" | jq empty >/dev/null 2>&1; then
    echo "$PUBLISH_OUTPUT"
    fail "Could not extract valid JSON from publish output"
fi

echo "$JSON_OUTPUT" > "$RAW_OUTPUT_FILE"
ok "Publish output saved → $RAW_OUTPUT_FILE"

############################################
# Parse deployment info
############################################

TX_DIGEST=$(jq -r '.digest // empty' <<< "$JSON_OUTPUT")

PACKAGE_ID=$(jq -r '
    .objectChanges[]
    | select(.type=="published")
    | .packageId
' <<< "$JSON_OUTPUT")

[[ -n "$PACKAGE_ID" ]] || fail "Could not extract Package ID from publish output"

ok "Package ID:  $PACKAGE_ID"
ok "TX Digest:   $TX_DIGEST"

############################################
# Extract created objects
############################################

section "Extracting Created Objects"

TREASURY_CAP_ID=$(jq -r '
    .objectChanges[]
    | select(.type=="created" and (.objectType | contains("TreasuryCap")))
    | .objectId
' <<< "$JSON_OUTPUT" | head -1)

print_id "TreasuryCap<MOCK_USDC>:" "$TREASURY_CAP_ID"

############################################
# Save deployment manifest
############################################

section "Saving Deployment Manifest"

cat > "$MANIFEST_FILE" <<EOF
{
  "network":       "$NETWORK",
  "timestamp":     "$TIMESTAMP",
  "txDigest":      "$TX_DIGEST",
  "packageId":     "$PACKAGE_ID",
  "activeAddress": "$ACTIVE_ADDRESS",
  "caps": {
    "treasuryCap": "$TREASURY_CAP_ID"
  }
}
EOF

ok "Manifest saved → $MANIFEST_FILE"

############################################
# Next steps
############################################

section "Next Steps"

cat <<EOF
  MOCK_USDC is deployed. The TreasuryCap is owned by $ACTIVE_ADDRESS.

  Coin type:
    ${PACKAGE_ID}::mock_usdc::MOCK_USDC

  Mint tokens to an address:
    iota client call \\
      --package $PACKAGE_ID \\
      --module  mock_usdc \\
      --function mint \\
      --args $TREASURY_CAP_ID <amount> <recipient_address>

  Use this coin type when creating an IssuanceState or VaultBalance
  in the securitization protocol.
EOF

echo
