import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { TrancheRegistry, TrancheInfo, TrancheTypeValue } from '../types';
import { getObject, executeTransaction, clockObjectId } from './iotaClient';

const MODULE = 'tranche_factory';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getTrancheRegistry(network?: Network): Promise<TrancheRegistry> {
  const f = await getObject(config.objects.trancheRegistry, network);
  return {
    id: config.objects.trancheRegistry,
    seniorSupplyCap: String(f['senior_supply_cap']),
    mezzSupplyCap: String(f['mezz_supply_cap']),
    juniorSupplyCap: String(f['junior_supply_cap']),
    seniorMinted: String(f['senior_minted']),
    mezzMinted: String(f['mezz_minted']),
    juniorMinted: String(f['junior_minted']),
    mintingEnabled: Boolean(f['minting_enabled']),
    tranchesCreated: Boolean(f['tranches_created']),
    issuanceContract: String(f['issuance_contract']),
    bootstrapped: Boolean(f['bootstrapped']),
  };
}

export async function getTrancheInfo(
  trancheType: TrancheTypeValue,
  network?: Network,
): Promise<TrancheInfo> {
  const reg = await getTrancheRegistry(network);

  const caps: Record<TrancheTypeValue, { cap: string; minted: string }> = {
    0: { cap: reg.seniorSupplyCap, minted: reg.seniorMinted },
    1: { cap: reg.mezzSupplyCap, minted: reg.mezzMinted },
    2: { cap: reg.juniorSupplyCap, minted: reg.juniorMinted },
  };

  const { cap, minted } = caps[trancheType];
  const remaining = (BigInt(cap) - BigInt(minted)).toString();

  return {
    trancheType,
    supplyCap: cap,
    amountMinted: minted,
    remainingCapacity: remaining,
    mintingActive: reg.mintingEnabled,
  };
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function bootstrap(
  params: {
    seniorTreasuryId: string;
    mezzTreasuryId: string;
    juniorTreasuryId: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::bootstrap`,
    arguments: [
      tx.object(config.caps.trancheAdminCap),
      tx.object(config.objects.trancheRegistry),
      tx.object(params.seniorTreasuryId ?? config.objects.seniorTreasury),
      tx.object(params.mezzTreasuryId ?? config.objects.mezzTreasury),
      tx.object(params.juniorTreasuryId ?? config.objects.juniorTreasury),
    ],
  });
  return executeTransaction(tx, network);
}

export async function createTranches(
  params: {
    seniorCap: bigint;
    mezzCap: bigint;
    juniorCap: bigint;
    issuanceContract: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::create_tranches`,
    arguments: [
      tx.object(config.caps.trancheAdminCap),
      tx.object(config.objects.trancheRegistry),
      tx.pure.u64(params.seniorCap),
      tx.pure.u64(params.mezzCap),
      tx.pure.u64(params.juniorCap),
      tx.pure.address(params.issuanceContract),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function disableMinting(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::disable_minting`,
    arguments: [
      tx.object(config.caps.trancheAdminCap),
      tx.object(config.objects.trancheRegistry),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function meltSenior(coinObjectId: string, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::melt_senior`,
    arguments: [
      tx.object(config.objects.trancheRegistry),
      tx.object(coinObjectId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function meltMezz(coinObjectId: string, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::melt_mezz`,
    arguments: [
      tx.object(config.objects.trancheRegistry),
      tx.object(coinObjectId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function meltJunior(coinObjectId: string, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::melt_junior`,
    arguments: [
      tx.object(config.objects.trancheRegistry),
      tx.object(coinObjectId),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}
