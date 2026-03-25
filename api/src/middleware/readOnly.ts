import { Request, Response, NextFunction } from "express";
import { config } from "../config";

export function requireWriteAccess(_req: Request, res: Response, next: NextFunction): void {
  if (config.readOnly) {
    res.status(403).json({
      error: "API is running in read-only mode. Set ADMIN_SECRET_KEY to enable write operations.",
    });
    return;
  }
  next();
}
