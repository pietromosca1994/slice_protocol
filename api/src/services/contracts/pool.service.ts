/**
 * PoolService
 *
 * Wraps all write (PTB) operations for pool_contract and the downstream
 * securitization contracts. Read operations are handled by RegistryService.
 *
 * Every function that calls a securitization contract now accepts
 * `securitizationPackageId` explicitly, since each pool has its own
 * freshly-deployed securitization package.
 */
import { Transaction } from "@iota/iota-sdk/transactions";
import { config } from "../../config";
import { signAndExecute, getKeypair, iotaClient, fetchObjectWithType } from "../iota-client";
import { ApiError } from "../../utils/errors";
import { extractObjectId } from "./deploy.service";

function requireSigner() {
  if (config.readOnly) throw ApiError.readOnly();
  return getKeypair();
}

// ── Pool lifecycle ─────────────────────────────────────────────────────────────

export interface CreatePoolParams {
  spv:                       string;
  poolId:                    string;   // UTF-8 string, will be encoded as vector<u8>
  originator:                string;
  totalPoolValue:            bigint;
  interestRate:              number;   // basis points
  maturityDate:              number;   // UNIX ms timestamp
  assetHash:                 string;   // hex string of SHA-256
  oracleAddress:             string;
  securitizationPackageId:   string;  // package ID of the per-pool securitization deployment
}

export async function createPool(
  params: CreatePoolParams,
): Promise<{ digest: string; objectChanges: any[] }> {
  requireSigner();
  const txb = new Transaction();

  const adminCap = txb.object(await _resolveAdminCap(params.securitizationPackageId));

  txb.moveCall({
    target: `${params.securitizationPackageId}::pool_contract::create_pool`,
    arguments: [
      adminCap,
      txb.object(config.spvRegistryId),
      txb.pure.address(params.spv),
      txb.pure.vector("u8", Array.from(Buffer.from(params.poolId))),
      txb.pure.address(params.originator),
      txb.pure.u64(params.totalPoolValue),
      txb.pure.u32(params.interestRate),
      txb.pure.u64(params.maturityDate),
      txb.pure.vector("u8", Array.from(Buffer.from(params.assetHash.replace(/^0x/,""), "hex"))),
      txb.pure.address(params.oracleAddress),
      txb.pure.address(params.securitizationPackageId),
      txb.object("0x6"), // Clock
    ],
  });

  return signAndExecute(txb);
}

export interface SetContractsParams {
  poolStateId:               string;
  trancheFactory:            string;
  issuanceContract:          string;
  waterfallEngine:           string;
  oracleAddress:             string;
  securitizationPackageId:   string;
}

export async function setContracts(params: SetContractsParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${params.securitizationPackageId}::pool_contract::set_contracts`,
    arguments: [
      txb.object(await _resolveAdminCap(params.securitizationPackageId)),
      txb.object(params.poolStateId),
      txb.pure.address(params.trancheFactory),
      txb.pure.address(params.issuanceContract),
      txb.pure.address(params.waterfallEngine),
      txb.pure.address(params.oracleAddress),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export interface SetContractObjectsParams {
  poolStateId:               string;
  trancheFactoryObj:         string;
  issuanceContractObj:       string;
  waterfallEngineObj:        string;
  paymentVaultObj:           string;
  securitizationPackageId:   string;
}

export async function setContractObjects(params: SetContractObjectsParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${params.securitizationPackageId}::pool_contract::set_contract_objects`,
    arguments: [
      txb.object(await _resolveAdminCap(params.securitizationPackageId)),
      txb.object(params.poolStateId),
      txb.pure.address(params.trancheFactoryObj),
      txb.pure.address(params.issuanceContractObj),
      txb.pure.address(params.waterfallEngineObj),
      txb.pure.address(params.paymentVaultObj),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function initialisePool(
  poolStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::pool_contract::initialise_pool`,
    arguments: [
      txb.object(await _resolveAdminCap(securitizationPackageId)),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function activatePool(
  poolStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::pool_contract::activate_pool`,
    arguments: [
      txb.object(await _resolveAdminCap(securitizationPackageId)),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function markDefaultAdmin(
  poolStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::pool_contract::mark_default_admin`,
    arguments: [
      txb.object(await _resolveAdminCap(securitizationPackageId)),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function closePool(
  poolStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::pool_contract::close_pool`,
    arguments: [
      txb.object(await _resolveAdminCap(securitizationPackageId)),
      txb.object(poolStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Tranche lifecycle ──────────────────────────────────────────────────────────

export interface CreateTranchesParams {
  trancheRegistryId:        string;
  poolStateId:              string;
  seniorCap:                bigint;
  mezzCap:                  bigint;
  juniorCap:                bigint;
  issuanceContractAddr:     string;
  securitizationPackageId:  string;
}

export async function createTranches(params: CreateTranchesParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${params.securitizationPackageId}::tranche_factory::create_tranches`,
    arguments: [
      txb.object(await _resolveTrancheAdminCap(params.securitizationPackageId)),
      txb.object(params.trancheRegistryId),
      txb.pure.address(params.poolStateId),  // ID passed as address
      txb.pure.u64(params.seniorCap),
      txb.pure.u64(params.mezzCap),
      txb.pure.u64(params.juniorCap),
      txb.pure.address(params.issuanceContractAddr),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Issuance lifecycle ─────────────────────────────────────────────────────────

export interface CreateIssuanceStateParams {
  issuanceOwnerCapId:       string;
  poolObjId:                string;
  priceSenior:              bigint;
  priceMezz:                bigint;
  priceJunior:              bigint;
  coinType:                 string;
  securitizationPackageId:  string;
}

export async function createIssuanceState(
  params: CreateIssuanceStateParams,
): Promise<{ digest: string; issuanceStateId: string }> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target:          `${params.securitizationPackageId}::issuance_contract::create_issuance_state`,
    typeArguments:   [params.coinType],
    arguments: [
      txb.object(params.issuanceOwnerCapId),
      txb.pure.address(params.poolObjId),  // ID passed as address
      txb.pure.u64(params.priceSenior),
      txb.pure.u64(params.priceMezz),
      txb.pure.u64(params.priceJunior),
    ],
  });

  const { digest, objectChanges } = await signAndExecute(txb);
  const issuanceStateId = extractObjectId(objectChanges, "::issuance_contract::IssuanceState");
  return { digest, issuanceStateId };
}

export interface StartIssuanceParams {
  issuanceStateId:          string;
  poolStateId:              string;
  saleStart:                number;
  saleEnd:                  number;
  securitizationPackageId:  string;
}

export async function startIssuance(params: StartIssuanceParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${params.securitizationPackageId}::issuance_contract::start_issuance`,
    typeArguments: [],
    arguments: [
      txb.object(await _resolveIssuanceOwnerCap(params.securitizationPackageId)),
      txb.object(params.issuanceStateId),
      txb.object(params.poolStateId),
      txb.pure.u64(params.saleStart),
      txb.pure.u64(params.saleEnd),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function endIssuance(
  issuanceStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::issuance_contract::end_issuance`,
    typeArguments: [],
    arguments: [
      txb.object(await _resolveIssuanceOwnerCap(securitizationPackageId)),
      txb.object(issuanceStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Waterfall ──────────────────────────────────────────────────────────────────

export interface InitialiseWaterfallParams {
  waterfallStateId:         string;
  poolObjId:                string;
  seniorOutstanding:        bigint;
  mezzOutstanding:          bigint;
  juniorOutstanding:        bigint;
  seniorRateBps:            number;
  mezzRateBps:              number;
  juniorRateBps:            number;
  paymentFrequency:         number;
  poolContractAddr:         string;
  securitizationPackageId:  string;
}

export async function initialiseWaterfall(params: InitialiseWaterfallParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${params.securitizationPackageId}::waterfall_engine::initialise_waterfall`,
    arguments: [
      txb.object(await _resolveWaterfallAdminCap(params.securitizationPackageId)),
      txb.object(params.waterfallStateId),
      txb.pure.address(params.poolObjId),  // ID passed as address
      txb.pure.u64(params.seniorOutstanding),
      txb.pure.u64(params.mezzOutstanding),
      txb.pure.u64(params.juniorOutstanding),
      txb.pure.u32(params.seniorRateBps),
      txb.pure.u32(params.mezzRateBps),
      txb.pure.u32(params.juniorRateBps),
      txb.pure.u8(params.paymentFrequency),
      txb.pure.address(params.poolContractAddr),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function runWaterfall(
  waterfallStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::waterfall_engine::run_waterfall`,
    arguments: [
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function triggerTurboMode(
  waterfallStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::waterfall_engine::trigger_turbo_mode`,
    arguments: [
      txb.object(await _resolveWaterfallAdminCap(securitizationPackageId)),
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function triggerDefaultMode(
  waterfallStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::waterfall_engine::trigger_default_mode_admin`,
    arguments: [
      txb.object(await _resolveWaterfallAdminCap(securitizationPackageId)),
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
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
  const txb = new Transaction();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::add_investor`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(params.complianceRegistryId),
      txb.pure.address(params.investor),
      txb.pure.u8(params.accreditationLevel),
      txb.pure.vector("u8", Array.from(Buffer.from(params.jurisdiction))),
      txb.pure.address(params.didObjectId),
      txb.pure.u64(params.customHoldingMs),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function removeInvestor(
  complianceRegistryId: string,
  investor: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::remove_investor`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(complianceRegistryId),
      txb.pure.address(investor),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function updateAccreditation(
  complianceRegistryId: string,
  investor:             string,
  newLevel:             number,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${config.spvPackageId}::compliance_registry::update_accreditation`,
    arguments: [
      txb.object(await _resolveComplianceAdminCap()),
      txb.object(complianceRegistryId),
      txb.pure.address(investor),
      txb.pure.u8(newLevel),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function depositPayment(
  waterfallStateId: string,
  amount:           bigint,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::waterfall_engine::deposit_payment`,
    arguments: [
      txb.object(waterfallStateId),
      txb.pure.u64(amount),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

export async function accrueInterest(
  waterfallStateId: string,
  securitizationPackageId: string,
): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target: `${securitizationPackageId}::waterfall_engine::accrue_interest`,
    arguments: [
      txb.object(waterfallStateId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Payment Vault (spv package) ────────────────────────────────────────────────

export async function createVault(coinType: string): Promise<{ digest: string; vaultId: string }> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target:        `${config.spvPackageId}::payment_vault::create_vault`,
    typeArguments: [coinType],
    arguments: [
      txb.object(await _resolveVaultAdminCap()),
    ],
  });

  const { digest, objectChanges } = await signAndExecute(txb);
  const vaultId = extractObjectId(objectChanges, "::payment_vault::VaultBalance");
  return { digest, vaultId };
}

export interface ReleaseFundsToVaultParams {
  issuanceStateId:         string;
  vaultId:                 string;
  coinType:                string;
  securitizationPackageId: string;
}

export async function releaseFundsToVault(params: ReleaseFundsToVaultParams): Promise<string> {
  requireSigner();
  const txb = new Transaction();

  txb.moveCall({
    target:        `${params.securitizationPackageId}::issuance_contract::release_funds_to_vault`,
    typeArguments: [params.coinType],
    arguments: [
      txb.object(await _resolveIssuanceOwnerCap(params.securitizationPackageId)),
      txb.object(params.issuanceStateId),
      txb.object(params.vaultId),
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Issuance: invest ───────────────────────────────────────────────────────────

export interface InvestParams {
  issuanceStateId:          string;
  trancheRegistryId:        string;
  complianceRegistryId:     string;
  trancheType:              number;   // 0 = Senior, 1 = Mezz, 2 = Junior
  amount:                   bigint;
  securitizationPackageId:  string;
}

export async function invest(params: InvestParams): Promise<string> {
  requireSigner();
  const kp        = getKeypair();
  const adminAddr = kp.getPublicKey().toIotaAddress();

  // Derive coinType from the IssuanceState object type string, e.g.:
  //   0xPKG::issuance_contract::IssuanceState<0x2::iota::IOTA>
  const { objectType } = await fetchObjectWithType(params.issuanceStateId);
  const coinTypeMatch  = objectType.match(/<(.+)>$/);
  if (!coinTypeMatch) {
    throw ApiError.internal(`Could not extract coin type from IssuanceState type: ${objectType}`);
  }
  const coinType = coinTypeMatch[1];

  const txb = new Transaction();

  // Split the payment coin from the admin wallet.
  // For the gas coin (IOTA) use txb.gas directly; otherwise fetch a coin object.
  let paymentCoin: ReturnType<Transaction["splitCoins"]>[number];
  if (coinType === "0x2::iota::IOTA") {
    [paymentCoin] = txb.splitCoins(txb.gas, [txb.pure.u64(params.amount)]);
  } else {
    const coins = await iotaClient.getCoins({ owner: adminAddr, coinType });
    if (!coins.data.length) {
      throw ApiError.internal(`No coin of type ${coinType} found in signer wallet`);
    }
    [paymentCoin] = txb.splitCoins(txb.object(coins.data[0].coinObjectId), [txb.pure.u64(params.amount)]);
  }

  txb.moveCall({
    target:        `${params.securitizationPackageId}::issuance_contract::invest`,
    typeArguments: [coinType],
    arguments: [
      txb.object(params.issuanceStateId),
      txb.object(params.trancheRegistryId),
      txb.object(params.complianceRegistryId),
      txb.object(await _resolveIssuanceAdminCap(params.securitizationPackageId)),
      txb.pure.u8(params.trancheType),
      paymentCoin,
      txb.object("0x6"),
    ],
  });

  const { digest } = await signAndExecute(txb);
  return digest;
}

// ── Cap resolution helpers ─────────────────────────────────────────────────────
// Caps are owned objects in the signer's wallet — we find them by type.
// pkgId is per-pool, so we filter by the full type string to get the right cap.

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

async function _resolveAdminCap(pkgId: string): Promise<string> {
  return _resolveCap(`${pkgId}::pool_contract::AdminCap`);
}

async function _resolveIssuanceOwnerCap(pkgId: string): Promise<string> {
  return _resolveCap(`${pkgId}::issuance_contract::IssuanceOwnerCap`);
}

async function _resolveWaterfallAdminCap(pkgId: string): Promise<string> {
  return _resolveCap(`${pkgId}::waterfall_engine::WaterfallAdminCap`);
}

async function _resolveTrancheAdminCap(pkgId: string): Promise<string> {
  return _resolveCap(`${pkgId}::tranche_factory::TrancheAdminCap`);
}

async function _resolveIssuanceAdminCap(pkgId: string): Promise<string> {
  return _resolveCap(`${pkgId}::tranche_factory::IssuanceAdminCap`);
}

async function _resolveComplianceAdminCap(): Promise<string> {
  return _resolveCap(`${config.spvPackageId}::compliance_registry::ComplianceAdminCap`);
}

async function _resolveVaultAdminCap(): Promise<string> {
  return _resolveCap(`${config.spvPackageId}::payment_vault::VaultAdminCap`);
}
