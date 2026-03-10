import { Router, Request, Response } from 'express';
import * as compliance from '../services/complianceService';

const router = Router();

// GET /compliance — fetch registry state
router.get('/', async (req: Request, res: Response) => {
  const data = await compliance.getRegistryState(req.network);
  res.json({ success: true, data, network: req.network });
});

// GET /compliance/investor/:address
router.get('/investor/:address', async (req: Request, res: Response) => {
  const data = await compliance.getInvestorRecord(req.params.address, req.network);
  if (!data) {
    res.status(404).json({ success: false, error: 'Investor not found', network: req.network });
    return;
  }
  res.json({ success: true, data, network: req.network });
});

// POST /compliance/restrictions
router.post('/restrictions', async (req: Request, res: Response) => {
  const { enabled } = req.body;
  const tx = await compliance.setTransferRestrictions(Boolean(enabled), req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /compliance/default-holding-period
router.post('/default-holding-period', async (req: Request, res: Response) => {
  const { holdingPeriodMs } = req.body;
  const tx = await compliance.setDefaultHoldingPeriod(BigInt(holdingPeriodMs), req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /compliance/investors — add investor
router.post('/investors', async (req: Request, res: Response) => {
  const { investor, accreditationLevel, jurisdiction, didObjectId, customHoldingMs } = req.body;
  const tx = await compliance.addInvestor(
    {
      investor,
      accreditationLevel: Number(accreditationLevel),
      jurisdiction,
      didObjectId,
      customHoldingMs: BigInt(customHoldingMs ?? 0),
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// DELETE /compliance/investors/:address — remove investor
router.delete('/investors/:address', async (req: Request, res: Response) => {
  const tx = await compliance.removeInvestor(req.params.address, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// PATCH /compliance/investors/:address/accreditation
router.patch('/investors/:address/accreditation', async (req: Request, res: Response) => {
  const { newLevel } = req.body;
  const tx = await compliance.updateAccreditation(
    req.params.address,
    Number(newLevel),
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

export default router;
