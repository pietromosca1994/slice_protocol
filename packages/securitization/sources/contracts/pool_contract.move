/// # PoolContract
///
/// Foundational layer of the IOTA Securitization Protocol.
///
/// ## Responsibilities
/// - Registering the asset pool on-chain with all parameters
/// - Binding the on-chain structure to off-chain legal documents via `asset_hash`
/// - Managing the pool lifecycle: Created → Active → Matured | Defaulted
/// - Accepting performance data from an authorised oracle address
/// - Acting as the root authority object that downstream contracts reference
///
/// ## IOTA Move design notes
/// - The `PoolState` struct is a shared object (`iota::transfer::share_object`)
///   so all participants can read it without owning it.
/// - An `AdminCap` capability object controls privileged operations; it is
///   transferred to the deployer at publish time.
/// - An `OracleCap` capability is minted at `initialise` time and sent to the
///   oracle address, enabling oracle-only mutations.
#[allow(duplicate_alias)]
module securitization::pool_contract {
    use iota::clock::{Self, Clock};
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use securitization::errors;
    use securitization::events;

    // ─── Status constants ─────────────────────────────────────────────────────
    const STATUS_CREATED:  u8 = 0;
    const STATUS_ACTIVE:   u8 = 1;
    const STATUS_DEFAULTED: u8 = 2;
    const STATUS_MATURED:  u8 = 3;

    // ─── Capability objects ───────────────────────────────────────────────────

    /// Held by the protocol administrator. Required for all privileged calls.
    public struct AdminCap has key, store { id: UID }

    /// Held by the trusted oracle. Required for `update_performance_data` and
    /// can also trigger `mark_default`.
    public struct OracleCap has key, store { id: UID }

    // ─── Core shared state ────────────────────────────────────────────────────

    /// Shared object representing the entire pool. Readable by any participant.
    public struct PoolState has key {
        id:                          UID,
        pool_id:                     vector<u8>,
        originator:                  address,
        spv:                         address,
        total_pool_value:            u64,
        current_outstanding_principal: u64,
        interest_rate:               u32,   // in basis points
        maturity_date:               u64,   // UNIX timestamp (ms)
        asset_hash:                  vector<u8>, // SHA-256 of off-chain docs
        pool_status:                 u8,
        oracle_address:              address,
        // Addresses of linked downstream contracts (set via set_contracts)
        tranche_factory:             address,
        issuance_contract:           address,
        waterfall_engine:            address,
        initialised:                 bool,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Called automatically by the Move framework when the package is published.
    /// Creates the shared PoolState (empty) and hands the AdminCap to the publisher.
    fun init(ctx: &mut TxContext) {
        let state = PoolState {
            id:                          object::new(ctx),
            pool_id:                     vector[],
            originator:                  @0x0,
            spv:                         @0x0,
            total_pool_value:            0,
            current_outstanding_principal: 0,
            interest_rate:               0,
            maturity_date:               0,
            asset_hash:                  vector[],
            pool_status:                 STATUS_CREATED,
            oracle_address:              @0x0,
            tranche_factory:             @0x0,
            issuance_contract:           @0x0,
            waterfall_engine:            @0x0,
            initialised:                 false,
        };
        transfer::share_object(state);

        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Admin: link downstream contracts ─────────────────────────────────────

    /// Set addresses of all downstream contracts.
    /// Must be called before `activate_pool`.
    public entry fun set_contracts(
        _cap:              &AdminCap,
        state:             &mut PoolState,
        tranche_factory:   address,
        issuance_contract: address,
        waterfall_engine:  address,
        oracle_address:    address,
    ) {
        assert!(tranche_factory   != @0x0, errors::contracts_not_linked());
        assert!(issuance_contract != @0x0, errors::contracts_not_linked());
        assert!(waterfall_engine  != @0x0, errors::contracts_not_linked());
        assert!(oracle_address    != @0x0, errors::not_oracle());

        state.tranche_factory   = tranche_factory;
        state.issuance_contract = issuance_contract;
        state.waterfall_engine  = waterfall_engine;
        state.oracle_address    = oracle_address;
    }

    // ─── Core lifecycle functions ─────────────────────────────────────────────

    /// Initialise the pool with all foundational parameters.
    /// Callable once by the admin. Mints and sends an OracleCap to the oracle.
    ///
    /// # Parameters
    /// - `pool_id`         Unique UTF-8 pool identifier
    /// - `originator`      Originator wallet address
    /// - `spv`             SPV wallet address
    /// - `total_pool_value` Total nominal value in stablecoin base units
    /// - `interest_rate`   Blended annual rate in basis points
    /// - `maturity_date`   Pool maturity as UNIX timestamp in milliseconds
    /// - `asset_hash`      SHA-256 of the off-chain asset register (32 bytes)
    public entry fun initialise_pool(
        cap:              &AdminCap,
        state:            &mut PoolState,
        pool_id:          vector<u8>,
        originator:       address,
        spv:              address,
        total_pool_value: u64,
        interest_rate:    u32,
        maturity_date:    u64,
        asset_hash:       vector<u8>,
        clock:            &Clock,
        ctx:              &mut TxContext,
    ) {
        let _ = cap;
        assert!(!state.initialised,              errors::already_initialised());
        assert!(pool_id != vector[],             errors::empty_asset_hash());
        assert!(originator != @0x0,              errors::not_admin());
        assert!(spv != @0x0,                     errors::not_admin());
        assert!(total_pool_value > 0,            errors::zero_pool_value());
        assert!(asset_hash != vector[],          errors::empty_asset_hash());
        assert!(
            maturity_date > clock::timestamp_ms(clock),
            errors::maturity_in_past()
        );

        state.pool_id                     = pool_id;
        state.originator                  = originator;
        state.spv                         = spv;
        state.total_pool_value            = total_pool_value;
        state.current_outstanding_principal = total_pool_value;
        state.interest_rate               = interest_rate;
        state.maturity_date               = maturity_date;
        state.asset_hash                  = asset_hash;
        state.pool_status                 = STATUS_CREATED;
        state.initialised                 = true;

        // Mint OracleCap and send to oracle_address (must already be set)
        let oracle_cap = OracleCap { id: object::new(ctx) };
        transfer::transfer(oracle_cap, state.oracle_address);

        events::emit_pool_initialised(
            state.pool_id,
            originator,
            spv,
            total_pool_value,
            clock::timestamp_ms(clock),
        );
    }

    /// Transition pool status from Created → Active.
    /// All downstream contract addresses must be set before calling.
    public entry fun activate_pool(
        _cap:  &AdminCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(state.initialised,              errors::not_initialised());
        assert!(state.pool_status == STATUS_CREATED, errors::invalid_pool_status());
        assert!(state.tranche_factory   != @0x0, errors::contracts_not_linked());
        assert!(state.issuance_contract != @0x0, errors::contracts_not_linked());
        assert!(state.waterfall_engine  != @0x0, errors::contracts_not_linked());

        state.pool_status = STATUS_ACTIVE;
        events::emit_pool_activated(state.pool_id, clock::timestamp_ms(clock));
    }

    /// Ingest updated repayment data from the oracle.
    /// Pool must be Active. Auto-matures if principal is zero and past maturity.
    ///
    /// # Parameters
    /// - `new_outstanding_principal` Updated total unpaid principal
    /// - `oracle_timestamp`          Observation timestamp (ms) from the oracle feed
    public entry fun update_performance_data(
        _cap:                      &OracleCap,
        state:                     &mut PoolState,
        new_outstanding_principal: u64,
        oracle_timestamp:          u64,
        clock:                     &Clock,
    ) {
        assert!(state.pool_status == STATUS_ACTIVE, errors::invalid_pool_status());
        let now = clock::timestamp_ms(clock);
        assert!(oracle_timestamp <= now, errors::future_timestamp());

        state.current_outstanding_principal = new_outstanding_principal;
        events::emit_performance_data_updated(new_outstanding_principal, oracle_timestamp, now);

        // Auto-mature when fully repaid past the maturity date
        if (now >= state.maturity_date && new_outstanding_principal == 0) {
            state.pool_status = STATUS_MATURED;
            events::emit_pool_closed(state.pool_id, now);
        };
    }

    /// Mark the pool as Defaulted. Callable by holder of OracleCap or AdminCap.
    /// In Move we implement two entry points — one per cap — rather than an
    /// "onlyAdminOrOracle" modifier as in Solidity.
    public entry fun mark_default_oracle(
        _cap:  &OracleCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(state.pool_status == STATUS_ACTIVE, errors::invalid_pool_status());
        state.pool_status = STATUS_DEFAULTED;
        events::emit_pool_defaulted(state.pool_id, clock::timestamp_ms(clock));
    }

    public entry fun mark_default_admin(
        _cap:  &AdminCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(state.pool_status == STATUS_ACTIVE, errors::invalid_pool_status());
        state.pool_status = STATUS_DEFAULTED;
        events::emit_pool_defaulted(state.pool_id, clock::timestamp_ms(clock));
    }

    /// Finalise the pool upon maturity or full repayment.
    /// Callable by admin from either Active or Defaulted status.
    public entry fun close_pool(
        _cap:  &AdminCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(
            state.pool_status == STATUS_ACTIVE || state.pool_status == STATUS_DEFAULTED,
            errors::invalid_pool_status()
        );
        state.pool_status = STATUS_MATURED;
        events::emit_pool_closed(state.pool_id, clock::timestamp_ms(clock));
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun pool_id(s: &PoolState): vector<u8>  { s.pool_id }
    public fun originator(s: &PoolState): address  { s.originator }
    public fun spv(s: &PoolState): address         { s.spv }
    public fun total_pool_value(s: &PoolState): u64 { s.total_pool_value }
    public fun outstanding_principal(s: &PoolState): u64 { s.current_outstanding_principal }
    public fun interest_rate(s: &PoolState): u32   { s.interest_rate }
    public fun maturity_date(s: &PoolState): u64   { s.maturity_date }
    public fun asset_hash(s: &PoolState): vector<u8> { s.asset_hash }
    public fun pool_status(s: &PoolState): u8      { s.pool_status }
    public fun oracle_address(s: &PoolState): address { s.oracle_address }
    public fun is_active(s: &PoolState): bool      { s.pool_status == STATUS_ACTIVE }
    public fun is_defaulted(s: &PoolState): bool   { s.pool_status == STATUS_DEFAULTED }
    public fun is_matured(s: &PoolState): bool     { s.pool_status == STATUS_MATURED }
    public fun status_created(): u8    { STATUS_CREATED }
    public fun status_active(): u8     { STATUS_ACTIVE }
    public fun status_defaulted(): u8  { STATUS_DEFAULTED }
    public fun status_matured(): u8    { STATUS_MATURED }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
