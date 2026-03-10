import { Router, Request, Response } from 'express';
import * as vault from '../services/vaultService';
import * as waterfall from '../services/waterfallService';

// ─── Vault Router ─────────────────────────────────────────────────────────────

export const vaultRouter = Router();

vaultRouter.get('/:vaultId', async (req: Request, res: Response) => {
  const data = await vault.getVaultBalance(req.params.vaultId, req.network);
  res.json({ success: true, data, network: req.network });
});

vaultRouter.post('/create', async (req: Request, res: Response) => {
  const { coinType } = req.body;
  const tx = await vault.createVault(coinType, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

vaultRouter.post('/authorise-depositor', async (req: Request, res: Response) => {
  const { vaultId, coinType, depositor } = req.body;
  const tx = await vault.authoriseDepositor({ vaultId, coinType, depositor }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

vaultRouter.post('/revoke-depositor', async (req: Request, res: Response) => {
  const { vaultId, coinType, depositor } = req.body;
  const tx = await vault.revokeDepositor({ vaultId, coinType, depositor }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

vaultRouter.post('/deposit', async (req: Request, res: Response) => {
  const { vaultId, coinType, coinObjectId } = req.body;
  const tx = await vault.depositToVault({ vaultId, coinType, coinObjectId }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

vaultRouter.post('/release', async (req: Request, res: Response) => {
  const { vaultId, coinType, recipient, amount } = req.body;
  const tx = await vault.releaseFunds(
    { vaultId, coinType, recipient, amount: BigInt(amount) },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// ─── Waterfall Router ─────────────────────────────────────────────────────────

export const waterfallRouter = Router();

waterfallRouter.get('/', async (req: Request, res: Response) => {
  const data = await waterfall.getWaterfallState(req.network);
  res.json({ success: true, data, network: req.network });
});

waterfallRouter.post('/initialise', async (req: Request, res: Response) => {
  const {
    seniorOutstanding, mezzOutstanding, juniorOutstanding,
    seniorRateBps, mezzRateBps, juniorRateBps,
    paymentFrequency, poolContractAddr,
  } = req.body;
  const tx = await waterfall.initialiseWaterfall(
    {
      seniorOutstanding: BigInt(seniorOutstanding),
      mezzOutstanding: BigInt(mezzOutstanding),
      juniorOutstanding: BigInt(juniorOutstanding),
      seniorRateBps: Number(seniorRateBps),
      mezzRateBps: Number(mezzRateBps),
      juniorRateBps: Number(juniorRateBps),
      paymentFrequency: Number(paymentFrequency),
      poolContractAddr,
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/accrue-interest', async (req: Request, res: Response) => {
  const tx = await waterfall.accrueInterest(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/deposit-payment', async (req: Request, res: Response) => {
  const { amount } = req.body;
  const tx = await waterfall.depositPayment(BigInt(amount), req.network);
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/run', async (req: Request, res: Response) => {
  const tx = await waterfall.runWaterfall(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/turbo-mode', async (req: Request, res: Response) => {
  const tx = await waterfall.triggerTurboMode(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/default-mode/admin', async (req: Request, res: Response) => {
  const tx = await waterfall.triggerDefaultModeAdmin(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

waterfallRouter.post('/default-mode/pool', async (req: Request, res: Response) => {
  const { poolCapId } = req.body;
  const tx = await waterfall.triggerDefaultModePool(poolCapId, req.network);
  res.json({ success: true, data: tx, network: req.network });
});
