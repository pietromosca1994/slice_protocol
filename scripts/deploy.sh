#!/usr/bin/env bash
set -euo pipefail

############################################
# Configuration
############################################

NETWORK=${NETWORK:-local}
PACKAGE_PATH=${PACKAGE_PATH:-./packages/securitization}
OUTPUT_DIR=${OUTPUT_DIR:-deployments}

mkdir -p "$OUTPUT_DIR"

TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
RAW_OUTPUT_FILE="$OUTPUT_DIR/publish_${NETWORK}_${TIMESTAMP}.json"

############################################
# Network selection
############################################

case "$NETWORK" in
    mainnet) RPC="https://api.mainnet.iota.cafe:443" ;;
    testnet) RPC="https://api.testnet.iota.cafe:443" ;;
    local)   RPC="http://127.0.0.1:9000" ;;
    *)
        echo "ERROR: Unknown network '$NETWORK'"
        exit 1
        ;;
esac

############################################
# Configure IOTA client
############################################

echo "Using network: $NETWORK"

iota client switch --env "$NETWORK" >/dev/null 2>&1 || \
iota client new-env --alias "$NETWORK" --rpc "$RPC"

iota client switch --env "$NETWORK"
iota client faucet

############################################
# Publish package
############################################

echo
echo "Publishing package:"
echo "  Path:    $PACKAGE_PATH"
echo "  Network: $NETWORK"
echo

PUBLISH_OUTPUT=$(iota client publish "$PACKAGE_PATH" --json 2>&1)

############################################
# Extract JSON safely
############################################

JSON_OUTPUT=$(echo "$PUBLISH_OUTPUT" | awk 'BEGIN{json=0} /^\{/ {json=1} json')

if ! echo "$JSON_OUTPUT" | jq empty >/dev/null 2>&1; then
    echo "ERROR: Could not extract valid JSON from publish output"
    echo
    echo "$PUBLISH_OUTPUT"
    exit 1
fi

echo "$JSON_OUTPUT" > "$RAW_OUTPUT_FILE"

############################################
# Parse deployment info
############################################

TX_DIGEST=$(jq -r '.digest // empty' <<< "$JSON_OUTPUT")

PACKAGE_ID=$(jq -r '
    .objectChanges[]
    | select(.type=="published")
    | .packageId
' <<< "$JSON_OUTPUT")

CREATED_OBJECTS=$(jq -r '
    .objectChanges[]
    | select(.type=="created")
    | "\(.objectType)  ->  \(.objectId)"
' <<< "$JSON_OUTPUT")

UPDATED_OBJECTS=$(jq -r '
    .objectChanges[]?
    | select(.type=="mutated")
    | "\(.objectType)  ->  \(.objectId)"
' <<< "$JSON_OUTPUT")

############################################
# Summary
############################################

echo
echo "======================================"
echo "DEPLOYMENT SUCCESSFUL"
echo "======================================"

printf "%-22s %s\n" "Network:" "$NETWORK"
printf "%-22s %s\n" "Transaction Digest:" "$TX_DIGEST"
printf "%-22s %s\n" "Package ID:" "$PACKAGE_ID"
printf "%-22s %s\n" "Output File:" "$RAW_OUTPUT_FILE"

if [[ -n "$CREATED_OBJECTS" ]]; then
    echo
    echo "Created Objects:"
    echo "--------------------------------------"
    echo "$CREATED_OBJECTS"
fi

if [[ -n "$UPDATED_OBJECTS" ]]; then
    echo
    echo "Updated Objects:"
    echo "--------------------------------------"
    echo "$UPDATED_OBJECTS"
fi

echo
echo "Done."
