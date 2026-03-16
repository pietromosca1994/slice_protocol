import { IotaClient } from "@iota/iota-sdk/client";
import { decodeIotaPrivateKey } from "@iota/iota-sdk/cryptography";
import { Ed25519Keypair } from "@iota/iota-sdk/keypairs/ed25519";
import { Transaction } from "@iota/iota-sdk/transactions";
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
  const { secretKey } = decodeIotaPrivateKey(config.adminSecretKey);
  _keypair = Ed25519Keypair.fromSecretKey(secretKey);
  logger.info({ address: _keypair.getPublicKey().toIotaAddress() }, "Signer loaded");
  return _keypair;
}

// ── Transaction helper ────────────────────────────────────────────────────────

export async function signAndExecute(
  txb: Transaction,
  gasBudget?: number | null,
): Promise<{ digest: string; objectChanges: any[] }> {
  const kp = getKeypair();
  // null = let the SDK auto-estimate via devInspect (e.g. for package publish)
  if (gasBudget !== null) {
    txb.setGasBudget(gasBudget ?? config.gasBudget);
  }

  const result = await iotaClient.signAndExecuteTransaction({
    signer: kp,
    transaction: txb,
    options: { showEffects: true, showObjectChanges: true },
  });

  if (result.effects?.status.status !== "success") {
    throw new Error(`Transaction failed: ${result.effects?.status.error ?? "unknown"}`);
  }
  return { digest: result.digest, objectChanges: result.objectChanges ?? [] };
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

// Fetches object fields AND its full objectType string (e.g. "0x<pkgId>::module::Type").
export async function fetchObjectWithType<T = Record<string, unknown>>(
  objectId: string,
): Promise<{ fields: T; objectType: string }> {
  const res = await iotaClient.getObject({
    id: objectId,
    options: { showContent: true, showType: true },
  });
  if (!res.data?.content || res.data.content.dataType !== "moveObject") {
    throw new Error(`Object ${objectId} not found or not a Move object`);
  }
  const objectType = (res.data.content as any).type ?? res.data.type ?? "";
  return { fields: res.data.content.fields as T, objectType };
}
