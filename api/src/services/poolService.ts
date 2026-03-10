import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { PoolState } from '../types';
import { getObject, executeTransaction, clockObjectId } from './iotaClient';

const MODULE = 'pool_contract';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getPoolState(network?: Network): Promise<PoolState> {
  const fields = await getObject(config.objects.poolState, network);

  return {
    id: config.objects.poolState,
    poolId: bufToString(fields['pool_id']),
    originator: fields['originator'] as string,
    spv: fields['spv'] as string,
    totalPoolValue: String(fields['total_pool_value']),
    currentOutstandingPrincipal: String(fields['current_outstanding_principal']),
    interestRate: Number(fields['interest_rate']),
    maturityDate: String(fields['maturity_date']),
    assetHash: bufToString(fields['asset_hash']),
    poolStatus: Number(fields['pool_status']) as PoolState['poolStatus'],
    oracleAddress: fields['oracle_address'] as string,
    trancheFactory: fields['tranche_factory'] as string,
    issuanceContract: fields['issuance_contract'] as string,
    waterfallEngine: fields['waterfall_engine'] as string,
    initialised: Boolean(fields['initialised']),
  };
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function setContracts(
  params: {
    trancheFactory: string;
    issuanceContract: string;
    waterfallEngine: string;
    oracleAddress: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::set_contracts`,
    arguments: [
      tx.object(config.caps.adminCap),
      tx.object(config.objects.poolState),
      tx.pure.address(params.trancheFactory),
      tx.pure.address(params.issuanceContract),
      tx.pure.address(params.waterfallEngine),
      tx.pure.address(params.oracleAddress),
    ],
  });
  return executeTransaction(tx, network);
}

export async function initialisePool(
  params: {
    poolId: string;
    originator: string;
    spv: string;
    totalPoolValue: bigint;
    interestRate: number;
    maturityDate: bigint;
    assetHash: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::initialise_pool`,
    arguments: [
      tx.object(config.caps.adminCap),
      tx.object(config.objects.poolState),
      tx.pure.vector('u8', Array.from(Buffer.from(params.poolId, 'utf-8'))),
      tx.pure.address(params.originator),
      tx.pure.address(params.spv),
      tx.pure.u64(params.totalPoolValue),
      tx.pure.u32(params.interestRate),
      tx.pure.u64(params.maturityDate),
      tx.pure.vector('u8', Array.from(Buffer.from(params.assetHash, 'hex'))),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function activatePool(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::activate_pool`,
    arguments: [
      tx.object(config.caps.adminCap),
      tx.object(config.objects.poolState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function updatePerformanceData(
  params: {
    newOutstandingPrincipal: bigint;
    oracleTimestamp: bigint;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::update_performance_data`,
    arguments: [
      tx.object(config.caps.oracleCap),
      tx.object(config.objects.poolState),
      tx.pure.u64(params.newOutstandingPrincipal),
      tx.pure.u64(params.oracleTimestamp),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function markDefaultOracle(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::mark_default_oracle`,
    arguments: [
      tx.object(config.caps.oracleCap),
      tx.object(config.objects.poolState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function markDefaultAdmin(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::mark_default_admin`,
    arguments: [
      tx.object(config.caps.adminCap),
      tx.object(config.objects.poolState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function closePool(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::close_pool`,
    arguments: [
      tx.object(config.caps.adminCap),
      tx.object(config.objects.poolState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

// ─── Helper ───────────────────────────────────────────────────────────────────

function bufToString(val: unknown): string {
  if (!val) return '';
  if (typeof val === 'string') return val;
  if (Array.isArray(val)) return Buffer.from(val).toString('hex');
  return String(val);
}
