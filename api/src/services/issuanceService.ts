import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { IssuanceState } from '../types';
import { getObject, executeTransaction, clockObjectId } from './iotaClient';

const MODULE = 'issuance_contract';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getIssuanceState(
  issuanceStateId: string,
  network?: Network,
): Promise<IssuanceState> {
  const f = await getObject(issuanceStateId, network);

  const vaultRaw = f['vault_balance'] as Record<string, unknown> | undefined;
  const vaultValue = vaultRaw?.['value'] ?? vaultRaw ?? '0';

  return {
    id: issuanceStateId,
    pricePerUnitSenior: String(f['price_per_unit_senior']),
    pricePerUnitMezz: String(f['price_per_unit_mezz']),
    pricePerUnitJunior: String(f['price_per_unit_junior']),
    saleStart: String(f['sale_start']),
    saleEnd: String(f['sale_end']),
    totalRaised: String(f['total_raised']),
    issuanceActive: Boolean(f['issuance_active']),
    issuanceEnded: Boolean(f['issuance_ended']),
    succeeded: Boolean(f['succeeded']),
    vaultBalance: String(vaultValue),
  };
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function createIssuanceState(
  coinType: string,
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::create_issuance_state`,
    typeArguments: [coinType],
    arguments: [tx.object(config.caps.issuanceOwnerCap)],
  });
  return executeTransaction(tx, network);
}

export async function startIssuance(
  params: {
    issuanceStateId: string;
    coinType: string;
    saleStart: bigint;
    saleEnd: bigint;
    priceSenior: bigint;
    priceMezz: bigint;
    priceJunior: bigint;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::start_issuance`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.issuanceOwnerCap),
      tx.object(params.issuanceStateId),
      tx.object(config.objects.poolState),
      tx.pure.u64(params.saleStart),
      tx.pure.u64(params.saleEnd),
      tx.pure.u64(params.priceSenior),
      tx.pure.u64(params.priceMezz),
      tx.pure.u64(params.priceJunior),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function endIssuance(
  params: {
    issuanceStateId: string;
    coinType: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::end_issuance`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.issuanceOwnerCap),
      tx.object(params.issuanceStateId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function invest(
  params: {
    issuanceStateId: string;
    coinType: string;
    trancheType: number;
    paymentCoinId: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::invest`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(params.issuanceStateId),
      tx.object(config.objects.trancheRegistry),
      tx.object(config.objects.complianceRegistry),
      tx.object(config.caps.issuanceAdminCap),
      tx.pure.u8(params.trancheType),
      tx.object(params.paymentCoinId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function refund(
  params: {
    issuanceStateId: string;
    coinType: string;
    investor: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::refund`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(params.issuanceStateId),
      tx.pure.address(params.investor),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function releaseFundsToVault(
  params: {
    issuanceStateId: string;
    coinType: string;
    vaultAddress: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::release_funds_to_vault`,
    typeArguments: [params.coinType],
    arguments: [
      tx.object(config.caps.issuanceOwnerCap),
      tx.object(params.issuanceStateId),
      tx.pure.address(params.vaultAddress),
    ],
  });
  return executeTransaction(tx, network);
}
