import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { registryService } from "../services/contracts/registry.service";
import * as poolService from "../services/contracts/pool.service";

export const waterfallEngineRouter = Router();
waterfallEngineRouter.use(requireWriteAccess);

// ── Schemas ────────────────────────────────────────────────────────────────────

const DepositPaymentSchema = z.object({
  amount: z.string().transform(BigInt),
});

// ── Routes ─────────────────────────────────────────────────────────────────────

// POST /pools/:poolObjId/waterfall/deposit
waterfallEngineRouter.post("/:poolObjId/waterfall/deposit", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { amount } = DepositPaymentSchema.parse(req.body);
    const pool       = await registryService.getPool(req.params.poolObjId);
    const waterfallStateId = pool.contractObjects.waterfallEngineObj;
    if (!waterfallStateId) {
      throw new Error("Pool has no linked waterfall state object");
    }
    const digest = await poolService.depositPayment(waterfallStateId, amount, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/accrue
waterfallEngineRouter.post("/:poolObjId/waterfall/accrue", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    const waterfallStateId = pool.contractObjects.waterfallEngineObj;
    if (!waterfallStateId) {
      throw new Error("Pool has no linked waterfall state object");
    }
    const digest = await poolService.accrueInterest(waterfallStateId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/run
waterfallEngineRouter.post("/:poolObjId/waterfall/run", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    const waterfallStateId = pool.contractObjects.waterfallEngineObj;
    if (!waterfallStateId) {
      throw new Error("Pool has no linked waterfall state object");
    }
    const digest = await poolService.runWaterfall(waterfallStateId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/turbo
waterfallEngineRouter.post("/:poolObjId/waterfall/turbo", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    const waterfallStateId = pool.contractObjects.waterfallEngineObj;
    if (!waterfallStateId) {
      throw new Error("Pool has no linked waterfall state object");
    }
    const digest = await poolService.triggerTurboMode(waterfallStateId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/default
waterfallEngineRouter.post("/:poolObjId/waterfall/default", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    const waterfallStateId = pool.contractObjects.waterfallEngineObj;
    if (!waterfallStateId) {
      throw new Error("Pool has no linked waterfall state object");
    }
    const digest = await poolService.triggerDefaultMode(waterfallStateId, pool.securitizationPackageId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});
