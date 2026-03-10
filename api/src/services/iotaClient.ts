import { IotaClient, getFullnodeUrl } from '@iota/iota-sdk/client';
import { Ed25519Keypair } from '@iota/iota-sdk/keypairs/ed25519';
import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { logger } from '../config/logger';
import { TxResult } from '../types';
import { decodeIotaPrivateKey } from '@iota/iota-sdk/cryptography';

// ─── Client cache (one per network) ─────────────────────────────────────────

const clientCache = new Map<Network, IotaClient>();

export function getClient(network?: Network): IotaClient {
  const net = network ?? config.network;
  if (!clientCache.has(net)) {
    const rpcUrl = config.rpcUrl(net);
    logger.info(`Creating IotaClient for ${net} at ${rpcUrl}`);
    clientCache.set(net, new IotaClient({ url: rpcUrl }));
  }
  return clientCache.get(net)!;
}

// ─── Signer ───────────────────────────────────────────────────────────────────

let _keypair: Ed25519Keypair | null = null;

export function getSigner(): Ed25519Keypair {
  if (!_keypair) {
    const pk = config.signerPrivateKey;
    if (!pk || pk === 'iotaprivkey1qpYOUR_BECH32_KEY_HERE') {
      throw new Error('SIGNER_PRIVATE_KEY not configured');
    }

    // Branch 1 — Bech32 (iotaprivkey1...)
    // Must be decoded first: the string encodes 33 bytes (1-byte scheme flag + 32-byte key)
    // Passing the raw string directly to fromSecretKey gives 71 chars, not 32 bytes → error
    if (pk.startsWith('iotaprivkey1') || pk.startsWith('suiprivkey1')) {
      const { secretKey } = decodeIotaPrivateKey(pk);
      _keypair = Ed25519Keypair.fromSecretKey(secretKey);

    // Branch 2 — Hex (0xaabb... or aabb... — exactly 64 hex chars = 32 bytes)
    } else if (pk.startsWith('0x') || /^[0-9a-fA-F]{64}$/.test(pk)) {
      const hex = pk.startsWith('0x') ? pk.slice(2) : pk;
      if (hex.length !== 64) {
        throw new Error(
          `Hex private key must be 32 bytes (64 hex chars). Got ${hex.length / 2} bytes.`
        );
      }
      _keypair = Ed25519Keypair.fromSecretKey(Buffer.from(hex, 'hex'));

    // Branch 3 — Base64 (some exporters prepend a 1-byte key-type flag, strip it)
    } else {
      const bytes = Buffer.from(pk, 'base64');
      const secret = bytes.length === 33 ? bytes.subarray(1) : bytes;
      if (secret.length !== 32) {
        throw new Error(
          `Could not parse SIGNER_PRIVATE_KEY. Expected a Bech32 key (iotaprivkey1…), ` +
          `a 64-char hex string, or a base64-encoded 32-byte secret. Got ${secret.length} bytes.`
        );
      }
      _keypair = Ed25519Keypair.fromSecretKey(secret);
    }

    logger.info(`Signer address: ${_keypair.toIotaAddress()}`);
  }
  return _keypair;
}

// ─── Execute a PTB transaction ────────────────────────────────────────────────

export async function executeTransaction(
  tx: Transaction,
  network?: Network,
): Promise<TxResult> {
  const client = getClient(network);
  const signer = getSigner();

  tx.setSenderIfNotSet(signer.toIotaAddress());

  const result = await client.signAndExecuteTransaction({
    transaction: tx,
    signer,
    options: {
      showEffects: true,
      showEvents: true,
    },
  });

  const status = result.effects?.status?.status === 'success' ? 'success' : 'failure';

  if (status === 'failure') {
    const err = result.effects?.status?.error ?? 'Unknown error';
    throw new Error(`Transaction failed: ${err}`);
  }

  return {
    txDigest: result.digest,
    status,
    gasUsed: result.effects?.gasUsed
      ? JSON.stringify(result.effects.gasUsed)
      : undefined,
    effects: result.effects,
  };
}

// ─── Read shared object fields ────────────────────────────────────────────────

export async function getObject(
  objectId: string,
  network?: Network,
): Promise<Record<string, unknown>> {
  const client = getClient(network);
  const res = await client.getObject({
    id: objectId,
    options: { showContent: true },
  });

  if (res.error) throw new Error(`Object not found: ${objectId} — ${res.error.code}`);

  const content = res.data?.content;
  if (!content || content.dataType !== 'moveObject') {
    throw new Error(`Object ${objectId} is not a Move object`);
  }

  return (content.fields as Record<string, unknown>) ?? {};
}

// ─── Convenience: get clock object id ────────────────────────────────────────

export function clockObjectId(): string {
  return config.objects.clock;
}
