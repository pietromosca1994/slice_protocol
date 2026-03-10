# IOTA Securitization Protocol

On-chain securitisation framework written in **IOTA Move** (Sui Move variant, IOTA Rebased).  
Implements a complete tokenised securitisation lifecycle — from asset pool creation through tranche issuance, payment waterfall distribution, and investor compliance — entirely on the IOTA blockchain.

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                         IOTA Securitization Protocol                 │
│                                                                       │
│  ┌──────────────┐    creates    ┌──────────────────┐                 │
│  │ PoolContract │ ─────────────▶│ TrancheFactory   │                 │
│  │  (root auth) │               │ (SENIOR/MEZZ/    │                 │
│  └──────┬───────┘               │  JUNIOR Coin<T>) │                 │
│         │ activates             └────────┬─────────┘                 │
│         ▼                               │ mint()                     │
│  ┌──────────────┐  verify investor      ▼                            │
│  │ IssuanceContract│◀─────────  ┌──────────────────┐                 │
│  │ (subscription)  │            │ComplianceRegistry │                 │
│  └──────┬──────────┘            │ (KYC / DID / AML)│                 │
│         │ funds to              └──────────────────┘                 │
│         ▼                                                             │
│  ┌──────────────┐  releases     ┌──────────────────┐                 │
│  │ PaymentVault │ ─────────────▶│ WaterfallEngine  │                 │
│  │  (custody)   │               │ (Senior→Mezz→    │                 │
│  └──────────────┘               │  Junior→Reserve) │                 │
│                                  └──────────────────┘                 │
└─────────────────────────────────────────────────────────────────────┘
```

### Contracts

| Contract | Source File | Role |
|---|---|---|
| `PoolContract` | `pool_contract.move` | Root authority; pool lifecycle management |
| `TrancheFactory` | `tranche_factory.move` | Creates SENIOR/MEZZ/JUNIOR `Coin<T>` foundries |
| `IssuanceContract` | `issuance_contract.move` | Subscription window; investor token issuance |
| `WaterfallEngine` | `waterfall_engine.move` | Payment priority distribution |
| `ComplianceRegistry` | `compliance_registry.move` | KYC/AML; transfer restrictions; DID integration |
| `PaymentVault` | `payment_vault.move` | Stablecoin custody; deposit/release accounting |

### Libraries

| Module | File | Purpose |
|---|---|---|
| `math` | `math.move` | Simple interest, basis-point arithmetic, safe math |
| `errors` | `errors.move` | Centralised named error codes (all 6 contracts) |
| `events` | `events.move` | All protocol events in one module |

---

## Folder Structure

```
iota-securitization-move/
│
├── Move.toml                          # Workspace manifest (multi-package)
│
├── packages/
│   ├── securitization/                # Main protocol package
│   │   ├── Move.toml                  # Package manifest + dependency config
│   │   └── sources/
│   │       ├── contracts/             # Six core ISC contracts
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
│   │       └── libraries/             # Shared utilities
│   │           ├── errors.move        # All error codes
│   │           ├── events.move        # All emitted events
│   │           ├── math.move          # Fixed-point arithmetic
│   │           └── math_tests.move    # Math library unit tests
│   │
│   └── mocks/                         # Test mock package
│       ├── Move.toml
│       └── sources/
│           └── (mock stablecoin, oracle stubs)
│
├── scripts/
│   └── deploy.sh                      # Deployment script (testnet / mainnet)
│
├── deployments/                       # Auto-generated deployment manifests
│   └── testnet_<timestamp>.json
│
└── docs/
    └── (architecture diagrams, PTB examples)
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
# Run all tests in the securitization package
cd packages/securitization
iota move test

# Run with gas profiling
iota move test --gas-limit 10000000000

# Run a specific test module
iota move test --filter pool_contract_tests

# Run a single test
iota move test --filter test_activate_pool_success
```

Expected test output (all passing):

```
Running Move unit tests
[ PASS ] securitization::math_tests::test_simple_interest_one_year
[ PASS ] securitization::math_tests::test_saturating_sub_underflow_returns_zero
[ PASS ] securitization::pool_contract_tests::test_initialise_pool_success
[ PASS ] securitization::pool_contract_tests::test_activate_pool_success
[ PASS ] securitization::pool_contract_tests::test_auto_maturation_on_full_repayment
[ PASS ] securitization::tranche_factory_tests::test_mint_at_exact_cap
[ PASS ] securitization::waterfall_engine_tests::test_normal_waterfall_surplus_goes_to_reserve
[ PASS ] securitization::waterfall_engine_tests::test_default_mode_only_pays_senior
[ PASS ] securitization::compliance_registry_tests::test_transfer_blocked_by_holding_period
[ PASS ] securitization::payment_vault_tests::test_multiple_deposit_release_cycles
...
Test result: OK. 45 tests passed; 0 failed.
```

---

## Deployment

```bash
# Deploy to testnet (default)
./scripts/deploy.sh testnet

# Deploy to mainnet
./scripts/deploy.sh mainnet
```

The script publishes the package and saves a JSON manifest to `deployments/`.

### Post-deployment PTB setup

After publishing, run the following Programmable Transaction Block calls in order:

```bash
# 1. Link downstream contracts
iota client ptb \
  --move-call <PACKAGE>::pool_contract::set_contracts \
    @<ADMIN_CAP_ID> @<POOL_STATE_ID> \
    @<TRANCHE_REGISTRY_ID> @<ISSUANCE_STATE_ID> @<WATERFALL_STATE_ID> @<ORACLE_ADDRESS>

# 2. Initialise the pool
iota client ptb \
  --move-call <PACKAGE>::pool_contract::initialise_pool \
    @<ADMIN_CAP_ID> @<POOL_STATE_ID> \
    '"POOL-001"' @<ORIGINATOR> @<SPV> \
    1000000000u64 500u32 <MATURITY_MS>u64 \
    '<ASSET_HASH_HEX>' @<CLOCK_ID>

# 3. Create tranches
iota client ptb \
  --move-call <PACKAGE>::tranche_factory::create_tranches \
    @<TRANCHE_ADMIN_CAP_ID> @<TRANCHE_REGISTRY_ID> \
    5000000u64 3000000u64 2000000u64 \
    @<ISSUANCE_CONTRACT_ADDRESS> @<CLOCK_ID>

# 4. Create vault (stablecoin type must match issuance coin type)
iota client ptb \
  --move-call <PACKAGE>::payment_vault::create_vault<0x<STABLECOIN_PACKAGE>::usdc::USDC> \
    @<VAULT_ADMIN_CAP_ID>

# 5. Authorise depositor
iota client ptb \
  --move-call <PACKAGE>::payment_vault::authorise_depositor<...USDC> \
    @<VAULT_ADMIN_CAP_ID> @<VAULT_BALANCE_ID> @<ISSUANCE_STATE_ID> @<CLOCK_ID>

# 6. Activate pool
iota client ptb \
  --move-call <PACKAGE>::pool_contract::activate_pool \
    @<ADMIN_CAP_ID> @<POOL_STATE_ID> @<CLOCK_ID>
```

---

## Key Design Decisions

### Capability-based access control
Every privileged operation requires a capability object (`AdminCap`, `OracleCap`, `IssuanceAdminCap`, etc.) to be passed as a reference. This is idiomatic IOTA Move and avoids `tx.origin` / `msg.sender` patterns common in EVM.

### Shared objects
`PoolState`, `TrancheRegistry`, `WaterfallState`, `ComplianceRegistry`, and `VaultBalance` are all shared objects — readable by any participant without ownership. Mutations require the appropriate capability.

### Generic stablecoin `<C>`
`IssuanceState<C>` and `VaultBalance<C>` are generic over the stablecoin coin type. This avoids hard-coding a specific stablecoin and allows the same protocol to be deployed with any `Coin<T>` on IOTA.

### Treasury caps in TrancheRegistry
All three `TreasuryCap<T>` objects (Senior, Mezz, Junior) live inside `TrancheRegistry`. This ensures the supply accounting and the minting authority are co-located and that caps can never be split from the registry.

### Waterfall modes
The `WaterfallEngine` supports three modes encoded as `u8` constants rather than enums (Move enums have limited pattern-matching compared to Rust). Transitions are guarded: Turbo requires Normal; Default can be set from any mode by admin or pool cap.

### Error code namespacing
All error codes are namespaced by contract (1xxx PoolContract, 2xxx TrancheFactory, etc.) making abort codes immediately diagnosable in on-chain explorer traces.

---

## IOTA Identity (DID) Integration

`ComplianceRegistry` stores the IOTA Identity DID document `object::ID` per investor. The on-chain contract verifies the DID object ID exists at the time of `add_investor`; full credential verification (expiry checks, credential schemas) is performed off-chain by the compliance admin before calling `add_investor`.

For production deployments, integrate with the [IOTA Identity SDK](https://wiki.iota.org/identity.rs/introduction) to:
1. Resolve investor DID documents
2. Verify Verifiable Credentials (accreditation, jurisdiction)
3. Submit proof references alongside the `add_investor` transaction

---

## License

MIT
