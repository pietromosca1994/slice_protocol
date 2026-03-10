# IOTA Securitization Protocol — TypeScript REST API

A production-ready Express API that exposes every entry-point of the IOTA Securitization Protocol Move contracts as HTTP endpoints. Supports **mainnet**, **testnet**, and **localnet** transparently.

---

## Architecture

```
src/
├── config/          # Env config & Winston logger
├── middleware/       # Network resolver, error handler
├── services/         # One service file per Move module
│   ├── iotaClient.ts        # SDK client, signer, PTB helper
│   ├── poolService.ts       # pool_contract module
│   ├── complianceService.ts # compliance_registry module
│   ├── trancheService.ts    # tranche_factory module
│   ├── issuanceService.ts   # issuance_contract module
│   ├── vaultService.ts      # payment_vault module
│   └── waterfallService.ts  # waterfall_engine module
├── routes/           # Express routers — one per domain
├── types/            # TypeScript interfaces mirroring Move structs
└── index.ts          # App bootstrap
```

---

## Quick Start

### 1. Configure environment

```bash
cp .env.example .env
# Fill in PACKAGE_ID, object IDs, cap IDs, and SIGNER_PRIVATE_KEY
```

### 2. Run locally

```bash
npm install
npm run dev         # ts-node-dev (hot reload)
# or
npm run build && npm start
```

### 3. Run with Docker

```bash
# Build & run (reads .env automatically)
docker compose up --build

# Or just the image
docker build -t iota-sec-api .
docker run --env-file .env -p 3000:3000 iota-sec-api
```

---

## Network Selection

Every request can target a specific network via:

| Method | Example |
|--------|---------|
| Query param | `GET /api/v1/pool?network=mainnet` |
| Header | `X-IOTA-Network: testnet` |
| Default | `IOTA_NETWORK` env var (fallback: `testnet`) |

---

## API Reference

### Health

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Service health + config summary |

---

### Pool Contract — `/api/v1/pool`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | — | Read current PoolState |
| POST | `/set-contracts` | AdminCap | Link downstream contract addresses |
| POST | `/initialise` | AdminCap | Initialise pool parameters |
| POST | `/activate` | AdminCap | Created → Active |
| POST | `/update-performance` | OracleCap | Update outstanding principal |
| POST | `/mark-default/oracle` | OracleCap | Active → Defaulted |
| POST | `/mark-default/admin` | AdminCap | Active → Defaulted |
| POST | `/close` | AdminCap | Any → Matured |

**POST /pool/initialise body:**
```json
{
  "poolId": "POOL-001",
  "originator": "0xABC...",
  "spv": "0xDEF...",
  "totalPoolValue": "10000000000",
  "interestRate": 500,
  "maturityDate": "1893456000000",
  "assetHash": "abcdef1234567890..."
}
```

---

### Compliance Registry — `/api/v1/compliance`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | — | Registry state (restrictions flag, default holding period) |
| GET | `/investor/:address` | — | Fetch single InvestorRecord |
| POST | `/restrictions` | ComplianceAdminCap | Toggle global transfer restrictions |
| POST | `/default-holding-period` | ComplianceAdminCap | Set default lock-up (ms) |
| POST | `/investors` | ComplianceAdminCap | Add investor to whitelist |
| DELETE | `/investors/:address` | ComplianceAdminCap | Deactivate investor |
| PATCH | `/investors/:address/accreditation` | ComplianceAdminCap | Update accreditation level |

**POST /compliance/investors body:**
```json
{
  "investor": "0xABC...",
  "accreditationLevel": 3,
  "jurisdiction": "US",
  "didObjectId": "0xDID...",
  "customHoldingMs": "7776000000"
}
```

**Accreditation levels:** 1=Retail, 2=Professional, 3=Institutional, 4=Qualified Purchaser

---

### Tranche Factory — `/api/v1/tranches`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | — | Full TrancheRegistry state |
| GET | `/:type` | — | TrancheInfo for type 0/1/2 |
| POST | `/bootstrap` | TrancheAdminCap | Inject TreasuryCaps from coin wrappers |
| POST | `/create` | TrancheAdminCap | Set supply caps and enable minting |
| POST | `/disable-minting` | TrancheAdminCap | Permanently disable minting |
| POST | `/melt/senior` | — | Burn SENIOR_COIN tokens |
| POST | `/melt/mezz` | — | Burn MEZZ_COIN tokens |
| POST | `/melt/junior` | — | Burn JUNIOR_COIN tokens |

---

### Issuance Contract — `/api/v1/issuance`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/:stateId` | — | IssuanceState for given object ID |
| POST | `/create-state` | IssuanceOwnerCap | Create new IssuanceState shared object |
| POST | `/start` | IssuanceOwnerCap | Open subscription window |
| POST | `/end` | IssuanceOwnerCap | Close subscription window |
| POST | `/invest` | — (KYC-gated on-chain) | Subscribe to a tranche |
| POST | `/refund` | — | Claim refund if issuance cancelled |
| POST | `/release-to-vault` | IssuanceOwnerCap | Release raised funds to PaymentVault |

**POST /issuance/start body:**
```json
{
  "issuanceStateId": "0xISS...",
  "coinType": "0xPKG::usdc::USDC",
  "saleStart": "1700000000000",
  "saleEnd": "1702592000000",
  "priceSenior": "1000000",
  "priceMezz": "1000000",
  "priceJunior": "1000000"
}
```

---

### Payment Vault — `/api/v1/vault`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/:vaultId` | — | VaultBalance state |
| POST | `/create` | VaultAdminCap | Create new VaultBalance shared object |
| POST | `/authorise-depositor` | VaultAdminCap | Grant deposit rights |
| POST | `/revoke-depositor` | VaultAdminCap | Revoke deposit rights |
| POST | `/deposit` | Authorised depositor | Deposit coin into vault |
| POST | `/release` | VaultAdminCap | Release funds to recipient |

---

### Waterfall Engine — `/api/v1/waterfall`

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/` | — | Full WaterfallState |
| POST | `/initialise` | WaterfallAdminCap | Set tranche amounts + rates |
| POST | `/accrue-interest` | — | Accrue interest since last timestamp |
| POST | `/deposit-payment` | — | Record incoming pool repayment |
| POST | `/run` | — | Execute full waterfall distribution |
| POST | `/turbo-mode` | WaterfallAdminCap | Activate Turbo mode |
| POST | `/default-mode/admin` | WaterfallAdminCap | Activate Default mode |
| POST | `/default-mode/pool` | PoolCap | Activate Default mode (from pool) |

---

## Response Format

All endpoints return:

```json
{
  "success": true,
  "data": { ... },
  "network": "testnet"
}
```

Write endpoints additionally include:

```json
{
  "success": true,
  "data": {
    "txDigest": "ABC123...",
    "status": "success",
    "gasUsed": "{ ... }"
  },
  "network": "testnet"
}
```

Error responses:

```json
{
  "success": false,
  "error": "Descriptive error message",
  "network": "testnet"
}
```

---

## Security Notes

- **Never commit** `SIGNER_PRIVATE_KEY` to source control. Use Docker secrets, AWS Secrets Manager, or Vault in production.
- The signer key should hold only the minimum capability objects needed for the operations you expose.
- Consider adding an API key middleware (`X-API-Key` header) in front of all write endpoints before exposing this service publicly.
- The `set_transfer_restrictions(enabled: false)` endpoint bypasses all KYC checks — restrict access accordingly.
