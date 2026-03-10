// ─── Network types ────────────────────────────────────────────────────────────

export type Network = 'mainnet' | 'testnet' | 'localnet';

// ─── Pool types ────────────────────────────────────────────────────────────────

export const PoolStatus = {
  CREATED: 0,
  ACTIVE: 1,
  DEFAULTED: 2,
  MATURED: 3,
} as const;

export type PoolStatusValue = (typeof PoolStatus)[keyof typeof PoolStatus];

export interface PoolState {
  id: string;
  poolId: string;
  originator: string;
  spv: string;
  totalPoolValue: string;
  currentOutstandingPrincipal: string;
  interestRate: number;
  maturityDate: string;
  assetHash: string;
  poolStatus: PoolStatusValue;
  oracleAddress: string;
  trancheFactory: string;
  issuanceContract: string;
  waterfallEngine: string;
  initialised: boolean;
}

// ─── Compliance types ─────────────────────────────────────────────────────────

export const AccreditationLevel = {
  RETAIL: 1,
  PROFESSIONAL: 2,
  INSTITUTIONAL: 3,
  QUALIFIED_PURCHASER: 4,
} as const;

export interface InvestorRecord {
  accreditationLevel: number;
  jurisdiction: string;
  holdingPeriodEnd: string;
  didObjectId: string;
  active: boolean;
}

export interface TransferCheckResult {
  allowed: boolean;
  reason: string;
}

// ─── Tranche types ────────────────────────────────────────────────────────────

export const TrancheType = {
  SENIOR: 0,
  MEZZ: 1,
  JUNIOR: 2,
} as const;

export type TrancheTypeValue = (typeof TrancheType)[keyof typeof TrancheType];

export interface TrancheInfo {
  trancheType: TrancheTypeValue;
  supplyCap: string;
  amountMinted: string;
  remainingCapacity: string;
  mintingActive: boolean;
}

export interface TrancheRegistry {
  id: string;
  seniorSupplyCap: string;
  mezzSupplyCap: string;
  juniorSupplyCap: string;
  seniorMinted: string;
  mezzMinted: string;
  juniorMinted: string;
  mintingEnabled: boolean;
  tranchesCreated: boolean;
  issuanceContract: string;
  bootstrapped: boolean;
}

// ─── Issuance types ───────────────────────────────────────────────────────────

export interface IssuanceState {
  id: string;
  pricePerUnitSenior: string;
  pricePerUnitMezz: string;
  pricePerUnitJunior: string;
  saleStart: string;
  saleEnd: string;
  totalRaised: string;
  issuanceActive: boolean;
  issuanceEnded: boolean;
  succeeded: boolean;
  vaultBalance: string;
}

// ─── Vault types ──────────────────────────────────────────────────────────────

export interface VaultBalance {
  id: string;
  balance: string;
  totalDeposited: string;
  totalDistributed: string;
}

// ─── Waterfall types ──────────────────────────────────────────────────────────

export const WaterfallMode = {
  NORMAL: 0,
  TURBO: 1,
  DEFAULT: 2,
} as const;

export const PaymentFrequency = {
  MONTHLY: 0,
  QUARTERLY: 1,
} as const;

export interface WaterfallState {
  id: string;
  seniorOutstanding: string;
  mezzOutstanding: string;
  juniorOutstanding: string;
  seniorAccruedInterest: string;
  mezzAccruedInterest: string;
  juniorAccruedInterest: string;
  seniorRateBps: number;
  mezzRateBps: number;
  juniorRateBps: number;
  reserveAccount: string;
  pendingFunds: string;
  lastDistributionMs: string;
  paymentFrequency: number;
  waterfallStatus: number;
}

export interface DistributionResult {
  toSenior: string;
  toMezz: string;
  toJunior: string;
  toReserve: string;
}

// ─── API response wrapper ─────────────────────────────────────────────────────

export interface ApiResponse<T> {
  success: boolean;
  data?: T;
  error?: string;
  txDigest?: string;
  network: Network;
}

export interface TxResult {
  txDigest: string;
  status: 'success' | 'failure';
  gasUsed?: string;
  effects?: unknown;
}
