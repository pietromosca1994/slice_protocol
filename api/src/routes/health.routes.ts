import { Router, Request, Response } from "express";
import { iotaClient } from "../services/iota-client";
import { config } from "../config";
import { logger } from "../utils/logger"

export const healthRouter = Router();

healthRouter.get("/", async (_req: Request, res: Response) => {
  try {
    const chainId = await iotaClient.getChainIdentifier();
    res.json({
      status:          "ok",
      network:         config.network,
      chainId,
      rpcUrl:          config.rpcUrl,
      readOnly:        config.readOnly,
      spvRegistryId:   config.spvRegistryId,
    });
  } catch (err) {                                                                                                                                     
    logger.warn({ err }, "Health check failed");
    res.status(503).json({ status: "degraded", reason: "Cannot reach IOTA RPC" });
  }
});
