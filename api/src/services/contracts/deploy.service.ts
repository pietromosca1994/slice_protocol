/**
 * DeployService
 *
 * Orchestrates building and publishing a fresh securitization package per pool.
 * Returns the package ID and all capability/object IDs created on publish.
 */
import { execSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { Transaction } from "@iota/iota-sdk/transactions";
import { signAndExecute, getKeypair, iotaClient } from "../iota-client";
import { config } from "../../config";
import { logger } from "../../utils/logger";

// ── Types ─────────────────────────────────────────────────────────────────────

export interface SetupPoolParams {
  spv:              string;
  poolId:           string;
  originator:       string;
  totalPoolValue:   bigint;
  interestRate:     number;
  maturityDate:     number;
  assetHash:        string;
  oracleAddress:    string;
  seniorSupplyCap:  bigint;
  mezzSupplyCap:    bigint;
  juniorSupplyCap:  bigint;
  seniorFaceValue:  bigint;
  mezzFaceValue:    bigint;
  juniorFaceValue:  bigint;
  seniorRateBps:    number;
  mezzRateBps:      number;
  juniorRateBps:    number;
  paymentFrequency: number;
  coinType:         string;
}

export interface SetupPoolResult {
  poolStateId:      string;
  issuanceStateId:  string;
  vaultId:          string;
}

export interface DeployResult {
  packageId:           string;
  adminCapId:          string;
  trancheAdminCapId:   string;
  trancheRegistryId:   string;
  waterfallStateId:    string;
  waterfallAdminCapId: string;
  issuanceOwnerCapId:  string;
  seniorTreasuryId:    string;
  mezzTreasuryId:      string;
  juniorTreasuryId:    string;
}

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Find the objectId of the first created object whose type contains `suffix`.
 *  Uses `includes` rather than `endsWith` to handle generic types like `IssuanceState<C>`. */
export function extractObjectId(objectChanges: any[], typeSuffix: string): string {
  const entry = objectChanges.find(
    (o: any) => o.type === "created" && typeof o.objectType === "string" && o.objectType.includes(typeSuffix),
  );
  if (!entry) {
    throw new Error(`No created object found with type suffix: ${typeSuffix}`);
  }
  return entry.objectId as string;
}

function extractSharedObjectId(objectChanges: any[], typeSuffix: string): string {
  const entry = objectChanges.find(
    (o: any) =>
      o.type === "created" &&
      typeof o.objectType === "string" &&
      o.objectType.includes(typeSuffix),
  );
  if (!entry) {
    throw new Error(`No created shared object found with type suffix: ${typeSuffix}`);
  }
  return entry.objectId as string;
}

// ── Service ───────────────────────────────────────────────────────────────────

/**
 * Build and publish the securitization package from source, then run bootstrap.
 * Returns IDs of all capabilities and shared objects created.
 */
export async function deploySecuritizationPackage(): Promise<DeployResult> {
  const kp      = getKeypair();
  const sender  = kp.getPublicKey().toIotaAddress();
  // Resolve the packages/ directory.
  // In Docker: PACKAGES_PATH env var points to the copied packages/ directory.
  // Locally: auto-detect by walking up from __dirname (src/services/contracts → repo root).
  const packagesPath = config.packagesPath
    ?? path.join(__dirname, "../../../../packages");

  // ── Step 1: Build bytecode ───────────────────────────────────────────────
  // Patch Move.toml to inject the deployed spv address, then restore it.
  const moveTomlPath = path.join(packagesPath, "securitization/Move.toml");
  const moveTomlOriginal = fs.readFileSync(moveTomlPath, "utf8");
  const moveTomlPatched = moveTomlOriginal.replace(
    /^(spv\s*=\s*)"[^"]*"/m,
    `$1"${config.spvPackageId}"`,
  );

  logger.info("Building securitization package bytecode…");
  let buildOutput: string;
  try {
    fs.writeFileSync(moveTomlPath, moveTomlPatched, "utf8");
    buildOutput = execSync(
      `iota move build --dump-bytecode-as-base64 --path "${packagesPath}/securitization"`,
      { encoding: "utf8" },
    );
  } finally {
    fs.writeFileSync(moveTomlPath, moveTomlOriginal, "utf8");
  }
  const { modules, dependencies } = JSON.parse(buildOutput) as {
    modules:      string[];
    dependencies: string[];
  };

  // ── Step 2: Publish ──────────────────────────────────────────────────────
  logger.info("Publishing securitization package…");
  const publishTxb = new Transaction();
  publishTxb.setSender(sender);
  const [upgradeCap] = publishTxb.publish({ modules, dependencies });
  publishTxb.transferObjects([upgradeCap], sender);

  // Pass null so the SDK auto-estimates gas via devInspect (same as `iota client publish`)
  const { digest: publishDigest, objectChanges: publishChanges } = await signAndExecute(publishTxb, null);
  logger.info({ digest: publishDigest }, "Securitization package published");

  // Wait for the package to be indexed before the bootstrap call
  await iotaClient.waitForTransaction({ digest: publishDigest });
  logger.info("Package indexed, proceeding to bootstrap…");

  // Extract package ID from the "published" entry
  const publishedEntry = publishChanges.find((o: any) => o.type === "published");
  if (!publishedEntry?.packageId) {
    throw new Error("Could not find packageId in publish objectChanges");
  }
  const packageId = publishedEntry.packageId as string;
  logger.info({ packageId }, "Securitization package ID");

  // Extract capability and object IDs
  const adminCapId          = extractObjectId(publishChanges, "::pool_contract::AdminCap");
  const trancheAdminCapId   = extractObjectId(publishChanges, "::tranche_factory::TrancheAdminCap");
  const trancheRegistryId   = extractSharedObjectId(publishChanges, "::tranche_factory::TrancheRegistry");
  const waterfallStateId    = extractSharedObjectId(publishChanges, "::waterfall_engine::WaterfallState");
  const waterfallAdminCapId = extractObjectId(publishChanges, "::waterfall_engine::WaterfallAdminCap");
  const issuanceOwnerCapId  = extractObjectId(publishChanges, "::issuance_contract::IssuanceOwnerCap");
  const seniorTreasuryId    = extractSharedObjectId(publishChanges, "::senior_coin::SeniorTreasury");
  const mezzTreasuryId      = extractSharedObjectId(publishChanges, "::mezz_coin::MezzTreasury");
  const juniorTreasuryId    = extractSharedObjectId(publishChanges, "::junior_coin::JuniorTreasury");

  // ── Step 3: Bootstrap (inject TreasuryCaps into TrancheRegistry) ─────────
  logger.info("Running tranche_factory::bootstrap…");
  const bootstrapTxb = new Transaction();
  bootstrapTxb.moveCall({
    target: `${packageId}::tranche_factory::bootstrap`,
    arguments: [
      bootstrapTxb.object(trancheAdminCapId),
      bootstrapTxb.object(trancheRegistryId),
      bootstrapTxb.object(seniorTreasuryId),
      bootstrapTxb.object(mezzTreasuryId),
      bootstrapTxb.object(juniorTreasuryId),
    ],
  });
  const { digest: bootstrapDigest } = await signAndExecute(bootstrapTxb);
  logger.info({ digest: bootstrapDigest }, "Bootstrap complete");

  return {
    packageId,
    adminCapId,
    trancheAdminCapId,
    trancheRegistryId,
    waterfallStateId,
    waterfallAdminCapId,
    issuanceOwnerCapId,
    seniorTreasuryId,
    mezzTreasuryId,
    juniorTreasuryId,
  };
}

/**
 * Single-PTB pool setup: creates, wires, activates, and registers a pool
 * atomically. If any command aborts the entire transaction rolls back — the
 * SPVRegistry is never touched on failure.
 *
 * PTB sequence (14 commands):
 *  1.  create_pool_unsealed         → pool_state (owned)
 *  2.  pool_obj_id(&pool_state)     → pool_obj_id (ID)
 *  3.  create_vault_unsealed        → vault (owned)
 *  4.  payment_vault::object_id     → vault_id (ID)
 *  5.  create_issuance_state_unsealed(pool_obj_id, vault_id) → issuance_state (owned)
 *  6.  issuance_contract::object_id → issuance_state_id (ID)
 *  7.  set_contracts
 *  8.  create_tranches
 *  9.  set_contract_objects
 * 10.  initialise_pool
 * 11.  initialise_waterfall
 * 12.  activate_and_register_pool   ← consumes pool_state, shares PoolState
 * 13.  share_issuance_state         ← consumes issuance_state
 * 14.  share_vault                  ← consumes vault
 */
export async function setupPool(
  deployResult: DeployResult,
  body: SetupPoolParams,
  sender: string,
): Promise<SetupPoolResult> {
  const {
    packageId,
    adminCapId,
    trancheAdminCapId,
    trancheRegistryId,
    waterfallStateId,
    waterfallAdminCapId,
    issuanceOwnerCapId,
  } = deployResult;

  const vaultAdminCapId = await _resolveVaultAdminCap();

  const priceSenior = body.seniorFaceValue / body.seniorSupplyCap;
  const priceMezz   = body.mezzFaceValue   / body.mezzSupplyCap;
  const priceJunior = body.juniorFaceValue  / body.juniorSupplyCap;

  const txb = new Transaction();
  txb.setSender(sender);

  // 1. create_pool_unsealed → pool_state (owned PoolState, not yet shared)
  const [poolState] = txb.moveCall({
    target: `${packageId}::pool_contract::create_pool_unsealed`,
    arguments: [
      txb.object(adminCapId),
      txb.pure.address(body.spv),
      txb.pure.vector("u8", Array.from(Buffer.from(body.poolId))),
      txb.pure.address(body.originator),
      txb.pure.u64(body.totalPoolValue),
      txb.pure.u32(body.interestRate),
      txb.pure.u64(body.maturityDate),
      txb.pure.vector("u8", Array.from(Buffer.from(body.assetHash.replace(/^0x/, ""), "hex"))),
      txb.pure.address(body.oracleAddress),
      txb.object("0x6"), // Clock
    ],
  });

  // 2. pool_obj_id(&pool_state) → pool_obj_id
  const [poolObjId] = txb.moveCall({
    target: `${packageId}::pool_contract::pool_obj_id`,
    arguments: [poolState],
  });

  // 3. create_vault_unsealed → vault (owned VaultBalance, not yet shared)
  //    Must precede issuance state creation so vault_id can be wired in.
  const [vault] = txb.moveCall({
    target: `${config.spvPackageId}::payment_vault::create_vault_unsealed`,
    typeArguments: [body.coinType],
    arguments: [txb.object(vaultAdminCapId)],
  });

  // 4. payment_vault::object_id(&vault) → vault_id
  const [vaultId] = txb.moveCall({
    target: `${config.spvPackageId}::payment_vault::object_id`,
    typeArguments: [body.coinType],
    arguments: [vault],
  });

  // 5. create_issuance_state_unsealed → issuance_state (owned, not yet shared)
  const [issuanceState] = txb.moveCall({
    target: `${packageId}::issuance_contract::create_issuance_state_unsealed`,
    typeArguments: [body.coinType],
    arguments: [
      txb.object(issuanceOwnerCapId),
      poolObjId,
      vaultId,
      txb.pure.u64(priceSenior),
      txb.pure.u64(priceMezz),
      txb.pure.u64(priceJunior),
    ],
  });

  // 6. issuance_contract::object_id(&issuance_state) → issuance_state_id
  const [issuanceStateId] = txb.moveCall({
    target: `${packageId}::issuance_contract::object_id`,
    typeArguments: [body.coinType],
    arguments: [issuanceState],
  });

  // 7. set_contracts — deployer addresses (all signer for this deployment)
  txb.moveCall({
    target: `${packageId}::pool_contract::set_contracts`,
    arguments: [
      txb.object(adminCapId),
      poolState,
      txb.pure.address(sender),
      txb.pure.address(sender),
      txb.pure.address(sender),
      txb.pure.address(body.oracleAddress),
    ],
  });

  // 8. create_tranches — bind TrancheRegistry to this pool
  txb.moveCall({
    target: `${packageId}::tranche_factory::create_tranches`,
    arguments: [
      txb.object(trancheAdminCapId),
      txb.object(trancheRegistryId),
      poolObjId,
      txb.pure.u64(body.seniorSupplyCap),
      txb.pure.u64(body.mezzSupplyCap),
      txb.pure.u64(body.juniorSupplyCap),
      txb.pure.address(sender), // IssuanceAdminCap recipient
      txb.object("0x6"), // Clock
    ],
  });

  // 9. set_contract_objects — wire all shared object IDs into PoolState
  txb.moveCall({
    target: `${packageId}::pool_contract::set_contract_objects`,
    arguments: [
      txb.object(adminCapId),
      poolState,
      txb.pure.address(trancheRegistryId),
      issuanceStateId,
      txb.pure.address(waterfallStateId),
      vaultId,
    ],
  });

  // 10. initialise_pool — mint and send OracleCap, set initialised = true
  txb.moveCall({
    target: `${packageId}::pool_contract::initialise_pool`,
    arguments: [
      txb.object(adminCapId),
      poolState,
      txb.object("0x6"), // Clock
    ],
  });

  // 11. initialise_waterfall — set outstanding amounts and rates
  txb.moveCall({
    target: `${packageId}::waterfall_engine::initialise_waterfall`,
    arguments: [
      txb.object(waterfallAdminCapId),
      txb.object(waterfallStateId),
      poolObjId,
      txb.pure.u64(body.seniorFaceValue),
      txb.pure.u64(body.mezzFaceValue),
      txb.pure.u64(body.juniorFaceValue),
      txb.pure.u32(body.seniorRateBps),
      txb.pure.u32(body.mezzRateBps),
      txb.pure.u32(body.juniorRateBps),
      txb.pure.u8(body.paymentFrequency),
      txb.pure.address(body.oracleAddress),
      txb.object("0x6"), // Clock
    ],
  });

  // 12. activate_and_register_pool — consumes pool_state, shares PoolState, registers in SPVRegistry
  txb.moveCall({
    target: `${packageId}::pool_contract::activate_and_register_pool`,
    arguments: [
      txb.object(adminCapId),
      poolState,
      txb.object(config.spvRegistryId),
      txb.pure.address(packageId),
      txb.object("0x6"), // Clock
    ],
  });

  // 13. share_issuance_state — consumes issuance_state
  txb.moveCall({
    target: `${packageId}::issuance_contract::share_issuance_state`,
    typeArguments: [body.coinType],
    arguments: [issuanceState],
  });

  // 14. share_vault — consumes vault
  txb.moveCall({
    target: `${config.spvPackageId}::payment_vault::share_vault`,
    typeArguments: [body.coinType],
    arguments: [vault],
  });

  const { digest, objectChanges } = await signAndExecute(txb, null);
  logger.info({ digest }, "Pool setup PTB complete");

  const poolStateObjId     = extractObjectId(objectChanges, "::pool_contract::PoolState");
  const issuanceStateObjId = extractObjectId(objectChanges, "::issuance_contract::IssuanceState");
  const vaultObjId         = extractObjectId(objectChanges, "::payment_vault::VaultBalance");

  return { poolStateId: poolStateObjId, issuanceStateId: issuanceStateObjId, vaultId: vaultObjId };
}

// ── Private helpers ────────────────────────────────────────────────────────────

async function _resolveVaultAdminCap(): Promise<string> {
  const kp    = getKeypair();
  const owner = kp.getPublicKey().toIotaAddress();
  const { data } = await iotaClient.getOwnedObjects({
    owner,
    filter:  { StructType: `${config.spvPackageId}::payment_vault::VaultAdminCap` },
    options: { showType: true },
  });
  const capId = data?.[0]?.data?.objectId;
  if (!capId) {
    throw new Error(`No VaultAdminCap found in signer wallet for spv package ${config.spvPackageId}`);
  }
  return capId;
}
