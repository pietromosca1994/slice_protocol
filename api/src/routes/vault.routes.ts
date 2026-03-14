import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { iotaClient } from "../services/iota-client";
import { config } from "../config";
import { signAndExecute, getKeypair } from "../services/iota-client";
import { TransactionBlock } from "@iota/iota-sdk/transactions";
import { ApiError } from "../utils/errors";

export const vaultRouter = Router();

// ── Helpers ────────────────────────────────────────────────────────────────────

async function fetchVaultState(vaultId: string) {
  const res = await iotaClient.getObject({
    id: vaultId,
    options: { showContent: true, showType: true },
  });
  if (!res.data?.content || res.data.content.dataType !== "moveObject") {
    throw ApiError.notFound(`VaultBalance ${vaultId} not found`);
  }
  const fields = res.data.content.fields as {
    balance:           { fields: { value: string } };
    total_deposited:   string;
    total_distributed: string;
  };
  return {
    balance:          BigInt(fields.balance?.fields?.value ?? "0"),
    totalDeposited:   BigInt(fields.total_deposited),
    totalDistributed: BigInt(fields.total_distributed),
  };
}

async function resolveVaultAdminCap(): Promise<string> {
  const kp    = getKeypair();
  const owner = kp.getPublicKey().toIotaAddress();
  const type  = `${config.spvPackageId}::payment_vault::VaultAdminCap`;
  const { data } = await iotaClient.getOwnedObjects({
    owner,
    filter:  { StructType: type },
    options: { showType: true },
  });
  const id = data?.[0]?.data?.objectId;
  if (!id) throw ApiError.internal("VaultAdminCap not found in signer wallet");
  return id;
}

// ── Routes ─────────────────────────────────────────────────────────────────────

// GET /vault/:vaultId
// Returns current vault balance and accounting totals
vaultRouter.get("/:vaultId", async (req: Request, res: Response, next: NextFunction) => {
  try {
    const state = await fetchVaultState(req.params.vaultId);
    // Serialise BigInt as string for JSON
    res.json({
      vaultId:          req.params.vaultId,
      balance:          state.balance.toString(),
      totalDeposited:   state.totalDeposited.toString(),
      totalDistributed: state.totalDistributed.toString(),
    });
  } catch (e) { next(e); }
});

// POST /vault/create
// Create and share a new VaultBalance for a given stablecoin type
vaultRouter.post(
  "/create",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { coinType } = z.object({ coinType: z.string().min(1) }).parse(req.body);
      const txb          = new TransactionBlock();

      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::create_vault`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
        ],
      });

      const digest = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// POST /vault/:vaultId/authorise-depositor
// Grant deposit rights to an address
vaultRouter.post(
  "/:vaultId/authorise-depositor",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { depositor, coinType } = z.object({
        depositor: z.string(),
        coinType:  z.string(),
      }).parse(req.body);

      const txb = new TransactionBlock();
      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::authorise_depositor`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure(depositor, "address"),
          txb.object("0x6"),
        ],
      });

      const digest = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// DELETE /vault/:vaultId/depositor/:depositor
// Revoke deposit rights
vaultRouter.delete(
  "/:vaultId/depositor/:depositor",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { coinType } = z.object({ coinType: z.string() }).parse(req.body);
      const txb          = new TransactionBlock();

      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::revoke_depositor`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure(req.params.depositor, "address"),
        ],
      });

      const digest = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// POST /vault/:vaultId/release
// Release funds to a recipient (admin only)
vaultRouter.post(
  "/:vaultId/release",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { recipient, amount, coinType } = z.object({
        recipient: z.string(),
        amount:    z.string().transform(BigInt),
        coinType:  z.string(),
      }).parse(req.body);

      const txb = new TransactionBlock();
      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::release_funds`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure(recipient, "address"),
          txb.pure(amount,    "u64"),
          txb.object("0x6"),
        ],
      });

      const digest = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);
