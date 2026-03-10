import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { VaultBalance } from '../types';
import { getObject, executeTransaction, clockObjectId } from './iotaClient';

const MODULE = 'payment_vault';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getVaultBalance(
  vaultId: string,
  network?: Network,
): Promise<VaultBalance> {
  const f = await getObject(vaultId, network);

  const balRaw = f['balance'] as Record<string, unknown> | undefined;
  const balValue = balRaw?.['value'] ?? balRaw ?? '0';

  return {
    id: vaultId,
    balance: String(balValue),
    totalDeposited: String(f['total_deposited']),
    totalDistributed: String(f['total_distributed']),
  };
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function createVault(coinType: string, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::create_vault`,
    typeArguments: [coinType],
    arguments: [tx.object(config.caps.vaultAdminCap)],
  });
  return executeTransaction(tx, network);
}

export async function authoriseDepositor(
  params: {
    vaultId: string;
    coinType: string;
    depositor: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::authorise_depositor`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.vaultAdminCap),
      tx.object(params.vaultId),
      tx.pure.address(params.depositor),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function revokeDepositor(
  params: {
    vaultId: string;
    coinType: string;
    depositor: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::revoke_depositor`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.vaultAdminCap),
      tx.object(params.vaultId),
      tx.pure.address(params.depositor),
    ],
  });
  return executeTransaction(tx, network);
}

export async function depositToVault(
  params: {
    vaultId: string;
    coinType: string;
    coinObjectId: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::deposit`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(params.vaultId),
      tx.object(params.coinObjectId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function releaseFunds(
  params: {
    vaultId: string;
    coinType: string;
    recipient: string;
    amount: bigint;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::release_funds`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.vaultAdminCap),
      tx.object(params.vaultId),
      tx.pure.address(params.recipient),
      tx.pure.u64(params.amount),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}
