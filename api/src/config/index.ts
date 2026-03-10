import dotenv from 'dotenv';
dotenv.config();

export type Network = 'mainnet' | 'testnet' | 'localnet';

const NETWORK_RPC: Record<Network, string> = {
  mainnet: process.env.IOTA_MAINNET_RPC_URL ?? 'https://api.mainnet.iota.cafe',
  testnet: process.env.IOTA_TESTNET_RPC_URL ?? 'https://api.testnet.iota.cafe',
  localnet: process.env.IOTA_LOCALNET_RPC_URL ?? 'http://localhost:9000',
};

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function optional(name: string, fallback = ''): string {
  return process.env[name] ?? fallback;
}

export const config = {
  port: parseInt(process.env.PORT ?? '3000', 10),
  logLevel: process.env.LOG_LEVEL ?? 'info',

  network: (process.env.IOTA_NETWORK ?? 'testnet') as Network,
  rpcUrl(network?: Network): string {
    return NETWORK_RPC[network ?? this.network];
  },

  signerPrivateKey: optional('SIGNER_PRIVATE_KEY'),

  // Contract addresses
  packageId: optional('PACKAGE_ID'),

  // Shared objects
  objects: {
    poolState: optional('POOL_STATE_ID'),
    complianceRegistry: optional('COMPLIANCE_REGISTRY_ID'),
    trancheRegistry: optional('TRANCHE_REGISTRY_ID'),
    waterfallState: optional('WATERFALL_STATE_ID'),
    seniorTreasury: optional('SENIOR_TREASURY_ID'),
    mezzTreasury: optional('MEZZ_TREASURY_ID'),
    juniorTreasury: optional('JUNIOR_TREASURY_ID'),
    clock: optional('CLOCK_OBJECT_ID', '0x0000000000000000000000000000000000000000000000000000000000000006'),
  },

  // Capability objects
  caps: {
    adminCap: optional('ADMIN_CAP_ID'),
    oracleCap: optional('ORACLE_CAP_ID'),
    complianceAdminCap: optional('COMPLIANCE_ADMIN_CAP_ID'),
    trancheAdminCap: optional('TRANCHE_ADMIN_CAP_ID'),
    issuanceAdminCap: optional('ISSUANCE_ADMIN_CAP_ID'),
    vaultAdminCap: optional('VAULT_ADMIN_CAP_ID'),
    waterfallAdminCap: optional('WATERFALL_ADMIN_CAP_ID'),
    issuanceOwnerCap: optional('ISSUANCE_OWNER_CAP_ID'),
  },
} as const;
