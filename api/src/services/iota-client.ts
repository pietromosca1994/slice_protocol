import { IotaClient, getFullnodeUrl } from "@iota/iota-sdk/client";
import { Ed25519Keypair } from "@iota/iota-sdk/keypairs/ed25519";
import { TransactionBlock } from "@iota/iota-sdk/transactions";
import { config } from "../config";
import { logger } from "../utils/logger";

// ── Singleton client ──────────────────────────────────────────────────────────

export const iotaClient = new IotaClient({ url: config.rpcUrl });

// ── Signer (only present when ADMIN_SECRET_KEY is set) ───────────────────────

let _keypair: Ed25519Keypair | null = null;

export function getKeypair(): Ed25519Keypair {
  if (_keypair) return _keypair;
  if (!config.adminSecretKey) {
    throw new Error("No ADMIN_SECRET_KEY configured — API is read-only");
  }
  _keypair = Ed25519Keypair.fromSecretKey(
    Buffer.from(config.adminSecretKey, "base64"),
  );
  logger.info({ address: _keypair.getPublicKey().toIotaAddress() }, "Signer loaded");
  return _keypair;
}

// ── Transaction helper ────────────────────────────────────────────────────────

export async function signAndExecute(txb: TransactionBlock): Promise<string> {
  const kp = getKeypair();
  txb.setGasBudget(config.gasBudget);

  const result = await iotaClient.signAndExecuteTransactionBlock({
    signer: kp,
    transactionBlock: txb,
    options: { showEffects: true, showObjectChanges: true },
  });

  if (result.effects?.status.status !== "success") {
    throw new Error(`Transaction failed: ${result.effects?.status.error ?? "unknown"}`);
  }
  return result.digest;
}

// ── Generic object fetcher ────────────────────────────────────────────────────

export async function fetchObject<T = Record<string, unknown>>(
  objectId: string,
): Promise<T> {
  const res = await iotaClient.getObject({
    id: objectId,
    options: { showContent: true, showType: true },
  });
  if (!res.data?.content || res.data.content.dataType !== "moveObject") {
    throw new Error(`Object ${objectId} not found or not a Move object`);
  }
  return res.data.content.fields as T;
}
