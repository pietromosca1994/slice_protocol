import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { WaterfallState } from '../types';
import { getObject, executeTransaction, clockObjectId } from './iotaClient';

const MODULE = 'waterfall_engine';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getWaterfallState(network?: Network): Promise<WaterfallState> {
  const f = await getObject(config.objects.waterfallState, network);
  return {
    id: config.objects.waterfallState,
    seniorOutstanding: String(f['senior_outstanding']),
    mezzOutstanding: String(f['mezz_outstanding']),
    juniorOutstanding: String(f['junior_outstanding']),
    seniorAccruedInterest: String(f['senior_accrued_interest']),
    mezzAccruedInterest: String(f['mezz_accrued_interest']),
    juniorAccruedInterest: String(f['junior_accrued_interest']),
    seniorRateBps: Number(f['senior_rate_bps']),
    mezzRateBps: Number(f['mezz_rate_bps']),
    juniorRateBps: Number(f['junior_rate_bps']),
    reserveAccount: String(f['reserve_account']),
    pendingFunds: String(f['pending_funds']),
    lastDistributionMs: String(f['last_distribution_ms']),
    paymentFrequency: Number(f['payment_frequency']),
    waterfallStatus: Number(f['waterfall_status']),
  };
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function initialiseWaterfall(
  params: {
    seniorOutstanding: bigint;
    mezzOutstanding: bigint;
    juniorOutstanding: bigint;
    seniorRateBps: number;
    mezzRateBps: number;
    juniorRateBps: number;
    paymentFrequency: number;
    poolContractAddr: string;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::initialise_waterfall`,
    arguments: [
      tx.object(config.caps.waterfallAdminCap),
      tx.object(config.objects.waterfallState),
      tx.pure.u64(params.seniorOutstanding),
      tx.pure.u64(params.mezzOutstanding),
      tx.pure.u64(params.juniorOutstanding),
      tx.pure.u32(params.seniorRateBps),
      tx.pure.u32(params.mezzRateBps),
      tx.pure.u32(params.juniorRateBps),
      tx.pure.u8(params.paymentFrequency),
      tx.pure.address(params.poolContractAddr),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function accrueInterest(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::accrue_interest`,
    arguments: [
      tx.object(config.objects.waterfallState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function depositPayment(amount: bigint, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::deposit_payment`,
    arguments: [
      tx.object(config.objects.waterfallState),
      tx.pure.u64(amount),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function runWaterfall(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::run_waterfall`,
    arguments: [
      tx.object(config.objects.waterfallState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function triggerTurboMode(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::trigger_turbo_mode`,
    arguments: [
      tx.object(config.caps.waterfallAdminCap),
      tx.object(config.objects.waterfallState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function triggerDefaultModeAdmin(network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::trigger_default_mode_admin`,
    arguments: [
      tx.object(config.caps.waterfallAdminCap),
      tx.object(config.objects.waterfallState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function triggerDefaultModePool(
  poolCapId: string,
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::trigger_default_mode_pool`,
    arguments: [
      tx.object(poolCapId),
      tx.object(config.objects.waterfallState),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}
