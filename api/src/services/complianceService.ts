import { Transaction } from '@iota/iota-sdk/transactions';
import { config, Network } from '../config';
import { InvestorRecord, TransferCheckResult } from '../types';
import { getObject, executeTransaction, clockObjectId, getClient } from './iotaClient';

const MODULE = 'compliance_registry';

// ─── Read ─────────────────────────────────────────────────────────────────────

export async function getRegistryState(network?: Network) {
  const fields = await getObject(config.objects.complianceRegistry, network);
  return {
    id: config.objects.complianceRegistry,
    transferRestrictionsOn: Boolean(fields['transfer_restrictions_on']),
    defaultHoldingPeriodMs: String(fields['default_holding_period_ms']),
  };
}

export async function getInvestorRecord(
  investor: string,
  network?: Network,
): Promise<InvestorRecord | null> {
  // Fetch the dynamic field entry from the investors Table
  const client = getClient(network);
  try {
    const res = await client.getDynamicFieldObject({
      parentId: config.objects.complianceRegistry,
      name: { type: 'address', value: investor },
    });

    if (res.error || !res.data?.content) return null;
    const content = res.data.content;
    if (content.dataType !== 'moveObject') return null;

    const f = content.fields as Record<string, unknown>;
    return {
      accreditationLevel: Number(f['accreditation_level']),
      jurisdiction: String(f['jurisdiction']),
      holdingPeriodEnd: String(f['holding_period_end']),
      didObjectId: String(f['did_object_id']),
      active: Boolean(f['active']),
    };
  } catch {
    return null;
  }
}

// ─── Write ────────────────────────────────────────────────────────────────────

export async function setTransferRestrictions(
  enabled: boolean,
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::set_transfer_restrictions`,
    arguments: [
      tx.object(config.caps.complianceAdminCap),
      tx.object(config.objects.complianceRegistry),
      tx.pure.bool(enabled),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function setDefaultHoldingPeriod(
  holdingPeriodMs: bigint,
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::set_default_holding_period`,
    arguments: [
      tx.object(config.caps.complianceAdminCap),
      tx.object(config.objects.complianceRegistry),
      tx.pure.u64(holdingPeriodMs),
    ],
  });
  return executeTransaction(tx, network);
}

export async function addInvestor(
  params: {
    investor: string;
    accreditationLevel: number;
    jurisdiction: string;
    didObjectId: string;
    customHoldingMs: bigint;
  },
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::add_investor`,
    arguments: [
      tx.object(config.caps.complianceAdminCap),
      tx.object(config.objects.complianceRegistry),
      tx.pure.address(params.investor),
      tx.pure.u8(params.accreditationLevel),
      tx.pure.vector('u8', Array.from(Buffer.from(params.jurisdiction, 'utf-8'))),
      tx.pure.id(params.didObjectId),
      tx.pure.u64(params.customHoldingMs),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function removeInvestor(investor: string, network?: Network) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::remove_investor`,
    arguments: [
      tx.object(config.caps.complianceAdminCap),
      tx.object(config.objects.complianceRegistry),
      tx.pure.address(investor),
      tx.object(clockObjectId()),
    ],
  });
  return executeTransaction(tx, network);
}

export async function updateAccreditation(
  investor: string,
  newLevel: number,
  network?: Network,
) {
  const tx = new Transaction();
  tx.moveCall({
    target: `${config.packageId}::${MODULE}::update_accreditation`,
    arguments: [
      tx.object(config.caps.complianceAdminCap),
      tx.object(config.objects.complianceRegistry),
      tx.pure.address(investor),
      tx.pure.u8(newLevel),
    ],
  });
  return executeTransaction(tx, network);
}
