import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { registryService } from "../services/contracts/registry.service";
import * as poolService from "../services/contracts/pool.service";
import { deploySecuritizationPackage, setupPool } from "../services/contracts/deploy.service";
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

// ── POST /pools — atomic two-transaction pool creation ─────────────────────────
//
// Tx 1: Deploy fresh securitization package + bootstrap tranche treasury caps.
// Tx 2: Single PTB that creates, wires, activates, and registers the pool.
//       If any step aborts the entire PTB rolls back — SPVRegistry is never touched.
//
poolContractRouter.post("/", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body          = CreatePoolSchema.parse(req.body);
    const signerAddress = getKeypair().getPublicKey().toIotaAddress();

    const deployResult = await deploySecuritizationPackage();
    const { packageId, poolStateId, issuanceStateId, vaultId } = {
      packageId: deployResult.packageId,
      ...await setupPool(deployResult, body, signerAddress),
    };

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
