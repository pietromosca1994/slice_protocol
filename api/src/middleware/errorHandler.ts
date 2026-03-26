import { Request, Response, NextFunction } from "express";
import { ZodError } from "zod";
import { ApiError } from "../utils/errors";
import { logger } from "../utils/logger";

// ── Move abort code → human-readable message ──────────────────────────────────
// Codes match packages/securitization/sources/libraries/errors.move
// and packages/spv/sources/libraries/errors.move
const MOVE_ABORT_MESSAGES: Record<number, string> = {
  // PoolContract (1xxx)
  1000: "Pool has already been initialised",
  1001: "Pool has not yet been initialised",
  1002: "Caller is not the pool admin",
  1003: "Caller is not the authorised oracle",
  1004: "Pool is not in the required status for this operation",
  1005: "Maturity date is in the past",
  1006: "Pool value cannot be zero",
  1007: "Asset hash cannot be empty",
  1008: "Downstream contract addresses have not been set",
  1009: "Oracle timestamp is in the future",
  // TrancheFactory (2xxx)
  2000: "Tranches have already been created for this pool",
  2001: "Tranches have not yet been created",
  2002: "Minting has been permanently disabled",
  2003: "Requested mint would exceed the tranche supply cap",
  2004: "Caller is not the authorised issuance contract",
  2005: "Supply cap cannot be zero",
  2006: "Cannot melt more tokens than are currently minted",
  2007: "Unknown tranche type provided",
  // IssuanceContract (3xxx)
  3000: "Issuance window is not currently active",
  3001: "Issuance window is already active",
  3002: "Sale end must be after sale start",
  3003: "Investment amount results in zero tokens",
  3004: "Price per unit cannot be zero",
  3005: "No subscription found for this investor",
  3006: "Refund not permitted — issuance succeeded",
  3007: "Caller is not a verified investor (not on compliance whitelist)",
  3008: "Issuance has already ended",
  3009: "Pool is not in Active status",
  3010: "Vault passed to release does not match the pool's registered vault",
  // WaterfallEngine (4xxx)
  4000: "No distributable funds available",
  4001: "Waterfall is already in the requested mode",
  4002: "Turbo mode can only be activated when waterfall is in Normal mode",
  4003: "Only pool contract or admin can set Default mode",
  4004: "Interest accrual: no time has elapsed since last accrual",
  // ComplianceRegistry (5xxx)
  5000: "Investor is not on the whitelist",
  5001: "Investor is already registered",
  5002: "Accreditation level is invalid (must be 1–4)",
  5003: "Jurisdiction cannot be empty",
  5004: "Transfer is blocked by compliance rules",
  5005: "Investor is still within their mandatory holding period",
  5006: "Caller is not the compliance admin",
  // PaymentVault (6xxx)
  6000: "Caller is not an authorised depositor",
  6001: "Vault has insufficient balance for this release",
  6002: "Release amount cannot be zero",
  6003: "Deposit amount cannot be zero",
  6004: "Caller is not the vault admin",
  6005: "Depositor is already authorised",
  6006: "Coin type does not match the vault's stablecoin",
  // SPVRegistry (7xxx)
  7000: "Pool object ID is already registered in the SPVRegistry",
  7001: "Pool object ID is not present in the SPVRegistry",
  7002: "Pool ID is already taken — choose a unique poolId",
};

function translateMoveAbort(message: string): { status: number; text: string } | null {
  const match = message.match(/Abort Code:\s*(\d+)/);
  if (!match) return null;
  const code = parseInt(match[1], 10);
  const text = MOVE_ABORT_MESSAGES[code];
  if (!text) return null;
  // 409 for "already exists / duplicate" codes, 400 for everything else
  const status = [1000, 2000, 3001, 3008, 5001, 6005, 7000, 7002].includes(code) ? 409 : 400;
  return { status, text: `${text} (abort code ${code})` };
}

export function errorHandler(
  err: unknown,
  _req: Request,
  res: Response,
  _next: NextFunction,
): void {
  if (err instanceof ApiError) {
    res.status(err.statusCode).json({
      error:   err.message,
      details: err.details ?? undefined,
    });
    return;
  }

  if (err instanceof ZodError) {
    res.status(400).json({
      error:   "Validation error",
      details: err.flatten().fieldErrors,
    });
    return;
  }

  logger.error({ err }, "Unhandled error");
  const message = err instanceof Error ? err.message : "Internal server error";

  // Translate Move abort codes into readable messages
  const translated = translateMoveAbort(message);
  if (translated) {
    res.status(translated.status).json({ error: translated.text });
    return;
  }

  res.status(500).json({ error: message });
}
