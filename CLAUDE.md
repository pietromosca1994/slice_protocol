# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Slice Protocol is an on-chain securitization engine built on the IOTA blockchain using Move. It tokenizes pools of illiquid financial assets (loans, mortgages, receivables) into tradeable securities with three risk tiers: Senior, Mezzanine, and Junior.

## Tech Stack

- **Smart contracts**: IOTA Move (Sui variant, `2024.beta` edition), built with `iota move` CLI
- **API**: TypeScript/Express.js, Node.js 20, using `@iota/iota-sdk`
- **Infrastructure**: Docker + Docker Compose

## Build & Test Commands

### Move Contracts

```bash
# Build
cd packages/securitization && iota move build
cd packages/spv && iota move build

# Test
iota move test
iota move test --filter pool_contract_tests   # filter by module
iota move test --filter test_activate_pool_success  # single test
```
## Architecture

### Package Structure

```
packages/
  securitization/   # Core protocol contracts (10 modules, ~2,052 LOC excl. tests)
    sources/
      contracts/
        pool_contract.move
        tranche_factory.move
        issuance_contract.move
        waterfall_engine.move
        senior_coin.move
        mezz_coin.move
        junior_coin.move
      libraries/
        errors.move
        events.move
        math.move
    tests/
      pool_contract_tests.move
      tranche_factory_tests.move
      issuance_contract_tests.move
      waterfall_engine_tests.move
  spv/              # Infrastructure contracts (5 modules, ~863 LOC)
    sources/
      contracts/
        spv_registry.move
        compliance_registry.move
        payment_vault.move
      libraries/
        errors.move
        events.move
    tests/
      spv_registry_tests.move
      compliance_registry_tests.move
      payment_vault_tests.move
api/                # TypeScript/Express REST API
  src/
    routes/         # One router per contract domain
    services/
      contracts/    # PTB builders (pool.service.ts, deploy.service.ts, registry.service.ts)
deployments/        # On-chain deployment artifacts
```

### Contract Modules

#### `packages/securitization` (depends on `spv`)

| Module | Shared Object | Capability | Role |
|--------|--------------|------------|------|
| `pool_contract.move` | `PoolState` | `AdminCap`, `OracleCap` | Root authority; manages pool lifecycle (Created → Active → Matured \| Defaulted); registers pool in SPVRegistry on creation; stores object IDs of all downstream contracts |
| `tranche_factory.move` | `TrancheRegistry` | `TrancheAdminCap`, `IssuanceAdminCap` | Creates supply-capped SENIOR/MEZZ/JUNIOR fungible tokens; minting gated by `IssuanceAdminCap`; bound to a pool via `pool_obj_id` |
| `issuance_contract.move` | `IssuanceState<C>` | `IssuanceOwnerCap` | Timed subscription window; accepts stablecoin, mints tranche tokens; generic over coin type `<C>`; bound to a pool via `pool_obj_id` |
| `waterfall_engine.move` | `WaterfallState` | `WaterfallAdminCap`, `PoolCap` | Automated repayment distribution (Senior → Mezz → Junior → Reserve); supports Normal / Turbo / Default modes; bound to a pool via `pool_obj_id` |
| `senior_coin.move` | — | — | OTW coin type `SENIOR_COIN`; `TreasuryCap` parked in `TrancheRegistry` at publish |
| `mezz_coin.move` | — | — | OTW coin type `MEZZ_COIN`; `TreasuryCap` parked in `TrancheRegistry` at publish |
| `junior_coin.move` | — | — | OTW coin type `JUNIOR_COIN`; `TreasuryCap` parked in `TrancheRegistry` at publish |

#### `packages/spv` (no protocol dependencies)

| Module | Shared Object | Capability | Role |
|--------|--------------|------------|------|
| `spv_registry.move` | `SPVRegistry` | `SPVRegistryAdminCap` | Singleton registry of all pools; maps pool IDs → `PoolEntry` metadata and SPV address → pool list; starting point for all API enumeration |
| `compliance_registry.move` | `ComplianceRegistry` | `ComplianceAdminCap` | KYC/AML whitelist with accreditation levels (1–4), jurisdiction, DID references, and per-investor holding period lock-ups |
| `payment_vault.move` | `VaultBalance<C>` | `VaultAdminCap` | Stablecoin custody generic over `<C>`; authorised-depositor model; `receive_balance` allows direct `Balance<C>` injection from Move (used by `issuance_contract::release_funds_to_vault`) |

## Workflow Orchestration
### 1. Plan Node Default
- Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
- If something goes sideways, STOP and re-plan immediately — don't keep pushing
- Use plan mode for verification steps, not just building
- Write detailed specs upfront to reduce ambiguity  

### 2. Subagent Strategy
- Use subagents liberally to keep main context window clean
- Offload research, exploration, and parallel analysis to subagents
- For complex problems, throw more compute at it via subagents
- One task per subagent for focused execution  

### 3. Self-Improvement Loop
- After ANY correction from the user: update tasks/lessons.md with the pattern
- Write rules for yourself that prevent the same mistake
- Ruthlessly iterate on these lessons until mistake rate drops
- Review lessons at session start for relevant project

### 4. Verification Before Done
- Never mark a task complete without proving it works
- Diff behavior between main and your changes when relevant
- Ask yourself: "Would a staff engineer approve this?"
- Run tests, check logs, demonstrate correctness

### 5. Demand Elegance (Balanced)
- For non-trivial changes: pause and ask "is there a more elegant way?"
- If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
- Skip this for simple, obvious fixes — don't over-engineer
- Challenge your own work before presenting it

### 6. Autonomous Bug Fixing
- When given a bug report: just fix it. Don't ask for hand-holding
- Point at logs, errors, failing tests — then resolve them
- Zero context switching required from the user
- Go fix failing CI tests without being told how

### Task Management
- Plan First: Write plan to tasks/todo.md with checkable items
- Verify Plan: Check in before starting implementation
- Track Progress: Mark items complete as you go
- Explain Changes: High-level summary at each step
- Document Results: Add review section to tasks/todo.md
- Capture Lessons: Update tasks/lessons.md after corrections

### Core Principles
- Simplicity First: Make every change as simple as possible. Impact minimal code.
- No Laziness: Find root causes. No temporary fixes. Senior developer standards.
- Minimal Impact: Changes should only touch what's necessary. Avoid introducing bugs.

