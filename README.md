# Slice Protocol — Deployment Guide

---

## 0. Prerequisites — Get Your Private Key

Import your wallet mnemonic and export the private key for the API:

```bash
iota keytool import "<mnemonic words>" <key_scheme>
iota keytool list
iota keytool export <address>
```

Copy the `iotaprivkey1...` value and base64-encode it for `ADMIN_SECRET_KEY` in your `.env` file.

---

## 1. Run a Local IOTA Network (localnet only)

> **Reference:** [IOTA Local Development Docs](https://docs.iota.org/developer/getting-started/local-network)

Start the local node with faucet:

```bash
RUST_LOG="off,iota_node=info" iota start --force-regenesis --with-faucet
```

Configure and fund the CLI client:

```bash
iota client new-env --alias local --rpc http://127.0.0.1:9000
iota client switch --env local
iota client active-address
iota client faucet
```

> Local Explorer: https://explorer.iota.org/?network=http%3A%2F%2F127.0.0.1%3A9000

---

## 2. Deploy the SPV Package (one-time)

The SPV package (`packages/spv`) is a singleton — deploy it once and configure the API with its
object IDs. It hosts the `SPVRegistry`, `ComplianceRegistry`, and `PaymentVault`.

```bash
cd packages/spv
iota move build
iota client publish .
```

Note the `SPVRegistry` object ID and the package ID from the output and copy them into `.env`.

---

## 3. Configure the API

```bash
cd api
cp .env.example .env
```

Edit `.env`:

```
IOTA_NETWORK=testnet          # or localnet / mainnet
SPV_REGISTRY_ID=0x...         # SPVRegistry object ID from step 2
SPV_PACKAGE_ID=0x...          # SPV package ID from step 2
ADMIN_SECRET_KEY=             # base64 Ed25519 private key (leave empty for read-only)
```

No `SECURITIZATION_PACKAGE_ID` is needed — the API deploys a fresh securitization package for
each pool automatically when `POST /pools` is called.

---

## 4. Start the API

```bash
cd api
npm install
npm run dev
# or with Docker:
docker compose up -d
```

Check connectivity:
```bash
curl http://localhost:3000/health
```

---

## 5. Create a Pool

A single `POST /pools` call deploys the securitization package, creates the pool, sets all
contract links, initialises the waterfall, and activates the pool:

```bash
curl -X POST http://localhost:3000/pools \
  -H "Content-Type: application/json" \
  -d '{
    "spv":            "0xSPV_ADDRESS",
    "poolId":         "POOL-2025-001",
    "originator":     "0xORIGINATOR_ADDRESS",
    "totalPoolValue": "10000000000",
    "interestRate":   500,
    "maturityDate":   1893456000000,
    "assetHash":      "abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234abcd1234",
    "oracleAddress":  "0xORACLE_ADDRESS",
    "seniorSupplyCap":  "5000",
    "mezzSupplyCap":    "3000",
    "juniorSupplyCap":  "2000",
    "seniorFaceValue":  "5000000000",
    "mezzFaceValue":    "3000000000",
    "juniorFaceValue":  "2000000000",
    "seniorRateBps":    300,
    "mezzRateBps":      600,
    "juniorRateBps":    1200,
    "paymentFrequency": 0,
    "coinType":         "0x2::iota::IOTA"
  }'
```

Response:
```json
{
  "poolStateId":             "0x...",
  "securitizationPackageId": "0x...",
  "issuanceStateId":         "0x..."
}
```

Each pool gets its own `securitizationPackageId`. Create multiple pools by repeating the call —
each is fully self-contained.

---

## 6. Pool Lifecycle

```
POST /pools                              Pool created and Active
POST /compliance/:regId/investors        Whitelist investors (KYC)
POST /pools/:id/issuance/start           Open subscription window
POST /pools/:id/issuance/invest          Investor subscribes (signer's wallet pays)
POST /pools/:id/issuance/end             Close subscription window
POST /pools/:id/waterfall/deposit        Record repayment
POST /pools/:id/waterfall/accrue         Accrue interest
POST /pools/:id/waterfall/run            Distribute (Senior → Mezz → Junior → Reserve)
POST /pools/:id/close                    Mature the pool
```

See `api/README.md` for full API reference and `USE_CASE.md` for the business logic walkthrough.

---

## Quick Reference — Lifecycle Summary

```
[Deploy SPV] ──► [Configure API] ──► [POST /pools] ──► [KYC] ──► [Issuance] ──► [Servicing] ──► [Maturity]
                                                                                      │
                                                                           ┌──────────┴──────────┐
                                                                        Turbo Mode          Default Mode
                                                                     (accelerate)           (recovery)
```

| Phase | Pool Status | Waterfall Mode |
|-------|-------------|----------------|
| Creation | `Created → Active` | — |
| KYC | `Active` | — |
| Issuance | `Active` | — |
| Servicing | `Active` | Normal |
| Turbo | `Active` | Turbo |
| Default | `Defaulted` | Default |
| Maturity | `Matured` | — |

---
