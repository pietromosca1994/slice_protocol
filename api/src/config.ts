import dotenv from "dotenv";
import { z } from "zod";

dotenv.config();

const networkUrls: Record<string, string> = {
  testnet: "https://api.testnet.iota.cafe",
  mainnet: "https://api.mainnet.iota.cafe",
  devnet:  "https://api.devnet.iota.cafe",
  localnet: "http://127.0.0.1:9000",
};

const ConfigSchema = z.object({
  PORT:                     z.coerce.number().default(3000),
  LOG_LEVEL:                z.enum(["fatal","error","warn","info","debug","trace"]).default("info"),
  IOTA_NETWORK:             z.enum(["testnet","mainnet","devnet","localnet"]).default("testnet"),
  IOTA_RPC_URL:             z.string().optional(),

  // On-chain addresses — the only things the operator must know besides the key
  SPV_REGISTRY_ID:          z.string().min(1, "SPV_REGISTRY_ID is required"),
  SPV_PACKAGE_ID:           z.string().min(1, "SPV_PACKAGE_ID is required"),
  SECURITIZATION_PACKAGE_ID:z.string().min(1, "SECURITIZATION_PACKAGE_ID is required"),

  // Signer — optional: without it the API is read-only
  ADMIN_SECRET_KEY:         z.string().optional(),

  GAS_BUDGET:               z.coerce.number().default(100_000_000),
});

const parsed = ConfigSchema.safeParse(process.env);
if (!parsed.success) {
  console.error("❌  Invalid environment configuration:");
  for (const issue of parsed.error.issues) {
    console.error(`   ${issue.path.join(".")}: ${issue.message}`);
  }
  process.exit(1);
}

const env = parsed.data;

export const config = {
  port:                     env.PORT,
  logLevel:                 env.LOG_LEVEL,
  network:                  env.IOTA_NETWORK,
  rpcUrl:                   env.IOTA_RPC_URL ?? networkUrls[env.IOTA_NETWORK],
  spvRegistryId:            env.SPV_REGISTRY_ID,
  spvPackageId:             env.SPV_PACKAGE_ID,
  securitizationPackageId:  env.SECURITIZATION_PACKAGE_ID,
  adminSecretKey:           env.ADMIN_SECRET_KEY,
  gasBudget:                env.GAS_BUDGET,
  readOnly:                 !env.ADMIN_SECRET_KEY,
} as const;
