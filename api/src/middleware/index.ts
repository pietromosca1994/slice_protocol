import { Request, Response, NextFunction } from 'express';
import { Network } from '../types';
import { logger } from '../config/logger';

// ─── Resolve network from header / query ─────────────────────────────────────

export function networkMiddleware(
  req: Request,
  _res: Response,
  next: NextFunction,
) {
  const raw =
    (req.query['network'] as string) ??
    req.headers['x-iota-network'] ??
    process.env.IOTA_NETWORK ??
    'testnet';

  const valid: Network[] = ['mainnet', 'testnet', 'localnet'];
  req.network = valid.includes(raw as Network)
    ? (raw as Network)
    : 'testnet';

  next();
}

// ─── Error handler ────────────────────────────────────────────────────────────

export function errorHandler(
  err: Error,
  _req: Request,
  res: Response,
  _next: NextFunction,
) {
  logger.error(err.message, { stack: err.stack });
  res.status(500).json({
    success: false,
    error: err.message,
  });
}

// ─── Extend Express Request ───────────────────────────────────────────────────

declare global {
  namespace Express {
    interface Request {
      network: Network;
    }
  }
}
