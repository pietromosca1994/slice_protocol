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
  const repoRoot = path.join(__dirname, "../../../../");

  // ── Step 1: Build bytecode ───────────────────────────────────────────────
  // Patch Move.toml to inject the deployed spv address, then restore it.
  const moveTomlPath = path.join(repoRoot, "packages/securitization/Move.toml");
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
      `iota move build --dump-bytecode-as-base64 --path ./packages/securitization`,
      { cwd: repoRoot, encoding: "utf8" },
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
