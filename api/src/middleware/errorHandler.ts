import { Request, Response, NextFunction } from "express";
import { ZodError } from "zod";
import { ApiError } from "../utils/errors";
import { logger } from "../utils/logger";

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
  // Surface Move transaction errors and other runtime errors with their actual message.
  const message = err instanceof Error ? err.message : "Internal server error";
  res.status(500).json({ error: message });
}
