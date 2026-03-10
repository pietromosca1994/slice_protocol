import 'express-async-errors';
import express from 'express';
import cors from 'cors';
import helmet from 'helmet';
import morgan from 'morgan';

import { config } from './config';
import { logger } from './config/logger';
import { networkMiddleware, errorHandler } from './middleware';

import poolRoutes from './routes/pool';
import complianceRoutes from './routes/compliance';
import trancheRoutes from './routes/tranches';
import issuanceRoutes from './routes/issuance';
import vaultRoutes from './routes/vault';
import waterfallRoutes from './routes/waterfall';

const app = express();

// ─── Core middleware ──────────────────────────────────────────────────────────
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(morgan('combined', { stream: { write: (msg) => logger.info(msg.trim()) } }));

// ─── Network resolution (reads ?network= or X-IOTA-Network header) ───────────
app.use(networkMiddleware);

// ─── Health check ─────────────────────────────────────────────────────────────
app.get('/health', (_req, res) => {
  res.json({
    status: 'ok',
    service: 'iota-securitization-api',
    version: '1.0.0',
    defaultNetwork: config.network,
    packageId: config.packageId || 'not-configured',
  });
});

// ─── API routes ───────────────────────────────────────────────────────────────
app.use('/api/v1/pool', poolRoutes);
app.use('/api/v1/compliance', complianceRoutes);
app.use('/api/v1/tranches', trancheRoutes);
app.use('/api/v1/issuance', issuanceRoutes);
app.use('/api/v1/vault', vaultRoutes);
app.use('/api/v1/waterfall', waterfallRoutes);

// ─── 404 ──────────────────────────────────────────────────────────────────────
app.use((_req, res) => {
  res.status(404).json({ success: false, error: 'Route not found' });
});

// ─── Error handler ────────────────────────────────────────────────────────────
app.use(errorHandler);

// ─── Start ────────────────────────────────────────────────────────────────────
app.listen(config.port, () => {
  logger.info(`IOTA Securitization API listening on port ${config.port}`);
  logger.info(`Default network: ${config.network}`);
  logger.info(`Package ID: ${config.packageId || '(not set)'}`);
});

export default app;
