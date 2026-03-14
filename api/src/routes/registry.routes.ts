import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { registryService } from "../services/contracts/registry.service";
import { ApiError } from "../utils/errors";

export const registryRouter = Router();

// GET /registry
// Returns SPVRegistry metadata (pool count, package IDs)
registryRouter.get("/", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const meta = await registryService.getRegistryMeta();
    res.json(meta);
  } catch (e) { next(e); }
});

// GET /registry/pools
// Returns all pool summaries
registryRouter.get("/pools", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const pools = await registryService.getAllPools();
    res.json(pools);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId
// Returns full pool detail (pool + tranches + issuance + waterfall)
registryRouter.get("/pools/:poolObjId", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { poolObjId } = req.params;
    const full = await registryService.getFullPool(poolObjId);
    res.json(full);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/tranches
registryRouter.get("/pools/:poolObjId/tranches", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (pool.contracts.trancheFactory === "0x0") throw ApiError.notFound("TrancheFactory not linked yet");
    const tranches = await registryService.getTranches(pool.contracts.trancheFactory);
    res.json(tranches);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/issuance
registryRouter.get("/pools/:poolObjId/issuance", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (pool.contracts.issuanceContract === "0x0") throw ApiError.notFound("IssuanceContract not linked yet");
    const issuance = await registryService.getIssuance(pool.contracts.issuanceContract);
    res.json(issuance);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/waterfall
registryRouter.get("/pools/:poolObjId/waterfall", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (pool.contracts.waterfallEngine === "0x0") throw ApiError.notFound("WaterfallEngine not linked yet");
    const waterfall = await registryService.getWaterfall(pool.contracts.waterfallEngine);
    res.json(waterfall);
  } catch (e) { next(e); }
});

// GET /registry/spv/:spvAddress/pools
// Returns pool IDs owned by a specific SPV address
registryRouter.get("/spv/:spvAddress/pools", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const ids = await registryService.getPoolIdsForSpv(req.params.spvAddress);
    res.json({ spv: req.params.spvAddress, poolIds: ids });
  } catch (e) { next(e); }
});
