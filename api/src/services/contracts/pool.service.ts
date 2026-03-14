/**
 * PoolService
 *
 * Wraps all write (PTB) operations for pool_contract and the downstream
 * securitization contracts. Read operations are handled by RegistryService.
 */
import { TransactionBlock } from "@iota/iota-sdk/transactions";
import { config } from "../../config";
import { signAndExecute, getKeypair } from "../iota-client";
import { ApiError } from "../../utils/errors";

function requireSigner() {
  if (config.readOnly) throw ApiError.readOnly();
  return getKeypair();
}

// ── Pool lifecycle ─────────────────────────────────────────────────────────────

export interface CreatePoolParams {
  spv:             string;
  poolId:          string;   // UTF-8 string, will be encoded as vector<u8>
  originator:      string;
  totalPoolValue:  bigint;
  interestRate:    number;   // basis points
  maturityDate:    number;   // UNIX ms timestamp
  assetHash:       string;   // hex string of SHA-256
  oracleAddress:   string;
}

export async function createPool(params: CreatePoolParams): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  const adminCap = txb.object(await _resolveAdminCap());

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::create_pool`,
    arguments: [
      adminCap,
      txb.object(config.spvRegistryId),
      txb.pure(params.spv,            "address"),
      txb.pure(Buffer.from(params.poolId), "vector<u8>"),
      txb.pure(params.originator,     "address"),
      txb.pure(params.totalPoolValue, "u64"),
      txb.pure(params.interestRate,   "u32"),
      txb.pure(params.maturityDate,   "u64"),
      txb.pure(Buffer.from(params.assetHash.replace(/^0x/,""), "hex"), "vector<u8>"),
      txb.pure(params.oracleAddress,  "address"),
      txb.object("0x6"), // Clock
    ],
  });

  return signAndExecute(txb);
}

export interface SetContractsParams {
  poolStateId:      string;
  trancheFactory:   string;
  issuanceContract: string;
  waterfallEngine:  string;
  oracleAddress:    string;
}

export async function setContracts(params: SetContractsParams): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::set_contracts`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(params.poolStateId),
      txb.pure(params.trancheFactory,   "address"),
      txb.pure(params.issuanceContract, "address"),
      txb.pure(params.waterfallEngine,  "address"),
      txb.pure(params.oracleAddress,    "address"),
    ],
  });

  return signAndExecute(txb);
}

export interface SetContractObjectsParams {
  poolStateId:         string;
  trancheFactoryObj:   string;
  issuanceContractObj: string;
  waterfallEngineObj:  string;
}

export async function setContractObjects(params: SetContractObjectsParams): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::set_contract_objects`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(params.poolStateId),
      txb.pure(params.trancheFactoryObj,   "address"),
      txb.pure(params.issuanceContractObj, "address"),
      txb.pure(params.waterfallEngineObj,  "address"),
    ],
  });

  return signAndExecute(txb);
}
export async function initialisePool(poolStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::initialise_pool`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function activatePool(poolStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::activate_pool`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function markDefaultAdmin(poolStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::mark_default_admin`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function closePool(poolStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::pool_contract::close_pool`,
    arguments: [
      txb.object(await _resolveAdminCap()),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

// ── Issuance lifecycle ─────────────────────────────────────────────────────────

export interface StartIssuanceParams {
  issuanceStateId: string;
  poolStateId:     string;
  saleStart:       number;
  saleEnd:         number;
  priceSenior:     bigint;
  priceMezz:       bigint;
  priceJunior:     bigint;
}

export async function startIssuance(params: StartIssuanceParams): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::issuance_contract::start_issuance`,
    typeArguments: [], // C type arg resolved at call time — caller must supply stablecoin type
    arguments: [
      txb.object(await _resolveIssuanceOwnerCap()),
      txb.object(params.issuanceStateId),
      txb.object(params.poolStateId),
      txb.pure(params.saleStart,   "u64"),
      txb.pure(params.saleEnd,     "u64"),
      txb.pure(params.priceSenior, "u64"),
      txb.pure(params.priceMezz,   "u64"),
      txb.pure(params.priceJunior, "u64"),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function endIssuance(issuanceStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::issuance_contract::end_issuance`,
    arguments: [
      txb.object(await _resolveIssuanceOwnerCap()),
      txb.object(issuanceStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

// ── Waterfall ──────────────────────────────────────────────────────────────────

export async function runWaterfall(waterfallStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::waterfall_engine::run_waterfall`,
    arguments: [
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function triggerTurboMode(waterfallStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::waterfall_engine::trigger_turbo_mode`,
    arguments: [
      txb.object(await _resolveWaterfallAdminCap()),
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function triggerDefaultMode(waterfallStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::waterfall_engine::trigger_default_mode_admin`,
    arguments: [
      txb.object(await _resolveWaterfallAdminCap()),
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

// ── Compliance (spv package) ───────────────────────────────────────────────────

export interface AddInvestorParams {
  complianceRegistryId: string;
  investor:             string;
  accreditationLevel:   number;
  jurisdiction:         string;   // ISO-3166-1 alpha-2, e.g. "US"
  didObjectId:          string;
  customHoldingMs:      number;
}

export async function addInvestor(params: AddInvestorParams): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::add_investor`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(params.complianceRegistryId),
      txb.pure(params.investor,           "address"),
      txb.pure(params.accreditationLevel, "u8"),
      txb.pure(Buffer.from(params.jurisdiction), "vector<u8>"),
      txb.pure(params.didObjectId,        "address"),
      txb.pure(params.customHoldingMs,    "u64"),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function removeInvestor(
  complianceRegistryId: string,
  investor: string,
): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::remove_investor`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(complianceRegistryId),
      txb.pure(investor, "address"),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function updateAccreditation(
  complianceRegistryId: string,
  investor:             string,
  newLevel:             number,
): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::update_accreditation`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(complianceRegistryId),
      txb.pure(investor,  "address"),
      txb.pure(newLevel,  "u8"),
    ],
  });

  return signAndExecute(txb);
}

export async function depositPayment(
  waterfallStateId: string,
  amount:           bigint,
): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::waterfall_engine::deposit_payment`,
    arguments: [
      txb.object(waterfallStateId),
      txb.pure(amount, "u64"),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

export async function accrueInterest(waterfallStateId: string): Promise<string> {
  requireSigner();
  const txb = new TransactionBlock();

  txb.moveCall({
    target: `${config.securitizationPackageId}::waterfall_engine::accrue_interest`,
    arguments: [
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  return signAndExecute(txb);
}

// ── Cap resolution helpers ─────────────────────────────────────────────────────
// Caps are owned objects in the signer's wallet — we find them by type.

async function _resolveCap(type: string): Promise<string> {
  const kp     = getKeypair();
  const owner  = kp.getPublicKey().toIotaAddress();
  const objects = await _getOwnedObjectsOfType(owner, type);
  if (objects.length === 0) {
    throw ApiError.internal(`No capability of type ${type} found in signer wallet`);
  }
  return objects[0];
}

async function _getOwnedObjectsOfType(owner: string, type: string): Promise<string[]> {
  const { data } = await import("../iota-client").then(m => m.iotaClient).then(client =>
    client.getOwnedObjects({
      owner,
      filter:  { StructType: type },
      options: { showType: true },
    })
  );
  return (data ?? []).map(o => o.data?.objectId).filter((id): id is string => !!id);
}

async function _resolveAdminCap(): Promise<string> {
  return _resolveCap(`${config.securitizationPackageId}::pool_contract::AdminCap`);
}

async function _resolveIssuanceOwnerCap(): Promise<string> {
  return _resolveCap(`${config.securitizationPackageId}::issuance_contract::IssuanceOwnerCap`);
}

async function _resolveWaterfallAdminCap(): Promise<string> {
  return _resolveCap(`${config.securitizationPackageId}::waterfall_engine::WaterfallAdminCap`);
}

async function _resolveComplianceAdminCap(): Promise<string> {
  return _resolveCap(`${config.spvPackageId}::compliance_registry::ComplianceAdminCap`);
}
