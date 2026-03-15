# Securitization Protocol API

REST API for the Slice Protocol on-chain securitization engine (IOTA). Exposes read and write
operations for all on-chain contracts via HTTP. The API discovers all pool and contract data by
traversing the on-chain `SPVRegistry` object — only two env vars are required to get started.

Each pool gets its own freshly-deployed securitization package. `POST /pools` runs two
transactions: one package deploy and one atomic PTB that creates, wires, and activates all
contracts. If the PTB aborts for any reason the `SPVRegistry` is left untouched.

---

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `IOTA_NETWORK` | Yes | `testnet` \| `mainnet` \| `devnet` \| `localnet` |
| `SPV_REGISTRY_ID` | Yes | Object ID of the shared `SPVRegistry` |
| `SPV_PACKAGE_ID` | Yes | Published package ID of the `spv` package |
| `ADMIN_SECRET_KEY` | No | Base64 Ed25519 private key. Omit for read-only mode. |
| `PORT` | No | Server port (default `3000`) |
| `LOG_LEVEL` | No | `fatal`/`error`/`warn`/`info`/`debug`/`trace` (default `info`) |
| `GAS_BUDGET` | No | Gas budget per transaction in MIST (default `100000000`) |
| `IOTA_RPC_URL` | No | Override RPC URL (defaults to network standard) |
| `PACKAGES_PATH` | No | Absolute path to the repo's `packages/` directory. Auto-detected locally; set to `/app/packages` in Docker (done automatically by the Dockerfile). |

The API derives all per-pool addresses (TrancheRegistry, IssuanceState, WaterfallState,
securitization package ID) from the `PoolState` objects indexed in `SPVRegistry`.
No per-pool configuration is required.

---

## Running with Docker

The Docker build context must be the **repository root** (not `api/`) because the image
copies the `packages/` directory to compile Move contracts at runtime.

```bash
# Run from the repository root
cd ..

# 1. Copy and fill in env
cp api/.env.example api/.env

# 2. Build and start (IOTA_CLI_URL build arg must point at the correct binary for your platform)
#    See https://github.com/iotaledger/iota/releases for available downloads.
docker compose -f api/docker-compose.yml up -d

# 3. Check health
curl http://localhost:3000/health
```

> The Dockerfile installs the `iota` CLI via `IOTA_CLI_URL`. Update the default ARG in
> `api/Dockerfile` (or pass `--build-arg IOTA_CLI_URL=...`) to match the release binary for
> your platform and iota version.

## Running locally

```bash
npm install
cp .env.example .env   # fill in values
npm run dev
```

---

## Postman collection

Import `postman/slice-protocol.postman_collection.json` into Postman. Set the `base_url`
collection variable to your API instance (default `http://localhost:3000`).

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
{ "poolCount": 3, "packageIds": { "spv": "0x..." } }
```

#### `GET /registry/pools`
Returns all pool summaries. Each entry includes `securitizationPackageId` (varies per pool).

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

Write endpoints return `{ "digest": "..." }` with HTTP 202 (except `POST /pools` which returns
HTTP 201 with full result). The transaction is submitted immediately; use the digest to confirm
finality on-chain.

#### `POST /pools` — atomic pool creation

Deploys a fresh securitization package per pool (tx 1), then atomically creates, wires, and
activates all contracts in a single PTB (tx 2). If the PTB aborts, `SPVRegistry` is untouched.
Returns all relevant object IDs on success.

```json
{
  "spv":            "0xSPV_ADDRESS",
  "poolId":         "POOL-2025-001",
  "originator":     "0xORIGINATOR_ADDRESS",
  "totalPoolValue": "10000000000",
  "interestRate":   500,
  "maturityDate":   1893456000000,
  "assetHash":      "abcd1234...64hexchars",
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
}
```

Field notes:
- `interestRate`: blended pool rate in basis points (500 = 5%)
- `seniorRateBps`/`mezzRateBps`/`juniorRateBps`: per-tranche waterfall rates in bps
- `seniorSupplyCap`/`mezzSupplyCap`/`juniorSupplyCap`: maximum token supply per tranche (number of tokens)
- `seniorFaceValue`/`mezzFaceValue`/`juniorFaceValue`: principal outstanding per tranche in stablecoin base units; used directly as waterfall outstanding. Token price is derived as `faceValue / supplyCap`.
- `paymentFrequency`: `0` = Monthly, `1` = Quarterly
- `assetHash`: 64 hex characters (SHA-256 of off-chain legal documents)
- `coinType`: Move type string of the stablecoin used for issuance

Response (HTTP 201):
```json
{
  "poolStateId":             "0x...",
  "securitizationPackageId": "0x...",
  "issuanceStateId":         "0x...",
  "vaultId":                 "0x..."
}
```

#### Pool lifecycle

```
POST /pools/:id/activate    Created → Active
POST /pools/:id/default     Active → Defaulted
POST /pools/:id/close       Active|Defaulted → Matured
```

#### Issuance

```
POST /pools/:id/issuance/start    Open subscription window
POST /pools/:id/issuance/invest   Submit an investment (signer pays)
POST /pools/:id/issuance/end      Close subscription window
```

##### `POST /pools/:id/issuance/start` body
```json
{
  "saleStart": 1700000000000,
  "saleEnd":   1702000000000
}
```

`saleStart`/`saleEnd` are Unix timestamps in milliseconds. Prices are fixed at pool creation
time (via `POST /pools`) and stored on-chain in `IssuanceState` — they cannot be changed here.
The `IssuanceState` object is resolved automatically from the pool.

##### `POST /pools/:id/issuance/invest` body
```json
{
  "trancheType":          0,
  "amount":               "5000000000",
  "complianceRegistryId": "0xCOMPLIANCE_REGISTRY_ID"
}
```

- `trancheType`: `0` = Senior, `1` = Mezzanine, `2` = Junior
- `amount`: stablecoin amount in base units taken from the signer's wallet
- `complianceRegistryId`: object ID of the `ComplianceRegistry` used to verify the signer

The coin type is derived automatically from the on-chain `IssuanceState` type — no need to
specify it. The `TrancheRegistry` and `IssuanceState` objects are resolved from the pool.

#### Waterfall

```
POST /pools/:id/waterfall/deposit   Record a pool repayment
POST /pools/:id/waterfall/accrue    Accrue interest since last distribution
POST /pools/:id/waterfall/run       Execute waterfall distribution
POST /pools/:id/waterfall/turbo     Normal → Turbo mode
POST /pools/:id/waterfall/default   Any mode → Default mode
```

##### `POST /pools/:id/waterfall/deposit` body
```json
{ "amount": "5000000000" }
```

All waterfall objects are resolved automatically from the pool's `contractObjects`.

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

## Pool lifecycle

```
POST /pools
  │  tx 1: deploy securitization package
  │  tx 2: atomic PTB — create pool + issuance + vault, wire contracts, activate
  ▼
pool is Active — securitizationPackageId stored in SPVRegistry per pool

POST /pools/:id/issuance/start   → subscription window opens
POST /pools/:id/issuance/invest  → investor subscribes (signer's wallet pays)
POST /pools/:id/issuance/end     → subscription window closes

POST /compliance/:regId/investors  → whitelist investors (can be done anytime before issuance)

POST /pools/:id/waterfall/deposit  → record repayment
POST /pools/:id/waterfall/accrue   → accrue interest
POST /pools/:id/waterfall/run      → distribute (Senior → Mezz → Junior → Reserve)

POST /pools/:id/close              → pool Matured
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
