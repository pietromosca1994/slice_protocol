#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration
############################################

NETWORK_ARG=${1:-${NETWORK:-}}
NETWORK=${NETWORK_ARG:-localnet}
PACKAGE_PATH=${PACKAGE_PATH:-./packages/securitization}
OUTPUT_DIR=${OUTPUT_DIR:-deployments}

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RAW_OUTPUT_FILE="$OUTPUT_DIR/publish_${NETWORK}_${TIMESTAMP}.json"
MANIFEST_FILE="$OUTPUT_DIR/manifest_${NETWORK}_${TIMESTAMP}.json"

############################################
# Helpers
############################################

log()     { echo "  $*"; }
section() { echo; echo "══════════════════════════════════════"; echo "  $*"; echo "══════════════════════════════════════"; }
ok()      { echo "  ✓ $*"; }
fail()    { echo "  ✗ $*" >&2; exit 1; }

# Extract a single created object ID by its Move type suffix
# Usage: extract_object <JSON> <TypeSuffix>
# e.g.:  extract_object "$JSON" "PoolState"
extract_object() {
    local json="$1" suffix="$2"
    jq -r --arg s "$suffix" '
        .objectChanges[]
        | select(.type=="created" and (.objectType | endswith($s)))
        | .objectId
    ' <<< "$json" | head -1
}

# Extract a capability object owned by the active address
extract_cap() {
    local json="$1" suffix="$2"
    jq -r --arg s "$suffix" '
        .objectChanges[]
        | select(.type=="created" and (.objectType | endswith($s)))
        | .objectId
    ' <<< "$json" | head -1
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

section "Publishing Package"
log "Path: $PACKAGE_PATH"

PUBLISH_OUTPUT=$(iota client publish "$PACKAGE_PATH" --json 2>&1)

# Extract JSON block (strip any leading non-JSON lines)
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

POOL_STATE_ID=$(extract_object       "$JSON_OUTPUT" "pool_contract::PoolState")
ADMIN_CAP_ID=$(extract_cap           "$JSON_OUTPUT" "pool_contract::AdminCap")
ORACLE_CAP_ID=$(extract_cap          "$JSON_OUTPUT" "pool_contract::OracleCap")

TRANCHE_REGISTRY_ID=$(extract_object "$JSON_OUTPUT" "tranche_factory::TrancheRegistry")
TRANCHE_ADMIN_CAP_ID=$(extract_cap   "$JSON_OUTPUT" "tranche_factory::TrancheAdminCap")

SENIOR_TREASURY_ID=$(extract_object  "$JSON_OUTPUT" "senior_coin::SeniorTreasury")
MEZZ_TREASURY_ID=$(extract_object    "$JSON_OUTPUT" "mezz_coin::MezzTreasury")
JUNIOR_TREASURY_ID=$(extract_object  "$JSON_OUTPUT" "junior_coin::JuniorTreasury")

COMPLIANCE_REGISTRY_ID=$(extract_object "$JSON_OUTPUT" "compliance_registry::ComplianceRegistry")
COMPLIANCE_ADMIN_CAP_ID=$(extract_cap   "$JSON_OUTPUT" "compliance_registry::ComplianceAdminCap")

WATERFALL_STATE_ID=$(extract_object  "$JSON_OUTPUT" "waterfall_engine::WaterfallState")
WATERFALL_ADMIN_CAP_ID=$(extract_cap "$JSON_OUTPUT" "waterfall_engine::WaterfallAdminCap")

ISSUANCE_OWNER_CAP_ID=$(extract_cap  "$JSON_OUTPUT" "issuance_contract::IssuanceOwnerCap")
VAULT_ADMIN_CAP_ID=$(extract_cap     "$JSON_OUTPUT" "payment_vault::VaultAdminCap")

# Print extracted IDs (warn if any are missing but do not abort — user may set them manually)
print_id() {
    local label="$1" value="$2"
    if [[ -n "$value" ]]; then
        ok "$(printf '%-30s %s' "$label" "$value")"
    else
        echo "  ⚠ $(printf '%-30s %s' "$label" "(not found — set manually)")"
    fi
}

print_id "PoolState:"             "$POOL_STATE_ID"
print_id "AdminCap:"              "$ADMIN_CAP_ID"
print_id "OracleCap:"             "$ORACLE_CAP_ID"
print_id "TrancheRegistry:"       "$TRANCHE_REGISTRY_ID"
print_id "TrancheAdminCap:"       "$TRANCHE_ADMIN_CAP_ID"
print_id "SeniorTreasury:"        "$SENIOR_TREASURY_ID"
print_id "MezzTreasury:"          "$MEZZ_TREASURY_ID"
print_id "JuniorTreasury:"        "$JUNIOR_TREASURY_ID"
print_id "ComplianceRegistry:"    "$COMPLIANCE_REGISTRY_ID"
print_id "ComplianceAdminCap:"    "$COMPLIANCE_ADMIN_CAP_ID"
print_id "WaterfallState:"        "$WATERFALL_STATE_ID"
print_id "WaterfallAdminCap:"     "$WATERFALL_ADMIN_CAP_ID"
print_id "IssuanceOwnerCap:"      "$ISSUANCE_OWNER_CAP_ID"
print_id "VaultAdminCap:"         "$VAULT_ADMIN_CAP_ID"

############################################
# Wiring Step 1 — set_contracts
# Links tranche_factory, issuance_contract,
# waterfall_engine, and oracle_address on
# PoolState. Must happen before initialise_pool
# so OracleCap is sent to the right address.
############################################

section "Wiring Step 1 — pool_contract::set_contracts"

# ORACLE_ADDRESS defaults to the deployer; override via env var if needed
ORACLE_ADDRESS=${ORACLE_ADDRESS:-$ACTIVE_ADDRESS}

if [[ -z "$POOL_STATE_ID" || -z "$ADMIN_CAP_ID" || \
      -z "$TRANCHE_REGISTRY_ID" || -z "$WATERFALL_STATE_ID" ]]; then
    echo "  ⚠ Skipping set_contracts — one or more required IDs not found."
    echo "    Set POOL_STATE_ID, ADMIN_CAP_ID, TRANCHE_REGISTRY_ID, WATERFALL_STATE_ID"
    echo "    and ORACLE_ADDRESS manually, then call set_contracts yourself."
else
    log "Linking downstream contracts on PoolState..."
    log "  tranche_factory:   $TRANCHE_REGISTRY_ID"
    log "  issuance_contract: $ACTIVE_ADDRESS (placeholder — update after create-state)"
    log "  waterfall_engine:  $WATERFALL_STATE_ID"
    log "  oracle_address:    $ORACLE_ADDRESS"

    iota client ptb \
        --move-call "${PACKAGE_ID}::pool_contract::set_contracts" \
            "@${ADMIN_CAP_ID}" \
            "@${POOL_STATE_ID}" \
            "@${TRANCHE_REGISTRY_ID}" \
            "@${ACTIVE_ADDRESS}" \
            "@${WATERFALL_STATE_ID}" \
            "@${ORACLE_ADDRESS}" \
        --gas-budget 50000000 \
        >/dev/null 2>&1

    ok "set_contracts executed"
fi

############################################
# Wiring Step 2 — tranche_factory::bootstrap
# Extracts TreasuryCaps from the three coin
# parking wrappers and injects them into
# TrancheRegistry. Must happen before
# create_tranches.
############################################

section "Wiring Step 2 — tranche_factory::bootstrap"

if [[ -z "$TRANCHE_ADMIN_CAP_ID" || -z "$TRANCHE_REGISTRY_ID" || \
      -z "$SENIOR_TREASURY_ID"   || -z "$MEZZ_TREASURY_ID"    || \
      -z "$JUNIOR_TREASURY_ID" ]]; then
    echo "  ⚠ Skipping bootstrap — one or more treasury IDs not found."
    echo "    Set TRANCHE_ADMIN_CAP_ID, TRANCHE_REGISTRY_ID,"
    echo "    SENIOR_TREASURY_ID, MEZZ_TREASURY_ID, JUNIOR_TREASURY_ID manually."
else
    log "Injecting TreasuryCaps into TrancheRegistry..."
    log "  SeniorTreasury: $SENIOR_TREASURY_ID"
    log "  MezzTreasury:   $MEZZ_TREASURY_ID"
    log "  JuniorTreasury: $JUNIOR_TREASURY_ID"

    iota client ptb \
        --move-call "${PACKAGE_ID}::tranche_factory::bootstrap" \
            "@${TRANCHE_ADMIN_CAP_ID}" \
            "@${TRANCHE_REGISTRY_ID}" \
            "@${SENIOR_TREASURY_ID}" \
            "@${MEZZ_TREASURY_ID}" \
            "@${JUNIOR_TREASURY_ID}" \
        --gas-budget 50000000 \
        >/dev/null 2>&1

    ok "bootstrap executed — TreasuryCaps injected"
fi

############################################
# Save deployment manifest
############################################

section "Saving Deployment Manifest"

cat > "$MANIFEST_FILE" <<EOF
{
  "network":               "$NETWORK",
  "timestamp":             "$TIMESTAMP",
  "txDigest":              "$TX_DIGEST",
  "packageId":             "$PACKAGE_ID",
  "activeAddress":         "$ACTIVE_ADDRESS",
  "objects": {
    "poolState":            "$POOL_STATE_ID",
    "complianceRegistry":   "$COMPLIANCE_REGISTRY_ID",
    "trancheRegistry":      "$TRANCHE_REGISTRY_ID",
    "waterfallState":       "$WATERFALL_STATE_ID",
    "seniorTreasury":       "$SENIOR_TREASURY_ID",
    "mezzTreasury":         "$MEZZ_TREASURY_ID",
    "juniorTreasury":       "$JUNIOR_TREASURY_ID"
  },
  "caps": {
    "adminCap":             "$ADMIN_CAP_ID",
    "oracleCap":            "$ORACLE_CAP_ID",
    "complianceAdminCap":   "$COMPLIANCE_ADMIN_CAP_ID",
    "trancheAdminCap":      "$TRANCHE_ADMIN_CAP_ID",
    "waterfallAdminCap":    "$WATERFALL_ADMIN_CAP_ID",
    "issuanceOwnerCap":     "$ISSUANCE_OWNER_CAP_ID",
    "vaultAdminCap":        "$VAULT_ADMIN_CAP_ID"
  }
}
EOF

ok "Manifest saved → $MANIFEST_FILE"

############################################
# Print .env block for the API
############################################

section "Copy this into your API .env file"

cat <<EOF
IOTA_NETWORK=$NETWORK
PACKAGE_ID=$PACKAGE_ID

# Shared objects
POOL_STATE_ID=$POOL_STATE_ID
COMPLIANCE_REGISTRY_ID=$COMPLIANCE_REGISTRY_ID
TRANCHE_REGISTRY_ID=$TRANCHE_REGISTRY_ID
WATERFALL_STATE_ID=$WATERFALL_STATE_ID
SENIOR_TREASURY_ID=$SENIOR_TREASURY_ID
MEZZ_TREASURY_ID=$MEZZ_TREASURY_ID
JUNIOR_TREASURY_ID=$JUNIOR_TREASURY_ID

# Capability objects
ADMIN_CAP_ID=$ADMIN_CAP_ID
ORACLE_CAP_ID=$ORACLE_CAP_ID
COMPLIANCE_ADMIN_CAP_ID=$COMPLIANCE_ADMIN_CAP_ID
TRANCHE_ADMIN_CAP_ID=$TRANCHE_ADMIN_CAP_ID
WATERFALL_ADMIN_CAP_ID=$WATERFALL_ADMIN_CAP_ID
ISSUANCE_OWNER_CAP_ID=$ISSUANCE_OWNER_CAP_ID
VAULT_ADMIN_CAP_ID=$VAULT_ADMIN_CAP_ID
EOF

############################################
# Next steps
############################################

section "Next Steps"

cat <<EOF
  The following Phase 1 steps still require manual API calls:

  3.  POST /api/v1/pool/initialise
        — set pool_id, originator, spv, totalPoolValue, interestRate,
          maturityDate, assetHash

  4.  POST /api/v1/pool/activate

  5.  POST /api/v1/tranches/create
        — set seniorCap, mezzCap, juniorCap, issuanceContract

  6.  POST /api/v1/vault/create
        — set coinType

  7.  POST /api/v1/vault/authorise-depositor
        — depositor = IssuanceState object address (created in step 8)

  8.  POST /api/v1/issuance/create-state
        — set coinType; note the returned object ID for step 7

  9.  POST /api/v1/waterfall/initialise
        — set per-tranche outstanding amounts, rates, paymentFrequency

  Then proceed with Phase 2 (KYC) through Phase 7 (Maturity).
  See the deployment guide for full details.
EOF

echo