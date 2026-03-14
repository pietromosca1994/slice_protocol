/**
 * RegistryService
 *
 * Reads the SPVRegistry shared object and resolves linked pool/tranche/issuance
 * objects entirely from on-chain data. The operator supplies only SPV_REGISTRY_ID;
 * all downstream object IDs are read from PoolState's _obj fields.
 */
import { config } from "../../config";
import { iotaClient, fetchObject } from "../iota-client";
import { logger } from "../../utils/logger";

// ── Raw on-chain shapes ───────────────────────────────────────────────────────

interface RawSPVRegistry {
  pool_ids:   string[];
  pool_count: string;
}

interface RawPoolState {
  pool_obj_id:                   string;
  pool_id:                       string;
  originator:                    string;
  spv:                           string;
  total_pool_value:              string;
  current_outstanding_principal: string;
  interest_rate:                 string;
  maturity_date:                 string;
  asset_hash:                    string;
  pool_status:                   string;
  oracle_address:                string;
  tranche_factory:               string;
  issuance_contract:             string;
  waterfall_engine:              string;
  // Object IDs of linked shared objects
  tranche_factory_obj:           string;
  issuance_contract_obj:         string;
  waterfall_engine_obj:          string;
  initialised:                   boolean;
}

interface RawTrancheRegistry {
  pool_obj_id:       string;
  senior_supply_cap: string;
  mezz_supply_cap:   string;
  junior_supply_cap: string;
  senior_minted:     string;
  mezz_minted:       string;
  junior_minted:     string;
  minting_enabled:   boolean;
  tranches_created:  boolean;
  issuance_contract: string;
  bootstrapped:      boolean;
}

interface RawIssuanceState {
  pool_obj_id:           string;
  price_per_unit_senior: string;
  price_per_unit_mezz:   string;
  price_per_unit_junior: string;
  sale_start:            string;
  sale_end:              string;
  total_raised:          string;
  issuance_active:       boolean;
  issuance_ended:        boolean;
  succeeded:             boolean;
}

interface RawWaterfallState {
  pool_obj_id:             string;
  senior_outstanding:      string;
  mezz_outstanding:        string;
  junior_outstanding:      string;
  senior_accrued_interest: string;
  mezz_accrued_interest:   string;
  junior_accrued_interest: string;
  senior_rate_bps:         string;
  mezz_rate_bps:           string;
  junior_rate_bps:         string;
  reserve_account:         string;
  pending_funds:           string;
  last_distribution_ms:    string;
  payment_frequency:       string;
  waterfall_status:        string;
}

// ── Normalised API types ──────────────────────────────────────────────────────

export type PoolStatus    = "Created" | "Active" | "Defaulted" | "Matured";
export type WaterfallMode = "Normal"  | "Turbo"  | "Default";

const POOL_STATUS: Record<string, PoolStatus> = {
  "0": "Created", "1": "Active", "2": "Defaulted", "3": "Matured",
};
const WATERFALL_MODE: Record<string, WaterfallMode> = {
  "0": "Normal", "1": "Turbo", "2": "Default",
};

const ZERO_ID = "0x0000000000000000000000000000000000000000000000000000000000000000";

function isZeroId(id: string): boolean {
  return !id || id === ZERO_ID || id === "0x0";
}

function hex2utf8(hex: string): string {
  try { return Buffer.from(hex.replace(/^0x/, ""), "hex").toString("utf8"); }
  catch { return hex; }
}

export interface ContractObjects {
  trancheFactoryObj:   string | null;
  issuanceContractObj: string | null;
  waterfallEngineObj:  string | null;
}

export interface PoolSummary {
  poolObjId:            string;
  poolId:               string;
  spv:                  string;
  originator:           string;
  status:               PoolStatus;
  totalPoolValue:       bigint;
  outstandingPrincipal: bigint;
  interestRateBps:      number;
  maturityDate:         Date;
  initialised:          boolean;
  contractAddresses: {
    trancheFactory:   string;
    issuanceContract: string;
    waterfallEngine:  string;
  };
  contractObjects: ContractObjects;
}

export interface TrancheInfo {
  seniorSupplyCap: bigint;
  mezzSupplyCap:   bigint;
  juniorSupplyCap: bigint;
  seniorMinted:    bigint;
  mezzMinted:      bigint;
  juniorMinted:    bigint;
  mintingEnabled:  boolean;
}

export interface IssuanceInfo {
  issuanceActive: boolean;
  issuanceEnded:  boolean;
  succeeded:      boolean;
  totalRaised:    bigint;
  saleStart:      Date | null;
  saleEnd:        Date | null;
  prices: { senior: bigint; mezz: bigint; junior: bigint };
}

export interface WaterfallInfo {
  mode:               WaterfallMode;
  paymentFrequency:   "Monthly" | "Quarterly";
  seniorOutstanding:  bigint;
  mezzOutstanding:    bigint;
  juniorOutstanding:  bigint;
  seniorAccrued:      bigint;
  mezzAccrued:        bigint;
  juniorAccrued:      bigint;
  reserveAccount:     bigint;
  pendingFunds:       bigint;
  lastDistributionMs: Date | null;
}

export interface FullPool {
  pool:      PoolSummary;
  tranches:  TrancheInfo   | null;
  issuance:  IssuanceInfo  | null;
  waterfall: WaterfallInfo | null;
}

// ── Service ───────────────────────────────────────────────────────────────────

export class RegistryService {

  async getRegistryMeta() {
    const raw = await fetchObject<RawSPVRegistry>(config.spvRegistryId);
    return {
      poolCount:  Number(raw.pool_count),
      packageIds: {
        spv:             config.spvPackageId,
        securitization:  config.securitizationPackageId,
      },
    };
  }

  async getAllPoolIds(): Promise<string[]> {
    const raw = await fetchObject<RawSPVRegistry>(config.spvRegistryId);
    return raw.pool_ids ?? [];
  }

  async getPoolIdsForSpv(spvAddress: string): Promise<string[]> {
    const tableId = await this._resolveTableId("spv_pools");
    if (!tableId) return [];
    try {
      const entry = await iotaClient.getDynamicFieldObject({
        parentId: tableId,
        name: { type: "address", value: spvAddress },
      });
      if (!entry.data?.content || entry.data.content.dataType !== "moveObject") return [];
      const fields = entry.data.content.fields as { value: string[] };
      return fields.value ?? [];
    } catch { return []; }
  }

  async getPool(poolObjId: string): Promise<PoolSummary> {
    const raw = await fetchObject<RawPoolState>(poolObjId);
    return this._normalisePool(raw);
  }

  async getFullPool(poolObjId: string): Promise<FullPool> {
    const pool = await this.getPool(poolObjId);
    const obj  = pool.contractObjects;

    const [tranches, issuance, waterfall] = await Promise.allSettled([
      obj.trancheFactoryObj   ? this.getTranches(obj.trancheFactoryObj)   : Promise.resolve(null),
      obj.issuanceContractObj ? this.getIssuance(obj.issuanceContractObj) : Promise.resolve(null),
      obj.waterfallEngineObj  ? this.getWaterfall(obj.waterfallEngineObj) : Promise.resolve(null),
    ]);

    return {
      pool,
      tranches:  tranches.status  === "fulfilled" ? tranches.value  : null,
      issuance:  issuance.status  === "fulfilled" ? issuance.value  : null,
      waterfall: waterfall.status === "fulfilled" ? waterfall.value : null,
    };
  }

  async getAllPools(): Promise<PoolSummary[]> {
    const ids     = await this.getAllPoolIds();
    const results = await Promise.allSettled(ids.map(id => this.getPool(id)));
    return results
      .filter((r): r is PromiseFulfilledResult<PoolSummary> => r.status === "fulfilled")
      .map(r => r.value);
  }

  async getTranches(objId: string): Promise<TrancheInfo> {
    const raw = await fetchObject<RawTrancheRegistry>(objId);
    return {
      seniorSupplyCap: BigInt(raw.senior_supply_cap),
      mezzSupplyCap:   BigInt(raw.mezz_supply_cap),
      juniorSupplyCap: BigInt(raw.junior_supply_cap),
      seniorMinted:    BigInt(raw.senior_minted),
      mezzMinted:      BigInt(raw.mezz_minted),
      juniorMinted:    BigInt(raw.junior_minted),
      mintingEnabled:  raw.minting_enabled,
    };
  }

  async getIssuance(objId: string): Promise<IssuanceInfo> {
    const raw       = await fetchObject<RawIssuanceState>(objId);
    const saleStart = Number(raw.sale_start);
    const saleEnd   = Number(raw.sale_end);
    return {
      issuanceActive: raw.issuance_active,
      issuanceEnded:  raw.issuance_ended,
      succeeded:      raw.succeeded,
      totalRaised:    BigInt(raw.total_raised),
      saleStart:      saleStart > 0 ? new Date(saleStart) : null,
      saleEnd:        saleEnd   > 0 ? new Date(saleEnd)   : null,
      prices: {
        senior: BigInt(raw.price_per_unit_senior),
        mezz:   BigInt(raw.price_per_unit_mezz),
        junior: BigInt(raw.price_per_unit_junior),
      },
    };
  }

  async getWaterfall(objId: string): Promise<WaterfallInfo> {
    const raw    = await fetchObject<RawWaterfallState>(objId);
    const lastMs = Number(raw.last_distribution_ms);
    return {
      mode:               WATERFALL_MODE[raw.waterfall_status] ?? "Normal",
      paymentFrequency:   raw.payment_frequency === "0" ? "Monthly" : "Quarterly",
      seniorOutstanding:  BigInt(raw.senior_outstanding),
      mezzOutstanding:    BigInt(raw.mezz_outstanding),
      juniorOutstanding:  BigInt(raw.junior_outstanding),
      seniorAccrued:      BigInt(raw.senior_accrued_interest),
      mezzAccrued:        BigInt(raw.mezz_accrued_interest),
      juniorAccrued:      BigInt(raw.junior_accrued_interest),
      reserveAccount:     BigInt(raw.reserve_account),
      pendingFunds:       BigInt(raw.pending_funds),
      lastDistributionMs: lastMs > 0 ? new Date(lastMs) : null,
    };
  }

  // ── Internals ──────────────────────────────────────────────────────────────

  private async _resolveTableId(fieldName: string): Promise<string | null> {
    try {
      const reg    = await iotaClient.getObject({ id: config.spvRegistryId, options: { showContent: true } });
      if (reg.data?.content?.dataType !== "moveObject") return null;
      const fields = reg.data.content.fields as Record<string, { fields: { id: { id: string } } }>;
      return fields[fieldName]?.fields?.id?.id ?? null;
    } catch (e) {
      logger.warn({ err: e, fieldName }, "Could not resolve table ID");
      return null;
    }
  }

  private _normalisePool(raw: RawPoolState): PoolSummary {
    return {
      poolObjId:            raw.pool_obj_id,
      poolId:               hex2utf8(raw.pool_id),
      spv:                  raw.spv,
      originator:           raw.originator,
      status:               POOL_STATUS[raw.pool_status] ?? "Created",
      totalPoolValue:       BigInt(raw.total_pool_value),
      outstandingPrincipal: BigInt(raw.current_outstanding_principal),
      interestRateBps:      Number(raw.interest_rate),
      maturityDate:         new Date(Number(raw.maturity_date)),
      initialised:          raw.initialised,
      contractAddresses: {
        trancheFactory:   raw.tranche_factory,
        issuanceContract: raw.issuance_contract,
        waterfallEngine:  raw.waterfall_engine,
      },
      contractObjects: {
        trancheFactoryObj:   isZeroId(raw.tranche_factory_obj)   ? null : raw.tranche_factory_obj,
        issuanceContractObj: isZeroId(raw.issuance_contract_obj) ? null : raw.issuance_contract_obj,
        waterfallEngineObj:  isZeroId(raw.waterfall_engine_obj)  ? null : raw.waterfall_engine_obj,
      },
    };
  }
}

export const registryService = new RegistryService();
