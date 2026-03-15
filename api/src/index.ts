import express from "express";
import helmet from "helmet";
import cors from "cors";
import rateLimit from "express-rate-limit";
import pinoHttp from "pino-http";

import { config } from "./config";
import { logger } from "./utils/logger";
import { errorHandler } from "./middleware/errorHandler";
import { healthRouter }              from "./routes/health.routes";
import { spvRegistryRouter }         from "./routes/spv_registry.routes";
import { poolContractRouter }        from "./routes/pool_contract.routes";
import { issuanceContractRouter }    from "./routes/issuance_contract.routes";
import { waterfallEngineRouter }     from "./routes/waterfall_engine.routes";
import { complianceRegistryRouter }  from "./routes/compliance_registry.routes";
import { paymentVaultRouter }        from "./routes/payment_vault.routes";

const app = express();

// Serialize BigInt values (returned by the IOTA SDK) as strings
app.set("json replacer", (_key: string, value: unknown) =>
  typeof value === "bigint" ? value.toString() : value,
);

// ── Global middleware ──────────────────────────────────────────────────────────
app.use(helmet());
app.use(cors());
app.use(express.json());
app.use(pinoHttp({ logger }));
app.use(rateLimit({ windowMs: 60_000, max: 120, standardHeaders: true, legacyHeaders: false }));

// ── Routes ─────────────────────────────────────────────────────────────────────
app.use("/health",     healthRouter);
app.use("/registry",   spvRegistryRouter);
app.use("/pools",      poolContractRouter);
app.use("/pools",      issuanceContractRouter);
app.use("/pools",      waterfallEngineRouter);
app.use("/compliance", complianceRegistryRouter);
app.use("/vault",      paymentVaultRouter);

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
