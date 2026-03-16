import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { registryService } from "../services/contracts/registry.service";
import * as poolService from "../services/contracts/pool.service";

export const issuanceContractRouter = Router();
issuanceContractRouter.use(requireWriteAccess);

// ── Schemas ────────────────────────────────────────────────────────────────────

const MIN_MS_TIMESTAMP = 1_000_000_000_000; // < this looks like seconds, not ms

const StartIssuanceSchema = z.object({
  saleStart: z.number().int().positive()
    .refine(v => v >= MIN_MS_TIMESTAMP, { message: "saleStart must be a Unix timestamp in milliseconds (≥ 1_000_000_000_000)" }),
  saleEnd: z.number().int().positive()
    .refine(v => v >= MIN_MS_TIMESTAMP, { message: "saleEnd must be a Unix timestamp in milliseconds (≥ 1_000_000_000_000)" }),
}).refine(b => b.saleEnd > b.saleStart, {
  message: "saleEnd must be greater than saleStart",
  path: ["saleEnd"],
}).refine(b => b.saleEnd > Date.now(), {
  message: "saleEnd is in the past — use a future Unix timestamp in milliseconds",
  path: ["saleEnd"],
});

const InvestSchema = z.object({
  trancheType:          z.number().int().min(0).max(2),
  amount:               z.string().transform(BigInt),
  complianceRegistryId: z.string(),
});

// ── Routes ─────────────────────────────────────────────────────────────────────

// POST /pools/:poolObjId/issuance/start
issuanceContractRouter.post("/:poolObjId/issuance/start", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body = StartIssuanceSchema.parse(req.body);
    const pool = await registryService.getPool(req.params.poolObjId);
    const issuanceStateId = pool.contractObjects.issuanceContractObj;
    if (!issuanceStateId) {
      throw new Error("Pool has no linked issuance state object");
    }
    const digest = await poolService.startIssuance({
      issuanceStateId,
      poolStateId:             req.params.poolObjId,
      saleStart:               body.saleStart,
      saleEnd:                 body.saleEnd,
      securitizationPackageId: pool.securitizationPackageId,
    });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/issuance/end
issuanceContractRouter.post("/:poolObjId/issuance/end", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    const issuanceStateId = pool.contractObjects.issuanceContractObj;
    if (!issuanceStateId) {
      throw new Error("Pool has no linked issuance state object");
    }
    const digest = await poolService.endIssuance(issuanceStateId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/issuance/release
// Release all raised funds from IssuanceState into the PaymentVault.
// Requires a succeeded, ended issuance. coinType is derived from on-chain state.
issuanceContractRouter.post("/:poolObjId/issuance/release", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool            = await registryService.getPool(req.params.poolObjId);
    const issuanceStateId = pool.contractObjects.issuanceContractObj;
    const vaultId         = pool.contractObjects.paymentVaultObj;
    if (!issuanceStateId) throw new Error("Pool has no linked issuance state object");
    if (!vaultId)         throw new Error("Pool has no linked payment vault object");

    const { fetchObjectWithType } = await import("../services/iota-client");
    const { objectType } = await fetchObjectWithType(issuanceStateId);
    const coinTypeMatch  = objectType.match(/<(.+)>$/);
    if (!coinTypeMatch) throw new Error(`Could not extract coin type from IssuanceState type: ${objectType}`);
    const coinType = coinTypeMatch[1];

    const digest = await poolService.releaseFundsToVault({
      issuanceStateId,
      vaultId,
      coinType,
      securitizationPackageId: pool.securitizationPackageId,
    });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/issuance/invest
// Submits an investment on behalf of the signer. The stablecoin is taken from
// the signer's wallet; coinType is derived from the on-chain IssuanceState type.
issuanceContractRouter.post("/:poolObjId/issuance/invest", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body             = InvestSchema.parse(req.body);
    const pool             = await registryService.getPool(req.params.poolObjId);
    const issuanceStateId  = pool.contractObjects.issuanceContractObj;
    const trancheRegistryId = pool.contractObjects.trancheFactoryObj;
    if (!issuanceStateId)   throw new Error("Pool has no linked issuance state object");
    if (!trancheRegistryId) throw new Error("Pool has no linked tranche registry");

    const digest = await poolService.invest({
      issuanceStateId,
      trancheRegistryId,
      complianceRegistryId:    body.complianceRegistryId,
      trancheType:             body.trancheType,
      amount:                  body.amount,
      securitizationPackageId: pool.securitizationPackageId,
    });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});
