# Securitization Protocol API

REST API for the IOTA Securitization Protocol. Exposes read and write operations
for all on-chain contracts via HTTP. The API is fully self-describing from a single
env var — it discovers all pool and contract data by traversing the on-chain
`SPVRegistry` object.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `IOTA_NETWORK` | Yes | `testnet` \| `mainnet` \| `devnet` \| `localnet` |
| `SPV_REGISTRY_ID` | Yes | Object ID of the shared `SPVRegistry` |
| `SPV_PACKAGE_ID` | Yes | Published package ID of the `spv` package |
| `SECURITIZATION_PACKAGE_ID` | Yes | Published package ID of the `securitization` package |
| `ADMIN_SECRET_KEY` | No | Base64 Ed25519 private key. Omit for read-only mode. |
| `PORT` | No | Server port (default `3000`) |
| `LOG_LEVEL` | No | `fatal`/`error`/`warn`/`info`/`debug`/`trace` (default `info`) |
| `GAS_BUDGET` | No | Gas budget per transaction in MIST (default `100000000`) |
| `IOTA_RPC_URL` | No | Override RPC URL (defaults to network standard) |

The API derives all other addresses (TrancheRegistry, IssuanceState, WaterfallState)
by reading the `PoolState` objects that are indexed in the `SPVRegistry`.

---

## Running with Docker

```bash
# 1. Copy and fill in env
cp .env.example .env

# 2. Build and start
docker compose up -d

# 3. Check health
curl http://localhost:3000/health
```

## Running locally

```bash
npm install
cp .env.example .env   # fill in values
npm run dev
```

---

## API Reference

### Health

#### `GET /health`
Returns node connectivity status and API configuration.

```json
{
  "status": "ok",
  "network": "testnet",
  "chainId": "...",
  "readOnly": false,
  "spvRegistryId": "0x..."
}
```

---

### Registry (read-only)

#### `GET /registry`
Returns SPVRegistry metadata.
```json
{ "poolCount": 3, "packageIds": { "spv": "0x...", "securitization": "0x..." } }
```

#### `GET /registry/pools`
Returns all pool summaries (reads every PoolState object indexed in the registry).

#### `GET /registry/pools/:poolObjId`
Returns full pool detail including tranches, issuance state, and waterfall state.

#### `GET /registry/pools/:poolObjId/tranches`
Returns TrancheRegistry state for the pool.

#### `GET /registry/pools/:poolObjId/issuance`
Returns IssuanceState for the pool.

#### `GET /registry/pools/:poolObjId/waterfall`
Returns WaterfallState for the pool.

#### `GET /registry/spv/:spvAddress/pools`
Returns pool object IDs owned by a specific SPV address.
```json
{ "spv": "0x...", "poolIds": ["0x...", "0x..."] }
```

---

### Pools (write — requires ADMIN_SECRET_KEY)

All write endpoints return `{ "digest": "..." }` (the transaction digest) with
HTTP 202. The transaction is submitted and the response is returned immediately;
use the digest to poll for finality on-chain.

#### Pool lifecycle

```
POST /pools                           Create a new pool
POST /pools/:id/set-contracts         Link downstream contract addresses
POST /pools/:id/set-contract-objects  Link downstream shared object IDs (required for API traversal)
POST /pools/:id/initialise            Finalise pool + mint OracleCap
POST /pools/:id/activate              Created → Active
POST /pools/:id/default               Active → Defaulted
POST /pools/:id/close                 Active|Defaulted → Matured
```

##### `POST /pools` body
```json
{
  "spv":            "0x...",
  "poolId":         "POOL-2025-001",
  "originator":     "0x...",
  "totalPoolValue": "10000000000",
  "interestRate":   500,
  "maturityDate":   1893456000000,
  "assetHash":      "abcd1234...64hexchars",
  "oracleAddress":  "0x..."
}
```

##### `POST /pools/:id/set-contracts` body
```json
{
  "trancheFactory":   "0x...",
  "issuanceContract": "0x...",
  "waterfallEngine":  "0x...",
  "oracleAddress":    "0x..."
}
```

##### `POST /pools/:id/set-contract-objects` body
```json
{
  "trancheFactoryObj":   "0x...",
  "issuanceContractObj": "0x...",
  "waterfallEngineObj":  "0x..."
}
```

#### Issuance

```
POST /pools/:id/issuance/start    Open subscription window
POST /pools/:id/issuance/end      Close subscription window
```

##### `POST /pools/:id/issuance/start` body
```json
{
  "issuanceStateId": "0x...",
  "saleStart":       1700000000000,
  "saleEnd":         1702000000000,
  "priceSenior":     "1000000",
  "priceMezz":       "1000000",
  "priceJunior":     "1000000"
}
```

#### Waterfall

```
POST /pools/:id/waterfall/deposit   Record a pool repayment (amount as string)
POST /pools/:id/waterfall/accrue    Accrue interest since last distribution
POST /pools/:id/waterfall/run       Execute the waterfall distribution
POST /pools/:id/waterfall/turbo     Normal → Turbo mode
POST /pools/:id/waterfall/default   Any mode → Default mode
```

##### `POST /pools/:id/waterfall/deposit` body
```json
{ "amount": "5000000000" }
```

---

### Compliance (spv package)

#### `GET /compliance/:registryId/investor/:address`
Returns whitelist status and record for an investor address.
```json
{
  "address": "0x...",
  "whitelisted": true,
  "accreditationLevel": 2,
  "jurisdiction": "US",
  "holdingPeriodEnd": "2025-06-01T00:00:00.000Z",
  "active": true
}
```

#### `GET /compliance/:registryId/transfer-check?from=0x...&to=0x...`
Checks whether a transfer between two addresses is currently permitted.
```json
{
  "allowed": false,
  "from": "0x...",
  "to": "0x...",
  "issues": ["Sender in holding period"]
}
```

#### `POST /compliance/:registryId/investors` — requires key
```json
{
  "investor":           "0x...",
  "accreditationLevel": 2,
  "jurisdiction":       "US",
  "didObjectId":        "0x...",
  "customHoldingMs":    2592000000
}
```

#### `DELETE /compliance/:registryId/investors/:address` — requires key
Soft-removes (deactivates) an investor.

#### `PATCH /compliance/:registryId/investors/:address/accreditation` — requires key
```json
{ "newLevel": 3 }
```

---

### Vault (spv package)

#### `GET /vault/:vaultId`
Returns vault balance and accounting totals (all values as strings to preserve precision).
```json
{
  "vaultId":          "0x...",
  "balance":          "50000000000",
  "totalDeposited":   "100000000000",
  "totalDistributed": "50000000000"
}
```

#### `POST /vault/create` — requires key
```json
{ "coinType": "0x2::iota::IOTA" }
```

#### `POST /vault/:vaultId/authorise-depositor` — requires key
```json
{ "depositor": "0x...", "coinType": "0x2::iota::IOTA" }
```

#### `DELETE /vault/:vaultId/depositor/:depositor` — requires key
```json
{ "coinType": "0x2::iota::IOTA" }
```

#### `POST /vault/:vaultId/release` — requires key
```json
{
  "recipient": "0x...",
  "amount":    "10000000000",
  "coinType":  "0x2::iota::IOTA"
}
```

---

## Pool setup sequence

After deploying both packages, follow this sequence to bring a pool live:

```
1.  POST /pools                          → creates PoolState, registers in SPVRegistry
2.  (deploy TrancheFactory off-chain)    → get trancheFactoryId
3.  (deploy IssuanceState off-chain)     → get issuanceStateId
4.  (deploy WaterfallState off-chain)    → get waterfallStateId
5.  POST /pools/:id/set-contracts        → links deployer addresses
6.  POST /pools/:id/set-contract-objects → links shared object IDs (enables API traversal)
7.  POST /pools/:id/initialise           → mints OracleCap
8.  POST /pools/:id/activate             → pool is live
9.  POST /pools/:id/issuance/start       → opens subscription window
10. POST /compliance/:regId/investors    → whitelist investors
11. (investors call invest() directly)
12. POST /pools/:id/issuance/end         → closes subscription
13. POST /vault/:vaultId/release         → release funds to waterfall
14. POST /pools/:id/waterfall/run        → execute distribution
```

---

## Error responses

All errors follow:
```json
{ "error": "Human-readable message", "details": { ... } }
```

| Status | Meaning |
|---|---|
| 400 | Validation error — check `details` |
| 403 | Read-only mode or missing capability |
| 404 | Object not found |
| 500 | RPC or transaction error |
