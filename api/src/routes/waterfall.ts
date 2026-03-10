import { Router, Request, Response } from 'express';
import * as waterfall from '../services/waterfallService';

// ─── Waterfall Router ─────────────────────────────────────────────────────────

export const router = Router();

router.get('/', async (req: Request, res: Response) => {
  const data = await waterfall.getWaterfallState(req.network);
  res.json({ success: true, data, network: req.network });
});

router.post('/initialise', async (req: Request, res: Response) => {
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

router.post('/accrue-interest', async (req: Request, res: Response) => {
  const tx = await waterfall.accrueInterest(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/deposit-payment', async (req: Request, res: Response) => {
  const { amount } = req.body;
  const tx = await waterfall.depositPayment(BigInt(amount), req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/run', async (req: Request, res: Response) => {
  const tx = await waterfall.runWaterfall(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/turbo-mode', async (req: Request, res: Response) => {
  const tx = await waterfall.triggerTurboMode(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/default-mode/admin', async (req: Request, res: Response) => {
  const tx = await waterfall.triggerDefaultModeAdmin(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/default-mode/pool', async (req: Request, res: Response) => {
  const { poolCapId } = req.body;
  const tx = await waterfall.triggerDefaultModePool(poolCapId, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

export default router;