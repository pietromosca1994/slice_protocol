import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { iotaClient } from "../services/iota-client";
import { config } from "../config";
import * as poolService from "../services/contracts/pool.service";

export const complianceRouter = Router();

// ── Schemas ────────────────────────────────────────────────────────────────────

const AddInvestorSchema = z.object({
  investor:           z.string().regex(/^0x[0-9a-fA-F]+/, "Must be a valid IOTA address"),
  accreditationLevel: z.number().int().min(1).max(4),
  jurisdiction:       z.string().length(2, "Must be ISO-3166-1 alpha-2 (e.g. 'US')").toUpperCase(),
  didObjectId:        z.string(),
  customHoldingMs:    z.number().int().min(0).default(0),
});

const UpdateAccreditationSchema = z.object({
  newLevel: z.number().int().min(1).max(4),
});

// ── Routes ─────────────────────────────────────────────────────────────────────

// GET /compliance/:registryId/investor/:address
// Check whether an investor is whitelisted (read-only, no key required)
complianceRouter.get(
  "/:registryId/investor/:address",
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { registryId, address } = req.params;

      // Read the investors Table via dynamic field lookup
      const reg = await iotaClient.getObject({
        id: registryId,
        options: { showContent: true },
      });

      if (reg.data?.content?.dataType !== "moveObject") {
        res.status(404).json({ error: "ComplianceRegistry not found" });
        return;
      }

      const fields = reg.data.content.fields as Record<string, unknown>;
      const investorsTable = fields.investors as { fields: { id: { id: string } } } | undefined;
      const tableId = investorsTable?.fields?.id?.id;

      if (!tableId) {
        res.status(404).json({ error: "Could not resolve investors table" });
        return;
      }

      try {
        const entry = await iotaClient.getDynamicFieldObject({
          parentId: tableId,
          name: { type: "address", value: address },
        });

        if (!entry.data?.content || entry.data.content.dataType !== "moveObject") {
          res.json({ address, whitelisted: false });
          return;
        }

        const record = entry.data.content.fields as {
          accreditation_level: string;
          jurisdiction:        string;
          holding_period_end:  string;
          active:              boolean;
        };

        res.json({
          address,
          whitelisted:        record.active,
          accreditationLevel: Number(record.accreditation_level),
          jurisdiction:       record.jurisdiction,
          holdingPeriodEnd:   Number(record.holding_period_end) > 0
            ? new Date(Number(record.holding_period_end))
            : null,
          active: record.active,
        });
      } catch {
        // Dynamic field not found = investor not registered
        res.json({ address, whitelisted: false });
      }
    } catch (e) { next(e); }
  },
);

// POST /compliance/:registryId/investors
// Add a new investor to the whitelist
complianceRouter.post(
  "/:registryId/investors",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const body   = AddInvestorSchema.parse(req.body);
      const digest = await poolService.addInvestor({
        complianceRegistryId: req.params.registryId,
        ...body,
      });
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// DELETE /compliance/:registryId/investors/:address
// Soft-remove (deactivate) an investor
complianceRouter.delete(
  "/:registryId/investors/:address",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const digest = await poolService.removeInvestor(
        req.params.registryId,
        req.params.address,
      );
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// PATCH /compliance/:registryId/investors/:address/accreditation
// Update accreditation level
complianceRouter.patch(
  "/:registryId/investors/:address/accreditation",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { newLevel } = UpdateAccreditationSchema.parse(req.body);
      const digest       = await poolService.updateAccreditation(
        req.params.registryId,
        req.params.address,
        newLevel,
      );
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// GET /compliance/:registryId/transfer-check
// Check if a transfer between two addresses is allowed
complianceRouter.get(
  "/:registryId/transfer-check",
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { from, to } = z.object({
        from: z.string(),
        to:   z.string(),
      }).parse(req.query);

      // We perform two individual whitelist checks since check_transfer_allowed
      // requires a Clock object and is a Move function; we approximate it here
      // by reading both investor records directly.
      const check = async (addr: string) => {
        const reg = await iotaClient.getObject({
          id: req.params.registryId,
          options: { showContent: true },
        });
        if (reg.data?.content?.dataType !== "moveObject") return null;
        const fields     = reg.data.content.fields as Record<string, unknown>;
        const tableId    = (fields.investors as { fields: { id: { id: string } } })?.fields?.id?.id;
        if (!tableId) return null;
        try {
          const entry = await iotaClient.getDynamicFieldObject({
            parentId: tableId,
            name: { type: "address", value: addr },
          });
          if (!entry.data?.content || entry.data.content.dataType !== "moveObject") return null;
          return entry.data.content.fields as {
            active:             boolean;
            holding_period_end: string;
          };
        } catch { return null; }
      };

      const [fromRecord, toRecord] = await Promise.all([check(from), check(to)]);
      const now = Date.now();

      const issues: string[] = [];
      if (!fromRecord)                                          issues.push("Sender not whitelisted");
      else if (!fromRecord.active)                             issues.push("Sender removed from whitelist");
      else if (Number(fromRecord.holding_period_end) > now)    issues.push("Sender in holding period");
      if (!toRecord)                                            issues.push("Recipient not whitelisted");
      else if (!toRecord.active)                               issues.push("Recipient removed from whitelist");

      res.json({
        allowed: issues.length === 0,
        from,
        to,
        issues,
      });
    } catch (e) { next(e); }
  },
);
