#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration
############################################

NETWORK_ARG=${1:-${NETWORK:-}}
NETWORK=${NETWORK_ARG:-localnet}
PACKAGE_PATH=${PACKAGE_PATH:-./packages/spv}
OUTPUT_DIR=${OUTPUT_DIR:-deployments}

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RAW_OUTPUT_FILE="$OUTPUT_DIR/publish_spv_${NETWORK}_${TIMESTAMP}.json"
MANIFEST_FILE="$OUTPUT_DIR/manifest_spv_${NETWORK}_${TIMESTAMP}.json"

############################################
# Helpers
############################################

log()     { echo "  $*"; }
section() { echo; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }
ok()      { echo "  ✓ $*"; }
fail()    { echo "  ✗ $*" >&2; exit 1; }

extract_object() {
    local json="$1" suffix="$2"
    jq -r --arg s "$suffix" '
        .objectChanges[]
        | select(.type=="created" and (.objectType | endswith($s)))
        | .objectId
    ' <<< "$json" | head -1
}

extract_cap() {
    local json="$1" suffix="$2"
    jq -r --arg s "$suffix" '
        .objectChanges[]
        | select(.type=="created" and (.objectType | endswith($s)))
        | .objectId
    ' <<< "$json" | head -1
}

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

section "Publishing SPV Package"
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
# Extract all created object IDs
############################################

section "Extracting Created Objects"

SPV_REGISTRY_ID=$(extract_object    "$JSON_OUTPUT" "spv_registry::SPVRegistry")
SPV_REGISTRY_ADMIN_CAP_ID=$(extract_cap "$JSON_OUTPUT" "spv_registry::SPVRegistryAdminCap")

COMPLIANCE_REGISTRY_ID=$(extract_object "$JSON_OUTPUT" "compliance_registry::ComplianceRegistry")
COMPLIANCE_ADMIN_CAP_ID=$(extract_cap   "$JSON_OUTPUT" "compliance_registry::ComplianceAdminCap")

VAULT_ADMIN_CAP_ID=$(extract_cap    "$JSON_OUTPUT" "payment_vault::VaultAdminCap")

print_id "SPVRegistry:"           "$SPV_REGISTRY_ID"
print_id "SPVRegistryAdminCap:"   "$SPV_REGISTRY_ADMIN_CAP_ID"
print_id "ComplianceRegistry:"    "$COMPLIANCE_REGISTRY_ID"
print_id "ComplianceAdminCap:"    "$COMPLIANCE_ADMIN_CAP_ID"
print_id "VaultAdminCap:"         "$VAULT_ADMIN_CAP_ID"

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
  "objects": {
    "spvRegistry":        "$SPV_REGISTRY_ID",
    "complianceRegistry": "$COMPLIANCE_REGISTRY_ID"
  },
  "caps": {
    "spvRegistryAdminCap":  "$SPV_REGISTRY_ADMIN_CAP_ID",
    "complianceAdminCap":   "$COMPLIANCE_ADMIN_CAP_ID",
    "vaultAdminCap":        "$VAULT_ADMIN_CAP_ID"
  }
}
EOF

ok "Manifest saved → $MANIFEST_FILE"

############################################
# Print .env block for the API
############################################

section "Copy these two values into your API .env file"

cat <<EOF
SPV_PACKAGE_ID=$PACKAGE_ID
SPV_REGISTRY_ID=$SPV_REGISTRY_ID
EOF

############################################
# Next steps
############################################

section "Next Steps"

cat <<EOF
  The SPV package is ready. No wiring steps are required.

  1.  Copy SPV_PACKAGE_ID and SPV_REGISTRY_ID into api/.env

  2.  (Optional) Create a VaultBalance for your stablecoin:
        POST /vault/create   { "coinType": "0x2::iota::IOTA" }

  3.  Start creating pools:
        POST /pools   (deploys a fresh securitization package per pool)

  4.  Whitelist investors before issuance opens:
        POST /compliance/$COMPLIANCE_REGISTRY_ID/investors

  See api/README.md for the full API reference.
EOF

echo
