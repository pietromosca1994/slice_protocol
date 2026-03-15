import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { registryService } from "../services/contracts/registry.service";
import * as poolService from "../services/contracts/pool.service";
import { deploySecuritizationPackage, extractObjectId } from "../services/contracts/deploy.service";
import { getKeypair } from "../services/iota-client";

export const poolContractRouter = Router();
poolContractRouter.use(requireWriteAccess);

// ── Schemas ────────────────────────────────────────────────────────────────────

const CreatePoolSchema = z.object({
  // Pool core
  spv:            z.string(),
  poolId:         z.string().min(1),
  originator:     z.string(),
  totalPoolValue: z.string().transform(BigInt),
  interestRate:   z.number().int().min(0).max(10000),
  maturityDate:   z.number().int().positive(),
  assetHash:      z.string().regex(/^(0x)?[0-9a-fA-F]{64}$/),
  oracleAddress:  z.string(),
  // Tranche token supply caps
  seniorSupplyCap: z.string().transform(BigInt),
  mezzSupplyCap:   z.string().transform(BigInt),
  juniorSupplyCap: z.string().transform(BigInt),
  // Tranche face values (outstanding principal in stablecoin base units).
  // Price per token is derived as faceValue / supplyCap.
  seniorFaceValue: z.string().transform(BigInt),
  mezzFaceValue:   z.string().transform(BigInt),
  juniorFaceValue: z.string().transform(BigInt),
  // Waterfall interest rates (basis points)
  seniorRateBps:    z.number().int().min(0),
  mezzRateBps:      z.number().int().min(0),
  juniorRateBps:    z.number().int().min(0),
  // Payment frequency: 0 = Monthly, 1 = Quarterly
  paymentFrequency: z.number().int().min(0).max(1),
  // Coin type for IssuanceState (e.g. "0x2::iota::IOTA")
  coinType: z.string(),
});

// ── POST /pools — full one-shot orchestration ──────────────────────────────────
//
// Sequence:
//  1. Deploy fresh securitization package
//  2. create_pool (register in SPVRegistry, emit PoolState)
//  3. set_contracts (deployer addresses)
//  4. initialise_pool
//  5. create_tranches
//  6. create_issuance_state  (prices derived as faceValue / supplyCap)
//  6b. create_vault (VaultBalance for the stablecoin coinType)
//  7. set_contract_objects (link shared object IDs into PoolState, including vault)
//  8. initialise_waterfall  (outstanding = faceValue, no derivation needed)
//  9. activate_pool
//
poolContractRouter.post("/", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body = CreatePoolSchema.parse(req.body);

    const signerAddress = getKeypair().getPublicKey().toIotaAddress();

    // 1. Deploy securitization package ────────────────────────────────────────
    const deployResult = await deploySecuritizationPackage();
    const {
      packageId,
      trancheRegistryId,
      waterfallStateId,
      issuanceOwnerCapId,
    } = deployResult;

    // 2. create_pool ──────────────────────────────────────────────────────────
    const { objectChanges: poolChanges } = await poolService.createPool({
      spv:                     body.spv,
      poolId:                  body.poolId,
      originator:              body.originator,
      totalPoolValue:          body.totalPoolValue,
      interestRate:            body.interestRate,
      maturityDate:            body.maturityDate,
      assetHash:               body.assetHash,
      oracleAddress:           body.oracleAddress,
      securitizationPackageId: packageId,
    });
    const poolStateId = extractObjectId(poolChanges, "::pool_contract::PoolState");

    // 3. set_contracts (deployer addresses — all three are the signer) ─────────
    await poolService.setContracts({
      poolStateId,
      trancheFactory:          signerAddress,
      issuanceContract:        signerAddress,
      waterfallEngine:         signerAddress,
      oracleAddress:           body.oracleAddress,
      securitizationPackageId: packageId,
    });

    // 4. initialise_pool ──────────────────────────────────────────────────────
    await poolService.initialisePool(poolStateId, packageId);

    // 5. create_tranches ──────────────────────────────────────────────────────
    await poolService.createTranches({
      trancheRegistryId,
      poolStateId,
      seniorCap:               body.seniorSupplyCap,
      mezzCap:                 body.mezzSupplyCap,
      juniorCap:               body.juniorSupplyCap,
      issuanceContractAddr:    signerAddress,
      securitizationPackageId: packageId,
    });

    // 6. create_issuance_state ────────────────────────────────────────────────
    // Price per token = faceValue / supplyCap (integer division in base units).
    const { issuanceStateId } = await poolService.createIssuanceState({
      issuanceOwnerCapId,
      poolObjId:               poolStateId,
      priceSenior:             body.seniorFaceValue / body.seniorSupplyCap,
      priceMezz:               body.mezzFaceValue   / body.mezzSupplyCap,
      priceJunior:             body.juniorFaceValue  / body.juniorSupplyCap,
      coinType:                body.coinType,
      securitizationPackageId: packageId,
    });

    // 6b. create_vault ────────────────────────────────────────────────────────
    const { vaultId } = await poolService.createVault(body.coinType);

    // 7. set_contract_objects (link shared object IDs into PoolState) ──────────
    await poolService.setContractObjects({
      poolStateId,
      trancheFactoryObj:       trancheRegistryId,
      issuanceContractObj:     issuanceStateId,
      waterfallEngineObj:      waterfallStateId,
      paymentVaultObj:         vaultId,
      securitizationPackageId: packageId,
    });

    // 8. initialise_waterfall ─────────────────────────────────────────────────
    // Outstanding principal is the face value directly — no derivation needed.
    await poolService.initialiseWaterfall({
      waterfallStateId,
      poolObjId:               poolStateId,
      seniorOutstanding:       body.seniorFaceValue,
      mezzOutstanding:         body.mezzFaceValue,
      juniorOutstanding:       body.juniorFaceValue,
      seniorRateBps:           body.seniorRateBps,
      mezzRateBps:             body.mezzRateBps,
      juniorRateBps:           body.juniorRateBps,
      paymentFrequency:        body.paymentFrequency,
      poolContractAddr:        body.oracleAddress,
      securitizationPackageId: packageId,
    });

    // 9. activate_pool ────────────────────────────────────────────────────────
    await poolService.activatePool(poolStateId, packageId);

    res.status(201).json({ poolStateId, securitizationPackageId: packageId, issuanceStateId, vaultId });
  } catch (e) { next(e); }
});

// ── Pool lifecycle ─────────────────────────────────────────────────────────────

// POST /pools/:poolObjId/activate
poolContractRouter.post("/:poolObjId/activate", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.activatePool(req.params.poolObjId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/default
poolContractRouter.post("/:poolObjId/default", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.markDefaultAdmin(req.params.poolObjId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/close
poolContractRouter.post("/:poolObjId/close", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.closePool(req.params.poolObjId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});
