# Slice Protocol

On-chain securitization engine built on IOTA. Tokenises pools of illiquid financial assets
(loans, mortgages, receivables) into tradeable Senior / Mezzanine / Junior tranche tokens,
with a fully automated payment waterfall and KYC-gated issuance.

---

## Setup

### 0. Prerequisites

- **IOTA CLI** installed (`iota` in PATH)
- **Node.js 20+** and **npm**
- A funded IOTA wallet

Export your wallet's private key for the API:

```bash
iota keytool import "<mnemonic words>" ed25519
iota keytool export <your-address>   # copy the iotaprivkey1... value
```

---

### 1. Run a Local IOTA Node (localnet only)

```bash
RUST_LOG="off,iota_node=info" iota start --force-regenesis --with-faucet

iota client new-env --alias local --rpc http://127.0.0.1:9000
iota client switch --env local
iota client faucet
```

> Explorer: https://explorer.iota.org/?network=http%3A%2F%2F127.0.0.1%3A9000

---

### 2. Deploy the SPV Package (one-time)

The `packages/spv` package is a singleton. Deploy it once per environment:

```bash
cd packages/spv
iota move build
iota client publish .
```

From the output, note:
- The **package ID** (starts with `0x`, labelled `Published Objects`)
- The **SPVRegistry object ID** (look for `spv::spv_registry::SPVRegistry` in created objects)

---

### 3. Configure and Start the API

```bash
cd api
cp .env.example .env
```

Edit `.env`:

```
IOTA_NETWORK=localnet           # or testnet / mainnet
SPV_REGISTRY_ID=0x<registry>   # from step 2
SPV_PACKAGE_ID=0x<package>     # from step 2
ADMIN_SECRET_KEY=iotaprivkey1…  # from step 0
```

```bash
npm install
npm run dev
```

Verify:
```bash
curl http://localhost:3000/health
```

---

## Full Use Case Walkthrough

The scenario below follows **GreenLend Capital**, an SPV that securitises a portfolio of
US commercial real estate loans (total value **$10 million USDC**) into three risk tranches.
Investors subscribe during a two-week window; repayments are distributed quarterly.

All amounts are in USDC base units (6 decimals): `10_000_000 USDC = 10_000_000_000_000 units`.
For brevity this example uses smaller numbers (`10_000_000_000` ≈ $10,000 USDC) and
`0x2::iota::IOTA` as the stablecoin.

---

### Step 1 — Create the Pool

One call deploys a fresh securitization package and atomically creates, wires, and activates
the pool. If anything fails mid-way, the `SPVRegistry` is left untouched.

```bash
curl -X POST http://localhost:3000/pools \
  -H "Content-Type: application/json" \
  -d '{
    "spv":            "0xSPV_ADDRESS",
    "poolId":         "GREENLEND-CRE-2025-001",
    "originator":     "0xORIGINATOR_ADDRESS",
    "totalPoolValue": "10000000000",
    "interestRate":   750,
    "maturityDate":   1924992000000,
    "assetHash":      "a3f1c2d4e5b6a7c8d9e0f1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b1c2",
    "oracleAddress":  "0xORACLE_ADDRESS",
    "seniorSupplyCap":  "5000",
    "mezzSupplyCap":    "3000",
    "juniorSupplyCap":  "2000",
    "seniorFaceValue":  "6000000000",
    "mezzFaceValue":    "2500000000",
    "juniorFaceValue":  "1500000000",
    "seniorRateBps":    400,
    "mezzRateBps":      700,
    "juniorRateBps":    1500,
    "paymentFrequency": 1,
    "coinType":         "0x2::iota::IOTA"
  }'
```

Field notes:
- `interestRate` — blended pool rate in basis points (750 = 7.5%)
- `maturityDate` — UNIX timestamp in ms (2031-01-01)
- `assetHash` — SHA-256 hex of the off-chain loan agreement bundle
- `seniorFaceValue` / `mezzFaceValue` / `juniorFaceValue` — principal allocated to each tranche; token price = `faceValue / supplyCap`
- `seniorRateBps` / `mezzRateBps` / `juniorRateBps` — per-tranche waterfall distribution rates
- `paymentFrequency` — `0` = Monthly, `1` = Quarterly

Save the response IDs — you'll use them throughout:

```json
{
  "poolStateId":             "0xPOOL",
  "securitizationPackageId": "0xPKG",
  "issuanceStateId":         "0xISSUANCE",
  "vaultId":                 "0xVAULT"
}
```

Verify on-chain:
```bash
curl http://localhost:3000/registry/pools/0xPOOL | jq '{status: .pool.status, issuanceActive: .issuance.issuanceActive}'
# → {"status":"Active","issuanceActive":false}
```

---

### Step 2 — KYC Investors

Before the subscription window opens, whitelist investors in `ComplianceRegistry`.
Deploy one via `iota client publish packages/spv` (or use an existing one).

```bash
COMPLIANCE_REG_ID=0xCOMPLIANCE_REGISTRY

# Whitelist Alice (institutional investor, 90-day holding period)
curl -X POST http://localhost:3000/compliance/$COMPLIANCE_REG_ID/investors \
  -H "Content-Type: application/json" \
  -d '{
    "investor":           "0xALICE_ADDRESS",
    "accreditationLevel": 3,
    "jurisdiction":       "US",
    "didObjectId":        "0xALICE_DID",
    "customHoldingMs":    7776000000
  }'

# Whitelist Bob (professional investor, default holding period)
curl -X POST http://localhost:3000/compliance/$COMPLIANCE_REG_ID/investors \
  -H "Content-Type: application/json" \
  -d '{
    "investor":           "0xBOB_ADDRESS",
    "accreditationLevel": 2,
    "jurisdiction":       "GB",
    "didObjectId":        "0xBOB_DID",
    "customHoldingMs":    0
  }'
```

Verify Alice:
```bash
curl http://localhost:3000/compliance/$COMPLIANCE_REG_ID/investor/0xALICE_ADDRESS | jq .
# → {"whitelisted":true,"accreditationLevel":3,"jurisdiction":"US",...}
```

Check if a transfer between them is currently allowed:
```bash
curl "http://localhost:3000/compliance/$COMPLIANCE_REG_ID/transfer-check?from=0xALICE_ADDRESS&to=0xBOB_ADDRESS" | jq .
# → {"allowed":false,"issues":["Sender in holding period"]}  (holding period just started)
```

---

### Step 3 — Open the Subscription Window

```bash
NOW_MS=$(date +%s%3N)
SALE_START=$(( NOW_MS + 60000 ))          # 1 minute from now
SALE_END=$(( NOW_MS + 60000 + 1209600000 )) # + 14 days

curl -X POST http://localhost:3000/pools/0xPOOL/issuance/start \
  -H "Content-Type: application/json" \
  -d "{\"saleStart\": $SALE_START, \"saleEnd\": $SALE_END}"
# → {"digest":"0x..."}
```

Check state:
```bash
curl http://localhost:3000/registry/pools/0xPOOL/issuance | jq '{issuanceActive, prices}'
# → {"issuanceActive":true,"prices":{"senior":"1200000","mezz":"833333","junior":"750000"}}
```

---

### Step 4 — Investors Subscribe

The signer's wallet pays stablecoin; tranche tokens are minted directly to the investor.

```bash
# Alice buys 10 Senior tokens (10 × 1,200,000 = 12,000,000 units)
curl -X POST http://localhost:3000/pools/0xPOOL/issuance/invest \
  -H "Content-Type: application/json" \
  -d "{
    \"trancheType\":          0,
    \"amount\":               \"12000000\",
    \"complianceRegistryId\": \"$COMPLIANCE_REG_ID\"
  }"

# Bob buys 5 Mezzanine tokens (5 × 833,333 = 4,166,665 units)
curl -X POST http://localhost:3000/pools/0xPOOL/issuance/invest \
  -H "Content-Type: application/json" \
  -d "{
    \"trancheType\":          1,
    \"amount\":               \"4166665\",
    \"complianceRegistryId\": \"$COMPLIANCE_REG_ID\"
  }"
```

- `trancheType`: `0` = Senior, `1` = Mezzanine, `2` = Junior

Check minted supply:
```bash
curl http://localhost:3000/registry/pools/0xPOOL/tranches | jq '{seniorMinted, mezzMinted, totalRaised}'
```

---

### Step 5 — Close Issuance and Release Funds to Vault

After the sale window closes (or early if fully subscribed):

```bash
# Close the subscription window
curl -X POST http://localhost:3000/pools/0xPOOL/issuance/end
# → {"digest":"0x..."}

# Move raised funds from IssuanceState into the PaymentVault
curl -X POST http://localhost:3000/pools/0xPOOL/issuance/release
# → {"digest":"0x..."}
```

Verify vault balance:
```bash
curl http://localhost:3000/vault/0xVAULT | jq .
# → {"balance":"16166665","totalDeposited":"16166665","totalDistributed":"0"}
```

---

### Step 6 — Quarterly Repayment Cycle

GreenLend's borrowers make their first quarterly repayment. The operator records it and
runs the waterfall to distribute to tranche holders in strict seniority order.

```bash
# Record a repayment of 500,000 units into the waterfall
curl -X POST http://localhost:3000/pools/0xPOOL/waterfall/deposit \
  -H "Content-Type: application/json" \
  -d '{"amount": "500000"}'

# Accrue interest since last distribution
curl -X POST http://localhost:3000/pools/0xPOOL/waterfall/accrue

# Run the waterfall: Senior paid first, then Mezz, then Junior, surplus to reserve
curl -X POST http://localhost:3000/pools/0xPOOL/waterfall/run
```

Check post-waterfall state:
```bash
curl http://localhost:3000/registry/pools/0xPOOL/waterfall | jq \
  '{seniorOutstanding, mezzOutstanding, juniorOutstanding, reserveAccount, pendingFunds}'
```

Repeat each quarter: `deposit → accrue → run`.

---

### Step 7 — Turbo Mode (Optional Early Repayment)

If the borrower makes a large prepayment and the SPV wants to accelerate principal
reduction on all tranches:

```bash
curl -X POST http://localhost:3000/pools/0xPOOL/waterfall/turbo
# Waterfall mode → Turbo; principal now repaid proportionally across all tranches
```

---

### Step 8 — Default Scenario (Optional)

If the borrower stops paying, the SPV or oracle triggers default:

```bash
curl -X POST http://localhost:3000/pools/0xPOOL/default
# Pool status → Defaulted; waterfall mode → Default (recovery priority)
```

In Default mode the waterfall still distributes whatever funds arrive,
Senior tranche retains priority.

---

### Step 9 — Mature the Pool

Once all outstanding principal is repaid (or by contractual maturity date):

```bash
curl -X POST http://localhost:3000/pools/0xPOOL/close
# Pool status → Matured; no further repayments accepted
```

---

## Lifecycle Summary

```
POST /pools
  ├─ tx 1: deploy securitization package
  └─ tx 2: atomic PTB → create + wire + activate (SPVRegistry updated only on success)
       ↓
  Pool: Active

POST /compliance/:regId/investors     ← KYC investors any time before issuance
       ↓
POST /pools/:id/issuance/start        ← open subscription window
POST /pools/:id/issuance/invest       ← investors buy tranche tokens (repeatable)
POST /pools/:id/issuance/end          ← close window
POST /pools/:id/issuance/release      ← move raised funds to PaymentVault
       ↓
  [Quarterly cycle]
POST /pools/:id/waterfall/deposit     ← record repayment from borrower
POST /pools/:id/waterfall/accrue      ← accrue interest
POST /pools/:id/waterfall/run         ← distribute Senior → Mezz → Junior → Reserve
       ↓
  [Optional]
POST /pools/:id/waterfall/turbo       ← accelerate principal repayment
POST /pools/:id/default               ← trigger default (Pool → Defaulted)
       ↓
POST /pools/:id/close                 ← Pool → Matured
```

| Phase | Pool Status | Waterfall Mode |
|-------|-------------|----------------|
| Creation | `Created → Active` | — |
| KYC / Issuance | `Active` | — |
| Servicing | `Active` | Normal |
| Accelerated repayment | `Active` | Turbo |
| Recovery | `Defaulted` | Default |
| Fully repaid | `Matured` | — |

---

## Multiple Pools

Each `POST /pools` call deploys its own `securitizationPackageId`. Pools are completely
self-contained — different stablecoins, different maturities, different tranche ratios.
The `SPVRegistry` is the single enumeration point for all pools:

```bash
curl http://localhost:3000/registry/pools        # all pools
curl http://localhost:3000/registry/spv/0xSPV/pools  # pools owned by a specific SPV
```

---

See `api/README.md` for the full API reference.
