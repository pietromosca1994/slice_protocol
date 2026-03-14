/// Shared error codes used across all securitization contracts.
/// Centralising error constants avoids magic numbers and makes
/// on-chain abort codes human-readable during debugging.
module securitization::errors {

    // ── PoolContract errors ───────────────────────────────────────────────────
    /// Pool has already been initialised
    const EAlreadyInitialised: u64        = 1000;
    /// Pool has not yet been initialised
    const ENotInitialised: u64            = 1001;
    /// Caller is not the pool admin
    const ENotAdmin: u64                  = 1002;
    /// Caller is not the authorised oracle
    const ENotOracle: u64                 = 1003;
    /// Pool is not in the required status for this operation
    const EInvalidPoolStatus: u64         = 1004;
    /// Maturity date is in the past
    const EMaturityInPast: u64            = 1005;
    /// Pool value cannot be zero
    const EZeroPoolValue: u64             = 1006;
    /// Asset hash cannot be empty
    const EEmptyAssetHash: u64            = 1007;
    /// Downstream contract addresses have not been set
    const EContractsNotLinked: u64        = 1008;
    /// Oracle timestamp is in the future
    const EFutureTimestamp: u64           = 1009;

    // ── TrancheFactory errors ─────────────────────────────────────────────────
    /// Tranches have already been created for this factory
    const ETranchesAlreadyCreated: u64    = 2000;
    /// Tranches have not yet been created
    const ETranchesNotCreated: u64        = 2001;
    /// Minting has been permanently disabled
    const EMintingDisabled: u64           = 2002;
    /// Requested mint would exceed the tranche supply cap
    const ESupplyCapExceeded: u64         = 2003;
    /// Caller is not the authorised issuance contract
    const ENotIssuanceContract: u64       = 2004;
    /// Supply cap cannot be zero
    const EZeroSupplyCap: u64             = 2005;
    /// Cannot melt more tokens than are currently minted
    const EInsufficientMinted: u64        = 2006;
    /// Unknown tranche type provided
    const EUnknownTrancheType: u64        = 2007;

    // ── IssuanceContract errors ───────────────────────────────────────────────
    /// Issuance window is not currently active
    const EIssuanceNotActive: u64         = 3000;
    /// Issuance window is already active
    const EIssuanceAlreadyActive: u64     = 3001;
    /// Sale end must be after sale start
    const EInvalidSaleWindow: u64         = 3002;
    /// Investment amount results in zero tokens
    const EZeroTokensCalculated: u64      = 3003;
    /// Price per unit cannot be zero
    const EZeroPricePerUnit: u64          = 3004;
    /// No subscription found for this investor
    const ENoSubscription: u64            = 3005;
    /// Refund not permitted — issuance succeeded
    const ERefundNotPermitted: u64        = 3006;
    /// Caller is not a verified investor
    const EInvestorNotVerified: u64       = 3007;
    /// Issuance has already ended
    const EIssuanceAlreadyEnded: u64      = 3008;
    /// Pool is not in Active status
    const EPoolNotActive: u64             = 3009;

    // ── WaterfallEngine errors ────────────────────────────────────────────────
    /// No distributable funds available
    const ENoFundsAvailable: u64          = 4000;
    /// Waterfall is already in the requested mode
    const EAlreadyInMode: u64             = 4001;
    /// Turbo mode can only be activated when waterfall is Normal
    const ETurboRequiresNormal: u64       = 4002;
    /// Default mode can only be set by pool or admin
    const ENotPoolOrAdmin: u64            = 4003;
    /// Interest accrual: no time has elapsed since last accrual
    const ENoTimeElapsed: u64             = 4004;

    // ── Public accessors ──────────────────────────────────────────────────────
    public fun already_initialised(): u64        { EAlreadyInitialised }
    public fun not_initialised(): u64            { ENotInitialised }
    public fun not_admin(): u64                  { ENotAdmin }
    public fun not_oracle(): u64                 { ENotOracle }
    public fun invalid_pool_status(): u64        { EInvalidPoolStatus }
    public fun maturity_in_past(): u64           { EMaturityInPast }
    public fun zero_pool_value(): u64            { EZeroPoolValue }
    public fun empty_asset_hash(): u64           { EEmptyAssetHash }
    public fun contracts_not_linked(): u64       { EContractsNotLinked }
    public fun future_timestamp(): u64           { EFutureTimestamp }

    public fun tranches_already_created(): u64   { ETranchesAlreadyCreated }
    public fun tranches_not_created(): u64       { ETranchesNotCreated }
    public fun minting_disabled(): u64           { EMintingDisabled }
    public fun supply_cap_exceeded(): u64        { ESupplyCapExceeded }
    public fun not_issuance_contract(): u64      { ENotIssuanceContract }
    public fun zero_supply_cap(): u64            { EZeroSupplyCap }
    public fun insufficient_minted(): u64        { EInsufficientMinted }
    public fun unknown_tranche_type(): u64       { EUnknownTrancheType }

    public fun issuance_not_active(): u64        { EIssuanceNotActive }
    public fun issuance_already_active(): u64    { EIssuanceAlreadyActive }
    public fun invalid_sale_window(): u64        { EInvalidSaleWindow }
    public fun zero_tokens_calculated(): u64     { EZeroTokensCalculated }
    public fun zero_price_per_unit(): u64        { EZeroPricePerUnit }
    public fun no_subscription(): u64            { ENoSubscription }
    public fun refund_not_permitted(): u64       { ERefundNotPermitted }
    public fun investor_not_verified(): u64      { EInvestorNotVerified }
    public fun issuance_already_ended(): u64     { EIssuanceAlreadyEnded }
    public fun pool_not_active(): u64            { EPoolNotActive }

    public fun no_funds_available(): u64         { ENoFundsAvailable }
    public fun already_in_mode(): u64            { EAlreadyInMode }
    public fun turbo_requires_normal(): u64      { ETurboRequiresNormal }
    public fun not_pool_or_admin(): u64          { ENotPoolOrAdmin }
    public fun no_time_elapsed(): u64            { ENoTimeElapsed }

}
