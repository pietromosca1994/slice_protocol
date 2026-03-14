import express from "express";
import helmet from "helmet";
import cors from "cors";
import rateLimit from "express-rate-limit";
import pinoHttp from "pino-http";

import { config } from "./config";
import { logger } from "./utils/logger";
import { errorHandler } from "./middleware/errorHandler";
import { healthRouter }     from "./routes/health.routes";
import { registryRouter }   from "./routes/registry.routes";
import { poolRouter }       from "./routes/pool.routes";
import { complianceRouter } from "./routes/compliance.routes";
import { vaultRouter }      from "./routes/vault.routes";

const app = express();

// ── Global middleware ──────────────────────────────────────────────────────────
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(pinoHttp({ logger }));
app.use(rateLimit({ windowMs: 60_000, max: 120, standardHeaders: true, legacyHeaders: false }));

// ── Routes ─────────────────────────────────────────────────────────────────────
app.use("/health",     healthRouter);
app.use("/registry",   registryRouter);
app.use("/pools",      poolRouter);
app.use("/compliance", complianceRouter);
app.use("/vault",      vaultRouter);

// ── 404 ────────────────────────────────────────────────────────────────────────
app.use((_req, res) => res.status(404).json({ error: "Not found" }));

// ── Error handler (must be last) ───────────────────────────────────────────────
app.use(errorHandler);

// ── Start ──────────────────────────────────────────────────────────────────────
app.listen(config.port, () => {
  logger.info({
    port:          config.port,
    network:       config.network,
    readOnly:      config.readOnly,
    spvRegistryId: config.spvRegistryId,
  }, "🚀  Securitization API started");
});

export default app;
