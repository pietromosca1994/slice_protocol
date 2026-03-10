import { Router, Request, Response } from 'express';
import * as pool from '../services/poolService';

const router = Router();

// GET /pool — fetch pool state
router.get('/', async (req: Request, res: Response) => {
  const data = await pool.getPoolState(req.network);
  res.json({ success: true, data, network: req.network });
});

// POST /pool/set-contracts
router.post('/set-contracts', async (req: Request, res: Response) => {
  const { trancheFactory, issuanceContract, waterfallEngine, oracleAddress } = req.body;
  const tx = await pool.setContracts(
    { trancheFactory, issuanceContract, waterfallEngine, oracleAddress },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/initialise
router.post('/initialise', async (req: Request, res: Response) => {
  const {
    poolId, originator, spv, totalPoolValue,
    interestRate, maturityDate, assetHash,
  } = req.body;
  const tx = await pool.initialisePool(
    {
      poolId,
      originator,
      spv,
      totalPoolValue: BigInt(totalPoolValue),
      interestRate: Number(interestRate),
      maturityDate: BigInt(maturityDate),
      assetHash,
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/activate
router.post('/activate', async (req: Request, res: Response) => {
  const tx = await pool.activatePool(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/update-performance
router.post('/update-performance', async (req: Request, res: Response) => {
  const { newOutstandingPrincipal, oracleTimestamp } = req.body;
  const tx = await pool.updatePerformanceData(
    {
      newOutstandingPrincipal: BigInt(newOutstandingPrincipal),
      oracleTimestamp: BigInt(oracleTimestamp),
    },
    req.network,
  );
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/mark-default (oracle)
router.post('/mark-default/oracle', async (req: Request, res: Response) => {
  const tx = await pool.markDefaultOracle(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/mark-default (admin)
router.post('/mark-default/admin', async (req: Request, res: Response) => {
  const tx = await pool.markDefaultAdmin(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

// POST /pool/close
router.post('/close', async (req: Request, res: Response) => {
  const tx = await pool.closePool(req.network);
  res.json({ success: true, data: tx, network: req.network });
});

export default router;
