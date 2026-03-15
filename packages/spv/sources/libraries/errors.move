/// Shared error codes used across all securitization contracts.
/// Centralising error constants avoids magic numbers and makes
/// on-chain abort codes human-readable during debugging.
module spv::errors {
    // ── ComplianceRegistry errors ─────────────────────────────────────────────
    /// Investor is not on the whitelist
    const EInvestorNotWhitelisted: u64     = 5000;
    /// Investor is already registered
    const EInvestorAlreadyExists: u64      = 5001;
    /// Accreditation level is invalid (must be 1-4)
    const EInvalidAccreditationLevel: u64  = 5002;
    /// Jurisdiction string cannot be empty
    const EEmptyJurisdiction: u64          = 5003;
    /// Transfer is blocked by compliance rules
    const ETransferBlocked: u64            = 5004;
    /// Investor is still within their mandatory holding period
    const EHoldingPeriodNotElapsed: u64    = 5005;
    /// Caller is not the compliance admin
    const ENotComplianceAdmin: u64         = 5006;

    // ── PaymentVault errors ───────────────────────────────────────────────────
    /// Caller is not an authorised depositor
    const ENotAuthorisedDepositor: u64     = 6000;
    /// Vault has insufficient balance for this release
    const EInsufficientVaultBalance: u64   = 6001;
    /// Release amount cannot be zero
    const EZeroReleaseAmount: u64          = 6002;
    /// Deposit amount cannot be zero
    const EZeroDepositAmount: u64          = 6003;
    /// Caller is not the vault admin
    const ENotVaultAdmin: u64              = 6004;
    /// Depositor is already authorised
    const EDepositorAlreadyAuthorised: u64 = 6005;
    /// Coin type does not match vault's stablecoin
    const EWrongCoinType: u64              = 6006;

    // ── SPVRegistry errors ────────────────────────────────────────────────────
    /// Pool object ID is already registered in the SPVRegistry
    const EPoolAlreadyRegistered: u64      = 7000;
    /// Pool object ID is not present in the SPVRegistry
    const EPoolNotRegistered: u64          = 7001;

    // ── Public accessors ──────────────────────────────────────────────────────
    public fun investor_not_whitelisted(): u64    { EInvestorNotWhitelisted }
    public fun investor_already_exists(): u64     { EInvestorAlreadyExists }
    public fun invalid_accreditation_level(): u64 { EInvalidAccreditationLevel }
    public fun empty_jurisdiction(): u64          { EEmptyJurisdiction }
    public fun transfer_blocked(): u64            { ETransferBlocked }
    public fun holding_period_not_elapsed(): u64  { EHoldingPeriodNotElapsed }
    public fun not_compliance_admin(): u64        { ENotComplianceAdmin }

    public fun not_authorised_depositor(): u64    { ENotAuthorisedDepositor }
    public fun insufficient_vault_balance(): u64  { EInsufficientVaultBalance }
    public fun zero_release_amount(): u64         { EZeroReleaseAmount }
    public fun zero_deposit_amount(): u64         { EZeroDepositAmount }
    public fun not_vault_admin(): u64             { ENotVaultAdmin }
    public fun depositor_already_authorised(): u64{ EDepositorAlreadyAuthorised }
    public fun wrong_coin_type(): u64             { EWrongCoinType }

    public fun pool_already_registered(): u64     { EPoolAlreadyRegistered }
    public fun pool_not_registered(): u64         { EPoolNotRegistered }
}
