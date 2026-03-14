import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { registryService } from "../services/contracts/registry.service";
import * as poolService from "../services/contracts/pool.service";

export const poolRouter = Router();
poolRouter.use(requireWriteAccess);

// ── Schemas ────────────────────────────────────────────────────────────────────

const CreatePoolSchema = z.object({
  spv:            z.string(),
  poolId:         z.string().min(1),
  originator:     z.string(),
  totalPoolValue: z.string().transform(BigInt),
  interestRate:   z.number().int().min(0).max(10000),
  maturityDate:   z.number().int().positive(),
  assetHash:      z.string().regex(/^(0x)?[0-9a-fA-F]{64}$/),
  oracleAddress:  z.string(),
});

const SetContractsSchema = z.object({
  trancheFactory:   z.string(),
  issuanceContract: z.string(),
  waterfallEngine:  z.string(),
  oracleAddress:    z.string(),
});

const StartIssuanceSchema = z.object({
  issuanceStateId: z.string(),
  saleStart:       z.number().int().positive(),
  saleEnd:         z.number().int().positive(),
  priceSenior:     z.string().transform(BigInt),
  priceMezz:       z.string().transform(BigInt),
  priceJunior:     z.string().transform(BigInt),
});

const DepositPaymentSchema = z.object({
  amount: z.string().transform(BigInt),
});

// ── Pool lifecycle ─────────────────────────────────────────────────────────────

// POST /pools
poolRouter.post("/", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body   = CreatePoolSchema.parse(req.body);
    const digest = await poolService.createPool(body);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/set-contracts
poolRouter.post("/:poolObjId/set-contracts", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body   = SetContractsSchema.parse(req.body);
    const digest = await poolService.setContracts({ poolStateId: req.params.poolObjId, ...body });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/initialise
poolRouter.post("/:poolObjId/initialise", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const digest = await poolService.initialisePool(req.params.poolObjId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/activate
poolRouter.post("/:poolObjId/activate", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const digest = await poolService.activatePool(req.params.poolObjId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/default
poolRouter.post("/:poolObjId/default", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const digest = await poolService.markDefaultAdmin(req.params.poolObjId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/close
poolRouter.post("/:poolObjId/close", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const digest = await poolService.closePool(req.params.poolObjId);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// ── Issuance ───────────────────────────────────────────────────────────────────

// POST /pools/:poolObjId/issuance/start
poolRouter.post("/:poolObjId/issuance/start", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body   = StartIssuanceSchema.parse(req.body);
    const digest = await poolService.startIssuance({ poolStateId: req.params.poolObjId, ...body });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/issuance/end
poolRouter.post("/:poolObjId/issuance/end", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.endIssuance(pool.contracts.issuanceContract);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// ── Waterfall ──────────────────────────────────────────────────────────────────

// POST /pools/:poolObjId/waterfall/deposit
poolRouter.post("/:poolObjId/waterfall/deposit", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const { amount } = DepositPaymentSchema.parse(req.body);
    const pool       = await registryService.getPool(req.params.poolObjId);
    const digest     = await poolService.depositPayment(pool.contracts.waterfallEngine, amount);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/accrue
poolRouter.post("/:poolObjId/waterfall/accrue", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.accrueInterest(pool.contracts.waterfallEngine);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/run
poolRouter.post("/:poolObjId/waterfall/run", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.runWaterfall(pool.contracts.waterfallEngine);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/turbo
poolRouter.post("/:poolObjId/waterfall/turbo", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.triggerTurboMode(pool.contracts.waterfallEngine);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/waterfall/default
poolRouter.post("/:poolObjId/waterfall/default", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const pool   = await registryService.getPool(req.params.poolObjId);
    const digest = await poolService.triggerDefaultMode(pool.contracts.waterfallEngine);
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});

// POST /pools/:poolObjId/set-contract-objects
// Links the shared object IDs of the three downstream contracts into PoolState.
// Must be called after create_issuance_state, create_tranches, and initialise_waterfall
// have all been executed and their shared object IDs are known.
const SetContractObjectsSchema = z.object({
  trancheFactoryObj:   z.string(),
  issuanceContractObj: z.string(),
  waterfallEngineObj:  z.string(),
});

poolRouter.post("/:poolObjId/set-contract-objects", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const body   = SetContractObjectsSchema.parse(req.body);
    const digest = await poolService.setContractObjects({ poolStateId: req.params.poolObjId, ...body });
    res.status(202).json({ digest });
  } catch (e) { next(e); }
});
