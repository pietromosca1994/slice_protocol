import { Router, Request, Response } from 'express';
import * as vault from '../services/vaultService';

// ─── Vault Router ─────────────────────────────────────────────────────────────

export const router = Router();

router.get('/:vaultId', async (req: Request, res: Response) => {
  const data = await vault.getVaultBalance(req.params.vaultId, req.network);
  res.json({ success: true, data, network: req.network });
});

router.post('/create', async (req: Request, res: Response) => {
  const { coinType } = req.body;
  const tx = await vault.createVault(coinType, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/authorise-depositor', async (req: Request, res: Response) => {
  const { vaultId, coinType, depositor } = req.body;
  const tx = await vault.authoriseDepositor({ vaultId, coinType, depositor }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/revoke-depositor', async (req: Request, res: Response) => {
  const { vaultId, coinType, depositor } = req.body;
  const tx = await vault.revokeDepositor({ vaultId, coinType, depositor }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/deposit', async (req: Request, res: Response) => {
  const { vaultId, coinType, coinObjectId } = req.body;
  const tx = await vault.depositToVault({ vaultId, coinType, coinObjectId }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

router.post('/release', async (req: Request, res: Response) => {
  const { vaultId, coinType, recipient, amount } = req.body;
  const tx = await vault.releaseFunds(
    { vaultId, coinType, recipient, amount: BigInt(amount) },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

export default router;
