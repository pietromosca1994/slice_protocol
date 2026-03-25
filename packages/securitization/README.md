# IOTA Securitization Protocol

On-chain securitisation framework written in **IOTA Move** (Sui Move variant, IOTA Rebased).  
Implements a complete tokenised securitisation lifecycle — from asset pool creation through tranche issuance, payment waterfall distribution, and investor compliance — entirely on the IOTA blockchain.

---

## What This Protocol Does

Traditional securitisation bundles financial assets (loans, mortgages, receivables) into a pool and issues notes of different seniority — Senior, Mezzanine, Junior — to investors. Repayments flow through a payment waterfall: Senior investors are paid first, Junior last, absorbing losses first in return for higher yield.

This protocol replicates that structure on-chain:

- A **pool** of assets is registered and linked to off-chain legal documentation via a SHA-256 hash
- Three **tranche tokens** (SENIOR, MEZZ, JUNIOR) are minted as standard IOTA `Coin<T>` fungible tokens
- A **subscription window** accepts stablecoin payments from KYC-verified investors and mints tranche tokens in return
- Periodic repayments from the borrower flow through the **waterfall engine**, which distributes them to tranche holders in strict priority order
- A **compliance registry** enforces KYC/AML, accreditation levels, holding-period lock-ups, and IOTA Identity DID integration
- A **payment vault** provides auditable stablecoin custody with an authorised-depositor whitelist

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                       IOTA Securitization Protocol                   │
│                                                                       │
│  ┌──────────────┐    links to   ┌──────────────────┐                 │
│  │ PoolContract │ ─────────────▶│  TrancheFactory  │                 │
│  │  (root auth) │               │  SENIOR_COIN     │                 │
│  └──────┬───────┘               │  MEZZ_COIN       │                 │
│         │ activates             │  JUNIOR_COIN     │                 │
│         ▼                       └────────┬─────────┘                 │
│  ┌──────────────────┐  mint()            │                           │
│  │ IssuanceContract │◀───────────────────┘                           │
│  │  (subscription)  │  verify via                                    │
│  └──────┬───────────┘◀──────────────────┐                            │
│         │ funds to                       │  ComplianceRegistry       │
│         ▼                               │  (KYC / DID / AML)        │
│  ┌──────────────┐  releases to          └──────────────────┘         │
│  │ PaymentVault │ ─────────────▶ ┌──────────────────┐                │
│  │  (custody)   │                │  WaterfallEngine │                │
│  └──────────────┘                │  Senior→Mezz→    │                │
│                                  │  Junior→Reserve  │                │
│                                  └──────────────────┘                │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Contract Reference

### PoolContract — `pool_contract.move`

The root authority object of the protocol. Every other contract references it.

**What it does:**
- Registers the asset pool on-chain with its economic parameters (total value, interest rate, maturity date)
- Binds the on-chain structure to off-chain legal documents via a SHA-256 `asset_hash`
- Manages the pool lifecycle through four states: `Created → Active → Matured | Defaulted`
- Mints and distributes an `OracleCap` to the trusted oracle address at initialisation time
- Links the addresses of all downstream contracts (`TrancheFactory`, `IssuanceContract`, `WaterfallEngine`)

**Key constraints:**
- `set_contracts` must be called **before** `initialise_pool` because `initialise_pool` reads `oracle_address` to send the `OracleCap` — if `oracle_address` is still `@0x0`, the cap is sent to the zero address and permanently lost
- `activate_pool` requires all three downstream contract addresses to be non-zero
- Once a pool is Defaulted or Matured it cannot be reactivated

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `AdminCap` | Deployer | `set_contracts`, `initialise_pool`, `activate_pool`, `mark_default_admin`, `close_pool` |
| `OracleCap` | Oracle address | `update_performance_data`, `mark_default_oracle` |

**Pool status codes:**

| Code | Status | Meaning |
|------|--------|---------|
| 0 | Created | Deployed but not yet initialised |
| 1 | Active | Accepting repayments, waterfall running |
| 2 | Defaulted | Default triggered; recovery mode |
| 3 | Matured | Fully repaid or manually closed |

---

### TrancheFactory — `tranche_factory.move`

Creates and controls the three fungible tranche tokens. Acts as the minting authority during issuance.

**What it does:**
- Holds `TreasuryCap<T>` for all three coin types inside a single shared `TrancheRegistry` object
- Sets supply caps per tranche and enables minting once `create_tranches` is called
- Mints tranche tokens to investors on behalf of `IssuanceContract` via `IssuanceAdminCap`
- Exposes `melt_*` functions so investors can burn tokens upon redemption
- Issues an `IssuanceAdminCap` to the `IssuanceContract` address during `create_tranches` — this is the only object that can trigger minting

**Two-step bootstrap process:**
The registry is created empty at publish time. Before any minting can happen:
1. `bootstrap` must be called first — it extracts the `TreasuryCap` objects from the three coin parking wrappers (`SeniorTreasury`, `MezzTreasury`, `JuniorTreasury`) and injects them into the registry
2. `create_tranches` must then be called to set supply caps and issue the `IssuanceAdminCap`

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `TrancheAdminCap` | Deployer | `bootstrap`, `create_tranches`, `disable_minting` |
| `IssuanceAdminCap` | IssuanceContract address | `mint` |

---

### SeniorCoin, MezzCoin, JuniorCoin — `senior_coin.move`, `mezz_coin.move`, `junior_coin.move`

Each defines a standard IOTA fungible token using the one-time witness (OTW) pattern.

**What they do:**
- Create the on-chain currency (`SENIOR_COIN`, `MEZZ_COIN`, `JUNIOR_COIN`) with 6 decimal places
- Freeze the coin metadata at publish time (immutable symbol, name, description)
- Park the `TreasuryCap<T>` in a shared wrapper object (`SeniorTreasury`, `MezzTreasury`, `JuniorTreasury`) for `TrancheFactory` to claim via `bootstrap`

**Treasury cap handoff pattern:**
Rather than transferring the `TreasuryCap` to the deployer wallet (which would require a separate wiring step), each coin's `init` function parks the cap in a shared object. `tranche_factory::bootstrap` then extracts it atomically. The `Option` wrapper ensures the cap can only be extracted once — a second `bootstrap` call aborts.

`take_treasury` is scoped `public(package)` so only modules within the same package can call it — external contracts cannot steal the treasury cap.

---

### IssuanceContract — `issuance_contract.move`

Manages the primary subscription window through which investors acquire tranche tokens.

**What it does:**
- Opens a timed subscription window (`sale_start` / `sale_end` timestamps in ms) during which investors can purchase tranche tokens with stablecoin
- Verifies every investor against `ComplianceRegistry` before accepting payment
- Calculates token quantities using `math::tokens_for_amount(payment, price_per_unit)`
- Custodies raised stablecoin in an internal `Balance<C>` until the issuance ends
- Mints tranche tokens directly to the investor by calling `tranche_factory::mint` via `IssuanceAdminCap`
- Tracks per-investor `Subscription` records (amount paid, tokens issued, refund status)
- Releases all raised funds to `PaymentVault` after a successful close
- Issues refunds if the issuance is cancelled (`succeeded == false`)

**Generic stablecoin:** `IssuanceState<C>` is generic over coin type `C`, so the same contract works with any stablecoin on IOTA.

**Important:** `IssuanceAdminCap` is sent to the `IssuanceContract` address during `create_tranches`. The API holds this cap as an env variable (`ISSUANCE_ADMIN_CAP_ID`) and passes it on every `invest` call.

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `IssuanceOwnerCap` | Deployer | `create_issuance_state`, `start_issuance`, `end_issuance`, `release_funds_to_vault` |

---

### ComplianceRegistry — `compliance_registry.move`

Enforces KYC/AML rules and integrates with IOTA Identity (DID).

**What it does:**
- Maintains a `Table<address, InvestorRecord>` whitelist of verified investors
- Stores per-investor: accreditation level, jurisdiction (ISO-3166-1), holding period end timestamp, IOTA Identity DID document object ID, and active flag
- Gates every token transfer via `check_transfer_allowed` — checks both sender and recipient are whitelisted, active, and past their holding period
- Provides a global `transfer_restrictions_on` flag that bypasses all checks when set to `false` (emergency use only)
- Applies a `default_holding_period_ms` to new investors unless a custom value is provided

**Accreditation levels:**

| Level | Type |
|-------|------|
| 1 | Retail |
| 2 | Professional |
| 3 | Institutional |
| 4 | Qualified Purchaser |

**Holding period:** Stored as an absolute UNIX timestamp in ms (`clock::timestamp_ms + holding_ms`). Transfers are blocked until `now > holding_period_end`. Set `customHoldingMs: 0` to use the registry default.

**DID integration:** `did_object_id` stores the IOTA Identity DID document object ID. Full credential verification (expiry, schema, issuer trust) is performed off-chain by the compliance admin before calling `add_investor`.

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `ComplianceAdminCap` | Deployer | All investor management and restriction configuration |

---

### PaymentVault — `payment_vault.move`

Secure stablecoin custody for all capital flows in the protocol.

**What it does:**
- Holds a `Balance<C>` of stablecoin with full deposit/withdrawal accounting (`total_deposited`, `total_distributed`)
- Enforces an authorised-depositor whitelist — only addresses granted deposit rights by the admin can call `deposit`
- Releases funds to any recipient address (typically the WaterfallEngine operator or tranche holders) via `release_funds`
- Generic over coin type `C` — one vault per stablecoin denomination

**Typical flow:**
1. `IssuanceContract` is authorised as a depositor via `authorise_depositor`
2. After issuance ends, `release_funds_to_vault` transfers all raised funds from `IssuanceState.vault_balance` to the `VaultBalance` object
3. The servicer/borrower also deposits periodic repayments directly to the vault
4. The admin calls `release_funds` to push amounts to tranche holders as the waterfall executes

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `VaultAdminCap` | Deployer | `create_vault`, `authorise_depositor`, `revoke_depositor`, `release_funds` |

---

### WaterfallEngine — `waterfall_engine.move`

Implements the payment priority waterfall that distributes repayments to tranche holders.

**What it does:**
- Tracks outstanding principal and accrued interest per tranche
- Accrues simple interest over elapsed time: `principal × rate_bps × elapsed_seconds / (10_000 × 31_536_000)`
- Accepts incoming repayments via `deposit_payment` (tracked numerically as `pending_funds`)
- Executes the full distribution cascade via `run_waterfall`:
  - **Normal mode:** Senior (interest → principal) → Mezz (interest → principal) → Junior (interest → principal) → Reserve
  - **Turbo mode:** Senior gets all excess cash after its own obligations, accelerating principal paydown; remainder cascades normally
  - **Default mode:** All funds routed exclusively to Senior recovery; Mezz and Junior suspended
- Issues a `PoolCap` to the pool contract address at initialisation, allowing the pool to trigger default mode autonomously

**Mode transitions:**

| From | To | Triggered by |
|------|----|--------------|
| Normal | Turbo | `WaterfallAdminCap` |
| Normal / Turbo | Default | `WaterfallAdminCap` or `PoolCap` |

Note: `deposit_payment` automatically accrues interest before recording the new payment, keeping accrual timestamps consistent.

**Capabilities:**

| Cap | Holder | Allows |
|-----|--------|--------|
| `WaterfallAdminCap` | Deployer | `initialise_waterfall`, `trigger_turbo_mode`, `trigger_default_mode_admin` |
| `PoolCap` | Pool contract address | `trigger_default_mode_pool` |

---

## Error Code Namespacing

All abort codes are namespaced by contract to make on-chain traces immediately diagnosable:

| Range | Contract |
|-------|----------|
| 1xxx | PoolContract |
| 2xxx | TrancheFactory |
| 3xxx | IssuanceContract |
| 4xxx | WaterfallEngine |
| 5xxx | ComplianceRegistry (spv package) |
| 6xxx | PaymentVault (spv package) |
| 7xxx | SPVRegistry (spv package) |

---

## Folder Structure

```
iota-securitization-move/
│
├── Move.toml
│
├── packages/
│   ├── securitization/
│   │   ├── Move.toml
│   │   └── sources/
│   │       ├── contracts/
│   │       │   ├── pool_contract.move
│   │       │   ├── pool_contract_tests.move
│   │       │   ├── tranche_factory.move
│   │       │   ├── tranche_factory_tests.move
│   │       │   ├── issuance_contract.move
│   │       │   ├── waterfall_engine.move
│   │       │   ├── waterfall_engine_tests.move
│   │       │   ├── compliance_registry.move
│   │       │   ├── compliance_registry_tests.move
│   │       │   ├── payment_vault.move
│   │       │   └── payment_vault_tests.move
│   │       └── libraries/
│   │           ├── errors.move
│   │           ├── events.move
│   │           ├── math.move
│   │           └── math_tests.move
│   │
│   └── mocks/
│       ├── Move.toml
│       └── sources/
│           └── (mock stablecoin, oracle stubs)
│
├── scripts/
│   └── deploy_securitization.sh
│
├── deployments/
│   └── testnet_<timestamp>.json
│
└── docs/
```

---

## Prerequisites

- [IOTA CLI](https://docs.iota.org/developer/getting-started/install-iota) ≥ 0.7
- Move edition `2024.beta`
- Active IOTA wallet with test IOTA for gas

---

## Building

```bash
cd packages/securitization
iota move build
```

---

## Running Tests

```bash
# Run all tests
iota move test

# Run with gas profiling
iota move test --gas-limit 10000000000

# Run a specific module
iota move test --filter pool_contract_tests

# Run a single test
iota move test --filter test_activate_pool_success
```

---

## Deployment

Pool creation is fully handled by the API (`POST /pools`). It runs two transactions:

1. **Deploy** — publishes this package; bootstraps `TrancheRegistry` with `TreasuryCap` objects.
2. **Atomic PTB** — in a single programmable transaction:
   - Creates `PoolState`, `IssuanceState<C>`, and `VaultBalance<C>` by value (not yet shared)
   - Calls `set_contracts`, `create_tranches`, `set_contract_objects`, `initialise_pool`, `initialise_waterfall`
   - Calls `activate_and_register_pool` — activates the pool, registers in `SPVRegistry`, and shares all objects atomically

If any step in the PTB fails, the entire transaction rolls back and `SPVRegistry` is never updated.

See the [root README](../../README.md) for the full setup and use-case walkthrough.


---

## Key Design Decisions

### Capability-based access control
Every privileged operation requires a capability object passed by reference. There are no `tx.origin` or `msg.sender` checks — authority is proven by object ownership, which is idiomatic IOTA Move.

### Shared objects
`PoolState`, `TrancheRegistry`, `WaterfallState`, `ComplianceRegistry`, and `VaultBalance` are all shared objects — readable by any participant without ownership. Mutations require the appropriate capability.

### Generic stablecoin `<C>`
`IssuanceState<C>` and `VaultBalance<C>` are generic over coin type so the same protocol works with any `Coin<T>` on IOTA without redeployment.

### Treasury cap parking pattern
Each coin module parks its `TreasuryCap` in a shared wrapper at publish time instead of sending it to the deployer wallet. `TrancheFactory::bootstrap` extracts all three atomically. The `Option` wrapper makes extraction a one-time operation — calling `bootstrap` twice aborts.

### Waterfall modes as u8 constants
Move has limited enum pattern-matching compared to Rust; mode transitions are encoded as `u8` constants with explicit guard assertions at each transition point.

### Error code namespacing
All error codes are namespaced by contract (1xxx–6xxx) making abort codes immediately diagnosable in on-chain explorer traces without needing the source.

---

## IOTA Identity (DID) Integration

`ComplianceRegistry` stores the IOTA Identity DID document `object::ID` per investor. The on-chain contract verifies the object ID is provided at `add_investor` time; full credential verification (expiry, schemas, issuer trust) is performed off-chain by the compliance admin before submitting the transaction.

For production deployments, integrate with the [IOTA Identity SDK](https://wiki.iota.org/identity.rs/introduction) to:
1. Resolve investor DID documents
2. Verify Verifiable Credentials (accreditation level, jurisdiction proof)
3. Submit the DID object ID alongside the `add_investor` transaction

---

## License

MIT