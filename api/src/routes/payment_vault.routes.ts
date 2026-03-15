import { Router, Request, Response, NextFunction } from "express";
import { z } from "zod";
import { requireWriteAccess } from "../middleware/readOnly";
import { iotaClient } from "../services/iota-client";
import { config } from "../config";
import { signAndExecute, getKeypair } from "../services/iota-client";
import { Transaction } from "@iota/iota-sdk/transactions";
import { ApiError } from "../utils/errors";

export const paymentVaultRouter = Router();

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
paymentVaultRouter.get("/:vaultId", async (req: Request, res: Response, next: NextFunction) => {
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
paymentVaultRouter.post(
  "/create",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { coinType } = z.object({ coinType: z.string().min(1) }).parse(req.body);
      const txb          = new Transaction();

      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::create_vault`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
        ],
      });

      const { digest } = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// POST /vault/:vaultId/authorise-depositor
// Grant deposit rights to an address
paymentVaultRouter.post(
  "/:vaultId/authorise-depositor",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { depositor, coinType } = z.object({
        depositor: z.string(),
        coinType:  z.string(),
      }).parse(req.body);

      const txb = new Transaction();
      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::authorise_depositor`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure.address(depositor),
          txb.object("0x6"),
        ],
      });

      const { digest } = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// DELETE /vault/:vaultId/depositor/:depositor
// Revoke deposit rights
paymentVaultRouter.delete(
  "/:vaultId/depositor/:depositor",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { coinType } = z.object({ coinType: z.string() }).parse(req.body);
      const txb          = new Transaction();

      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::revoke_depositor`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure.address(req.params.depositor),
        ],
      });

      const { digest } = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);

// POST /vault/:vaultId/release
// Release funds to a recipient (admin only)
paymentVaultRouter.post(
  "/:vaultId/release",
  requireWriteAccess,
  async (req: Request, res: Response, next: NextFunction) => {
    try {
      const { recipient, amount, coinType } = z.object({
        recipient: z.string(),
        amount:    z.string().transform(BigInt),
        coinType:  z.string(),
      }).parse(req.body);

      const txb = new Transaction();
      txb.moveCall({
        target:        `${config.spvPackageId}::payment_vault::release_funds`,
        typeArguments: [coinType],
        arguments: [
          txb.object(await resolveVaultAdminCap()),
          txb.object(req.params.vaultId),
          txb.pure.address(recipient),
          txb.pure.u64(amount),
          txb.object("0x6"),
        ],
      });

      const { digest } = await signAndExecute(txb);
      res.status(202).json({ digest });
    } catch (e) { next(e); }
  },
);
