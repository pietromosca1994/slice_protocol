import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { registryService } from "../services/contracts/registry.service";
import { ApiError } from "../utils/errors";

export const spvRegistryRouter = Router();


// GET /registry
// Returns SPVRegistry metadata (pool count, package IDs)
spvRegistryRouter.get("/", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const meta = await registryService.getRegistryMeta();
    res.json(meta);
  } catch (e) { next(e); }
});

// GET /registry/pools
// Returns all pool summaries
spvRegistryRouter.get("/pools", async (_req: Request, res: Response, next: NextFunction) => {
  try {
    const pools = await registryService.getAllPools();
    res.json(pools);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId
// Returns full pool detail (pool + tranches + issuance + waterfall)
spvRegistryRouter.get("/pools/:poolObjId", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { poolObjId } = req.params;
    const full = await registryService.getFullPool(poolObjId);
    res.json(full);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/tranches
spvRegistryRouter.get("/pools/:poolObjId/tranches", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (!pool.contractObjects.trancheFactoryObj) throw ApiError.notFound("TrancheFactory not linked yet");
    const tranches = await registryService.getTranches(pool.contractObjects.trancheFactoryObj);
    res.json(tranches);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/issuance
spvRegistryRouter.get("/pools/:poolObjId/issuance", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (!pool.contractObjects.issuanceContractObj) throw ApiError.notFound("IssuanceContract not linked yet");
    const issuance = await registryService.getIssuance(pool.contractObjects.issuanceContractObj);
    res.json(issuance);
  } catch (e) { next(e); }
});

// GET /registry/pools/:poolObjId/waterfall
spvRegistryRouter.get("/pools/:poolObjId/waterfall", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool = await registryService.getPool(req.params.poolObjId);
    if (!pool.contractObjects.waterfallEngineObj) throw ApiError.notFound("WaterfallEngine not linked yet");
    const waterfall = await registryService.getWaterfall(pool.contractObjects.waterfallEngineObj);
    res.json(waterfall);
  } catch (e) { next(e); }
});

// GET /registry/spv/:spvAddress/pools
// Returns pool IDs owned by a specific SPV address
spvRegistryRouter.get("/spv/:spvAddress/pools", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const ids = await registryService.getPoolIdsForSpv(req.params.spvAddress);
    res.json({ spv: req.params.spvAddress, poolIds: ids });
  } catch (e) { next(e); }
});
