import { Router, Request, Response } from 'express';
import * as issuance from '../services/issuanceService';

const router = Router();

// GET /issuance/:stateId — fetch issuance state
router.get('/:stateId', async (req: Request, res: Response) => {
  const data = await issuance.getIssuanceState(req.params.stateId, req.network);
  res.json({ success: true, data, network: req.network });
});

// POST /issuance/create-state
router.post('/create-state', async (req: Request, res: Response) => {
  const { coinType } = req.body;
  const tx = await issuance.createIssuanceState(coinType, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /issuance/start
router.post('/start', async (req: Request, res: Response) => {
  const { issuanceStateId, coinType, saleStart, saleEnd, priceSenior, priceMezz, priceJunior } = req.body;
  const tx = await issuance.startIssuance(
    {
      issuanceStateId,
      coinType,
      saleStart: BigInt(saleStart),
      saleEnd: BigInt(saleEnd),
      priceSenior: BigInt(priceSenior),
      priceMezz: BigInt(priceMezz),
      priceJunior: BigInt(priceJunior),
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /issuance/end
router.post('/end', async (req: Request, res: Response) => {
  const { issuanceStateId, coinType } = req.body;
  const tx = await issuance.endIssuance({ issuanceStateId, coinType }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /issuance/invest
router.post('/invest', async (req: Request, res: Response) => {
  const { issuanceStateId, coinType, trancheType, paymentCoinId } = req.body;
  const tx = await issuance.invest(
    {
      issuanceStateId,
      coinType,
      trancheType: Number(trancheType),
      paymentCoinId,
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /issuance/refund
router.post('/refund', async (req: Request, res: Response) => {
  const { issuanceStateId, coinType, investor } = req.body;
  const tx = await issuance.refund({ issuanceStateId, coinType, investor }, req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /issuance/release-to-vault
router.post('/release-to-vault', async (req: Request, res: Response) => {
  const { issuanceStateId, coinType, vaultAddress } = req.body;
  const tx = await issuance.releaseFundsToVault(
    { issuanceStateId, coinType, vaultAddress },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

export default router;
