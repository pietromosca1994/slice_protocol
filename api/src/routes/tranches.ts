import { Router, Request, Response } from 'express';
import * as tranche from '../services/trancheService';
import { TrancheTypeValue } from '../types';

const router = Router();

// GET /tranches — fetch registry
router.get('/', async (req: Request, res: Response) => {
  const data = await tranche.getTrancheRegistry(req.network);
  res.json({ success: true, data, network: req.network });
});

// GET /tranches/:type — 0=senior, 1=mezz, 2=junior
router.get('/:type', async (req: Request, res: Response) => {
  const t = Number(req.params.type) as TrancheTypeValue;
  if (![0, 1, 2].includes(t)) {
    res.status(400).json({ success: false, error: 'Invalid tranche type (0, 1, or 2)', network: req.network });
    return;
  }
  const data = await tranche.getTrancheInfo(t, req.network);
  res.json({ success: true, data, network: req.network });
});

// POST /tranches/bootstrap
router.post('/bootstrap', async (req: Request, res: Response) => {
  const { seniorTreasuryId, mezzTreasuryId, juniorTreasuryId } = req.body;
  const tx = await tranche.bootstrap(
    { seniorTreasuryId, mezzTreasuryId, juniorTreasuryId },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /tranches/create
router.post('/create', async (req: Request, res: Response) => {
  const { seniorCap, mezzCap, juniorCap, issuanceContract } = req.body;
  const tx = await tranche.createTranches(
    {
      seniorCap: BigInt(seniorCap),
      mezzCap: BigInt(mezzCap),
      juniorCap: BigInt(juniorCap),
      issuanceContract,
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /tranches/disable-minting
router.post('/disable-minting', async (req: Request, res: Response) => {
  const tx = await tranche.disableMinting(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /tranches/melt/senior
router.post('/melt/senior', async (req: Request, res: Response) => {
  const { coinObjectId } = req.body;
  const tx = await tranche.meltSenior(coinObjectId, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /tranches/melt/mezz
router.post('/melt/mezz', async (req: Request, res: Response) => {
  const { coinObjectId } = req.body;
  const tx = await tranche.meltMezz(coinObjectId, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /tranches/melt/junior
router.post('/melt/junior', async (req: Request, res: Response) => {
  const { coinObjectId } = req.body;
  const tx = await tranche.meltJunior(coinObjectId, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

export default router;
