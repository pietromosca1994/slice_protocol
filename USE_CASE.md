# The Slice Protocol as a Securitisation Engine

---

## What Securitisation Is

Securitisation is the process of taking a pool of illiquid financial assets — loans, mortgages, receivables, lease payments — and converting them into tradeable securities. The originator (a bank, lender, or fintech) sells the assets to a Special Purpose Vehicle (SPV), which then issues notes to investors. Those notes are tranched by seniority: Senior investors get paid first and take the least risk; Junior investors get paid last and absorb losses first in exchange for higher yield.

The Slice Protocol replicates this entire structure on the IOTA blockchain, replacing legal paper with smart contracts and certificates with fungible tokens.

---

## The Real-World Parallel

| Traditional Securitisation | Slice Protocol |
|---|---|
| Asset register / prospectus | `asset_hash` in `PoolContract` (SHA-256 of off-chain docs) |
| Special Purpose Vehicle (SPV) | `PoolContract` shared object |
| Rating agency approval | `ComplianceRegistry` accreditation levels |
| KYC / AML checks | `ComplianceRegistry` investor whitelist + DID |
| Subscription agreement | `IssuanceContract` subscription window |
| Senior note certificate | `SENIOR_COIN` fungible token |
| Mezzanine note certificate | `MEZZ_COIN` fungible token |
| Junior / equity note | `JUNIOR_COIN` fungible token |
| Paying agent / escrow | `PaymentVault` |
| Payment waterfall clause | `WaterfallEngine` |
| Servicer / oracle | `OracleCap` holder |
| Transfer restrictions | `ComplianceRegistry` holding periods + jurisdiction checks |

---

## Lifecycle

### 1. Pool Formation

A lender has €10M of car loans on its balance sheet. It wants to free up capital without selling the loans outright. It creates a pool by calling `initialise_pool`:

```
total_pool_value  = 10,000,000,000   (base units)
interest_rate     = 500 bps          (5% blended rate)
maturity_date     = 3 years from now
asset_hash        = SHA-256 of the loan register stored off-chain
```

The hash is the on-chain fingerprint of the legal documentation. Any tampering with the off-chain documents produces a different hash, making the binding between the blockchain record and the legal reality auditable and tamper-evident.

The `originator` and `spv` addresses represent the lender and the bankruptcy-remote SPV respectively. Once `activate_pool` is called, the pool is live and its parameters are immutable.

---

### 2. Tranche Structuring

The SPV structures the €10M into three risk classes:

```
Senior  (€5M,  3% interest)   lowest risk  — paid first   — AAA equivalent
Mezz    (€3M,  6% interest)   medium risk  — paid second  — BBB equivalent
Junior  (€2M, 12% interest)   highest risk — paid last    — first-loss piece
```

`create_tranches` sets these supply caps. Three fungible tokens are minted as needed during the subscription phase — no tokens exist yet at this point, only the authority to mint up to the cap.

The `IssuanceAdminCap` is transferred to the `IssuanceContract` address at this step. This is the protocol equivalent of the SPV receiving legal authority to issue notes — a Move capability object rather than a mandate in a trust deed.

---

### 3. Investor KYC and Onboarding

Before any investor can subscribe, they must be whitelisted in `ComplianceRegistry`. This mirrors the subscription document and KYC checks that a placement agent would perform in a traditional deal:

| Registry Field | Traditional Equivalent |
|---|---|
| `accreditation_level` | MiFID II / SEC Reg D investor classification |
| `jurisdiction` | Geographic placement restrictions |
| `holding_period` | Lock-up clause in the subscription agreement |
| `did_object_id` | Anchor to a verified IOTA Identity credential |
| `is_active` | Ability to suspend an investor without removing their record |

`check_transfer_allowed` is the on-chain equivalent of the transfer agent verifying that a proposed note transfer complies with the placement memorandum. Non-compliant transfers abort at the contract level — no legal action required.

---

### 4. Primary Issuance — Subscription Window

`start_issuance` opens the book-building phase. The window has a hard start and end timestamp; no investments are accepted outside it.

When an investor calls `invest`:

1. `ComplianceRegistry` is checked — is the investor whitelisted, active, and past their holding period?
2. The stablecoin payment is held in `IssuanceState.vault_balance` — equivalent to funds held in escrow by the placement agent
3. `tokens_for_amount(payment, price_per_unit)` calculates the allocation — equivalent to the note allocation confirmed at closing
4. `SENIOR_COIN`, `MEZZ_COIN`, or `JUNIOR_COIN` tokens are minted directly to the investor's wallet — equivalent to DTC / Euroclear settlement of the notes

When `end_issuance` is called, `release_funds_to_vault` moves all raised stablecoin into `PaymentVault` — equivalent to the SPV receiving subscription proceeds at closing and using them to purchase the loan pool from the originator.

---

### 5. Ongoing Servicing — The Waterfall

Every month the borrowers make repayments. The servicer reports to the protocol via two actions:

- **`update_performance_data`** (via `OracleCap`) — updates outstanding principal on `PoolContract`, giving investors an auditable view of pool health
- **`deposit_payment`** on `WaterfallEngine` — records the cash available for distribution

`run_waterfall` then distributes it in strict priority order. For example, with €80,000 available:

```
Step 1 → Senior accrued interest    €12,500   paid in full   → remaining: €67,500
Step 2 → Senior principal           €40,000   partial        → remaining: €27,500
Step 3 → Mezz accrued interest      €15,000   paid in full   → remaining: €12,500
Step 4 → Mezz principal             €0        nothing left
Step 5 → Junior                     €0        nothing reaches Junior this period
Step 6 → Reserve                    €12,500   excess to buffer
```

This is the legal waterfall clause from the deal prospectus, executed deterministically on-chain with no paying agent discretion.

---

### 6. Stress Scenarios

#### Turbo Mode

Mirrors an **accelerated amortisation trigger** — a provision in many CLO and ABS deals that redirects cash to pay down Senior principal faster when the deal is outperforming. Instead of excess cash flowing to Junior, it all goes to Senior paydown, shortening duration and reducing credit risk for the most senior investors.

#### Default Mode

Mirrors the **enforcement waterfall** that activates when a deal breaches its performance triggers (delinquency rates, overcollateralisation tests, coverage ratios). Junior and Mezz distributions are suspended entirely. All recoveries flow exclusively to Senior — exactly as a trustee would enforce the priority of payments clause in a defaulted deal.

The `PoolCap` held by the pool contract allows the oracle to trigger default mode autonomously via `mark_default_oracle`, without waiting for an admin action — equivalent to the trustee acting on the servicer's breach notice under a pre-agreed enforcement mechanism.

---

### 7. Maturity and Redemption

When the oracle reports `outstanding_principal = 0` and the maturity date has passed, `PoolContract` automatically transitions to `STATUS_MATURED`. Investors burn their tokens via `melt_senior`, `melt_mezz`, or `melt_junior` — equivalent to surrendering note certificates to the paying agent upon final redemption.

`disable_minting` permanently closes the tranche, ensuring no new tokens can be issued against a retired pool — equivalent to the trustee cancelling the note programme after final redemption and releasing the SPV.

---

## What the Protocol Adds Over Traditional Securitisation

| Pain Point in Traditional Deals | How Slice Addresses It |
|---|---|
| Settlement takes T+2 days via DTC / Euroclear | Token transfers settle in seconds on IOTA |
| Waterfall calculations are manual and error-prone | Deterministic on-chain execution, auditable by anyone |
| KYC is siloed per institution | Shared `ComplianceRegistry` with DID anchoring |
| Investor reporting depends on the servicer | `PoolContract` and `WaterfallState` are publicly readable |
| Transfer restrictions enforced by legal agreements only | Enforced at the contract level — non-compliant transfers abort |
| Paying agent is a trusted third party with discretion | `PaymentVault` is a smart contract with no discretion |
| Secondary market is illiquid and OTC | Tranche tokens are standard fungible coins, tradeable on any DEX |

> The protocol does not eliminate the need for legal documentation — `asset_hash` deliberately anchors the on-chain structure to off-chain legal reality. What it eliminates is the need for intermediaries to **enforce** what the documentation says.