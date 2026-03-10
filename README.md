# Slice Protocol — Deployment Guide

---

## 0. Prerequisites — Get Your Private Key

Import your wallet mnemonic and export the private key for the API:

```bash
iota keytool import "<mnemonic words>" <key_scheme>
iota keytool list
iota keytool export <address>
```

Copy the `iotaprivkey1...` value into `SIGNER_PRIVATE_KEY` in your `.env` file.

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

> 🔍 **Local Explorer:** https://explorer.iota.org/?network=http%3A%2F%2F127.0.0.1%3A9000

---

## 2. Deploy the Protocol

```bash
chmod +x ./scripts/deploy.sh
./scripts/deploy.sh [testnet|mainnet|localnet]
```

The script publishes the package and writes a deployment manifest to `deployments/`.  
Copy all object IDs from the manifest into your `.env` file before proceeding.

---

## 3. Post-Deployment Setup

The phases below must be executed **in order**. Each phase depends on objects created by the previous one.

---

### Phase 1 — Infrastructure Setup *(one-time)*

Wire all contracts together and prepare the issuance infrastructure.

> ⚠️ `set-contracts` **must** come before `initialise` — the pool reads `oracle_address` during initialisation to mint the `OracleCap`. If the address is not set, the cap is sent to `@0x0` and permanently lost.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 1 | `POST` | `/api/v1/pool/set-contracts` | Link tranche factory, issuance contract, waterfall engine, oracle address |
| 2 | `POST` | `/api/v1/pool/initialise` | Set pool parameters; mints `OracleCap` → oracle address |
| 3 | `POST` | `/api/v1/pool/activate` | Transition pool `Created → Active` |
| 4 | `POST` | `/api/v1/tranches/bootstrap` | Extract `TreasuryCap`s from coin wrappers into the registry |
| 5 | `POST` | `/api/v1/tranches/create` | Set supply caps; issues `IssuanceAdminCap` → issuance contract |
| 6 | `POST` | `/api/v1/vault/create` | Create the `VaultBalance<C>` shared object |
| 7 | `POST` | `/api/v1/vault/authorise-depositor` | Grant deposit rights to the issuance contract address |
| 8 | `POST` | `/api/v1/issuance/create-state` | Create the `IssuanceState<C>` shared object |
| 9 | `POST` | `/api/v1/waterfall/initialise` | Set per-tranche outstanding amounts, interest rates, and payment frequency |

---

### Phase 2 — KYC / Investor Onboarding

Register and verify investors before the subscription window opens.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 10 | `POST` | `/api/v1/compliance/default-holding-period` | e.g. `7776000000` ms = 90 days |
| 11 | `POST` | `/api/v1/compliance/investors` | Add investor A — institutional (level 3), jurisdiction `US` |
| 12 | `POST` | `/api/v1/compliance/investors` | Add investor B — professional (level 2), jurisdiction `DE` |
| 13 | `GET`  | `/api/v1/compliance/investor/:address` | Verify both investors are active and whitelisted |

---

### Phase 3 — Primary Issuance

Open the subscription window and accept stablecoin investments.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 14 | `POST` | `/api/v1/issuance/start` | Set `saleStart`, `saleEnd`, and per-tranche prices |
| 15 | `POST` | `/api/v1/issuance/invest` | Investor A buys **Senior** — `trancheType: 0` |
| 16 | `POST` | `/api/v1/issuance/invest` | Investor A buys **Mezz** — `trancheType: 1` |
| 17 | `POST` | `/api/v1/issuance/invest` | Investor B buys **Junior** — `trancheType: 2` |
| 18 | `GET`  | `/api/v1/tranches/0` | Verify Senior minted amount increased |
| 19 | `GET`  | `/api/v1/tranches/1` | Verify Mezz minted amount increased |
| 20 | `GET`  | `/api/v1/tranches/2` | Verify Junior minted amount increased |
| 21 | `POST` | `/api/v1/issuance/end` | Close the subscription window |
| 22 | `POST` | `/api/v1/issuance/release-to-vault` | Transfer all raised funds to `PaymentVault` |
| 23 | `GET`  | `/api/v1/vault/:vaultId` | Verify vault balance equals total raised |

---

### Phase 4 — Ongoing Pool Servicing

Repeat each payment period (monthly or quarterly).

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 24 | `POST` | `/api/v1/pool/update-performance` | Oracle reports new outstanding principal |
| 25 | `POST` | `/api/v1/waterfall/accrue-interest` | Accrue simple interest since last distribution |
| 26 | `POST` | `/api/v1/waterfall/deposit-payment` | Record repayment amount into pending funds |
| 27 | `POST` | `/api/v1/waterfall/run` | Execute waterfall: Senior → Mezz → Junior → Reserve |
| 28 | `GET`  | `/api/v1/waterfall` | Verify outstanding principals reduced |

---

### Phase 5 — Stress Scenario: Turbo Mode

Activate when the borrower is ahead of schedule to accelerate Senior principal paydown.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 29 | `POST` | `/api/v1/waterfall/turbo-mode` | Redirect all excess cash to Senior principal paydown |
| 30 | `POST` | `/api/v1/pool/update-performance` | Oracle reports larger-than-expected repayment |
| 31 | `POST` | `/api/v1/waterfall/deposit-payment` | Record the repayment |
| 32 | `POST` | `/api/v1/waterfall/run` | Excess after Senior obligations goes entirely to Senior principal |
| 33 | `GET`  | `/api/v1/waterfall` | Confirm `seniorOutstanding` drops faster than normal mode |

---

### Phase 6 — Stress Scenario: Default

Suspend Mezz and Junior distributions; route all recoveries to Senior.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 34 | `POST` | `/api/v1/pool/mark-default/oracle` | Oracle triggers default on the pool |
| 35 | `POST` | `/api/v1/waterfall/default-mode/admin` | Waterfall switches to recovery-only mode |
| 36 | `POST` | `/api/v1/waterfall/deposit-payment` | Deposit partial recovery proceeds |
| 37 | `POST` | `/api/v1/waterfall/run` | Only Senior receives distributions |
| 38 | `GET`  | `/api/v1/waterfall` | Confirm `mezzOutstanding` and `juniorOutstanding` are unchanged |

---

### Phase 7 — Maturity & Redemption

Close out the pool and allow investors to burn their tranche tokens.

| # | Method | Endpoint | Notes |
|---|--------|----------|-------|
| 39 | `POST` | `/api/v1/pool/update-performance` | Oracle reports `outstandingPrincipal: 0` |
| 40 | `GET`  | `/api/v1/pool` | `poolStatus` auto-flips to `3` (Matured) |
| 41 | `POST` | `/api/v1/tranches/melt/senior` | Investor A burns Senior tokens on redemption |
| 42 | `POST` | `/api/v1/tranches/melt/mezz` | Investor A burns Mezz tokens |
| 43 | `POST` | `/api/v1/tranches/melt/junior` | Investor B burns Junior tokens |
| 44 | `POST` | `/api/v1/tranches/disable-minting` | Permanently disable all tranche minting |
| 45 | `GET`  | `/api/v1/tranches` | Verify all minted amounts are `0` and minting is disabled |

---

## Quick Reference — Lifecycle Summary

```
[Deploy] ──► [Setup] ──► [KYC] ──► [Issuance] ──► [Servicing] ──► [Maturity]
                                                         │
                                              ┌──────────┴──────────┐
                                           Turbo Mode          Default Mode
                                        (accelerate)           (recovery)
```

| Phase | Pool Status | Waterfall Mode |
|-------|-------------|----------------|
| 1 — Setup | `Created → Active` | — |
| 2 — KYC | `Active` | — |
| 3 — Issuance | `Active` | — |
| 4 — Servicing | `Active` | Normal |
| 5 — Turbo | `Active` | Turbo |
| 6 — Default | `Defaulted` | Default |
| 7 — Maturity | `Matured` | — |

# Last deployment 
## Testnet
```bash 
======================================
DEPLOYMENT SUCCESSFUL
======================================
Network:               testnet
Transaction Digest:    6eAhSCNhFduBETwBF12rPA26qsNPHCNtrEgMQVgjDuaM
Package ID:            0x94830d7f4f8f3a1cd7e41456c8d189b9ebcfcb30ce131a21a78af15322ffa468
Output File:           deployments/publish_testnet_20260310_111343.json

Created Objects:
--------------------------------------
0x08d3c6464c39a53720f3cfd02b7c7fcc8301d8e1eecf1d0fd78824ce8774fcb8  (MEZZ_COIN>)
0x1d704430cbb468fa2a4337e77993f09a23974b19b601961ec5f1e4b38adc44ee  (WaterfallAdminCap)
0x38dd24458fbc7961a6e97b2ad1dd1288334b49f1cfd4dc1947f7a3184dc0a7ac  (VaultAdminCap)
0x4f8f0302066d9c5ce52edce97b72ecc9551fe6df8fc2835adfb36c08a3d222a9  (ComplianceAdminCap)
0x5d5412e329d525d734874748cd31278a43aa7ef7386ff7b208e4e6221d3b1006  (SENIOR_COIN>)
0x648d438e1c5793bcecf1fcda7e1e81195b20718fd5589b42e7f6edd7dd595620  (SeniorTreasury)
0x7656909ee1803eb6e8a755ba03a19755f3c0f3268b480df1dc83d3bbbd579743  (AdminCap)
0x7993a6ebb797318be3c120535b0681f818009b9ce7bcb05461a94723cf3bd5b5  (JuniorTreasury)
0x8fc339ca7536a4a4561edf51f09554611b237e5fb59191b82527626dcbe7dc2f  (ComplianceRegistry)
0x9578e17217ec86a370c226ab932411a56b481e0439e7c9b2ce1cc3b1c57b5ba4  (TrancheAdminCap)
0x9d3301cfabb2edf33192b6b78a362a0ab55064fdc8ec8b77c2a1576645aa86ae  (WaterfallState)
0xa94ccf119bf93883d7bb8e824e9c418cf7d32ad771775f2daf67a8c14eec73bb  (TrancheRegistry)
0xb46f455cffc1a0e8d367571796c31d7fba170a18e7f0ef92ea16d5811cd3a912  (MezzTreasury)
0xbe4ecded29499b3227c5b681fba7fb04348bff28f5e3ae9bcb9d830fde60506a  (IssuanceOwnerCap)
0xc9e15ee8498adf178f37c4a4097523205df09925d4b0ea197c3df7c8480336ff  (UpgradeCap)
0xd2aa5176cab327a0f9fbe94d0d395543c95f6affd4dca4e69ccf65e8a90c05ba  (JUNIOR_COIN>)
0xd43d9183e5ae130170fc703d8ef0bc4334d18f15f53ea0f609110b3b9f589e4c  (PoolState)

Updated Objects:
--------------------------------------
0x13e9eee5e66fe53e38c9c59e700088e4f16f5ed74e35ffce0524010d1e12fe19  (IOTA>)
```


