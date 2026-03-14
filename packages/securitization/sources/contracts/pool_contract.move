/// # PoolContract
///
/// Foundational layer of the IOTA Securitization Protocol.
///
/// ## Responsibilities
/// - Creating new asset pools on-demand via `create_pool` (one per call)
/// - Registering each new pool into the shared `SPVRegistry` (spv package)
/// - Binding the on-chain structure to off-chain legal documents via `asset_hash`
/// - Managing the pool lifecycle: Created → Active → Matured | Defaulted
/// - Accepting performance data from an authorised oracle address
/// - Acting as the root authority object that downstream contracts reference
///
/// ## Package split design
/// The protocol is split across two packages:
///
/// ```
/// spv (deployed once, permanent)
/// ├── compliance_registry   — KYC/AML whitelist
/// ├── payment_vault         — stablecoin custody
/// ├── spv_registry          — pool enumeration index
/// ├── errors                — shared error codes for the spv layer
/// └── events                — shared events for the spv layer
///
/// securitization (deployed once; each pool is an object, not a deployment)
/// ├── pool_contract         — pool lifecycle  ← this module
/// ├── tranche_factory       — token minting
/// ├── issuance_contract     — subscription window
/// ├── waterfall_engine      — cash-flow distribution
/// ├── errors                — error codes for the securitization layer
/// └── events                — events for the securitization layer
/// ```
///
/// `pool_contract` is the bridge: it imports `spv::spv_registry` to register
/// each new pool, while all other logic stays within the securitization package.
///
/// ## Multi-pool design
/// - `init` no longer creates a `PoolState`; it only mints the `AdminCap`.
/// - `create_pool` creates and shares a fresh `PoolState` per call, then
///   immediately registers its object ID in the `spv::SPVRegistry`.
/// - All downstream securitization contracts store `pool_obj_id: ID` to
///   identify which pool they belong to, enabling UI enumeration via the
///   registry without re-deploying.
///
/// ## IOTA Move design notes
/// - Each `PoolState` is a separate shared object; any participant can read it.
/// - `AdminCap` gates privileged lifecycle operations across all pools.
/// - `OracleCap` is minted per-pool in `initialise_pool` and carries a
///   `pool_obj_id` field so it cannot be used against the wrong pool.
#[allow(duplicate_alias)]
module securitization::pool_contract {
    use iota::clock::{Self, Clock};
    use iota::object::{Self, UID, ID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    // Cross-package import: SPVRegistry lives in the spv package
    use spv::spv_registry::{Self, SPVRegistry};
    use securitization::errors;
    use securitization::events;

    // ─── Status constants ─────────────────────────────────────────────────────
    const STATUS_CREATED:   u8 = 0;
    const STATUS_ACTIVE:    u8 = 1;
    const STATUS_DEFAULTED: u8 = 2;
    const STATUS_MATURED:   u8 = 3;

    // ─── Capability objects ───────────────────────────────────────────────────

    /// Held by the protocol administrator. Controls privileged calls across
    /// every pool in the securitization package.
    public struct AdminCap has key, store { id: UID }

    /// Minted per-pool in `initialise_pool`. Scoped to a single pool via
    /// `pool_obj_id` so it cannot act on a different pool's state.
    public struct OracleCap has key, store {
        id:          UID,
        pool_obj_id: ID,
    }

    // ─── Core shared state ────────────────────────────────────────────────────

    /// One shared object per pool. Created by `create_pool` and never destroyed.
    public struct PoolState has key {
        id:                            UID,
        /// Self-referential object ID stored for cross-contract checks and events.
        pool_obj_id:                   ID,
        pool_id:                       vector<u8>,
        originator:                    address,
        spv:                           address,
        total_pool_value:              u64,
        current_outstanding_principal: u64,
        interest_rate:                 u32,        // basis points
        maturity_date:                 u64,        // UNIX timestamp (ms)
        asset_hash:                    vector<u8>, // SHA-256 of off-chain docs
        pool_status:                   u8,
        oracle_address:                address,
        // Addresses of linked downstream contracts (set via set_contracts)
        tranche_factory:               address,
        issuance_contract:             address,
        waterfall_engine:              address,
        initialised:                   bool,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Called once by the Move framework when the securitization package is
    /// published. Mints the AdminCap; individual pools are created on-demand
    /// via `create_pool`.
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Pool creation ────────────────────────────────────────────────────────

    /// Create a new pool, share it as an independent object, and register its
    /// object ID in the `spv::SPVRegistry`.
    ///
    /// The SPVRegistry is the single on-chain source of truth for pool
    /// enumeration. The UI calls `spv_registry::all_pool_ids` or
    /// `spv_registry::pools_for_spv` to list pools without any off-chain index.
    ///
    /// Lifecycle after this call:
    ///   1. `set_contracts`   — link tranche_factory, issuance_contract, waterfall_engine
    ///   2. `initialise_pool` — finalise parameters, mint OracleCap
    ///   3. `activate_pool`   — open the pool for business
    ///
    /// # Parameters
    /// - `spv_registry`     Shared `SPVRegistry` from the spv package
    /// - `spv`              SPV wallet address that owns this pool
    /// - `pool_id`          Unique UTF-8 pool identifier (e.g. b"POOL-2025-001")
    /// - `originator`       Originator wallet address
    /// - `total_pool_value` Total nominal value in stablecoin base units
    /// - `interest_rate`    Blended annual rate in basis points
    /// - `maturity_date`    Pool maturity as UNIX timestamp in milliseconds
    /// - `asset_hash`       SHA-256 of the off-chain asset register (32 bytes)
    /// - `oracle_address`   Address that will receive the per-pool `OracleCap`
    public entry fun create_pool(
        _cap:             &AdminCap,
        spv_registry:     &mut SPVRegistry,
        spv:              address,
        pool_id:          vector<u8>,
        originator:       address,
        total_pool_value: u64,
        interest_rate:    u32,
        maturity_date:    u64,
        asset_hash:       vector<u8>,
        oracle_address:   address,
        clock:            &Clock,
        ctx:              &mut TxContext,
    ) {
        assert!(pool_id    != vector[],  errors::empty_asset_hash());
        assert!(originator != @0x0,      errors::not_admin());
        assert!(spv        != @0x0,      errors::not_admin());
        assert!(total_pool_value > 0,    errors::zero_pool_value());
        assert!(asset_hash != vector[],  errors::empty_asset_hash());
        assert!(oracle_address != @0x0,  errors::not_oracle());
        assert!(
            maturity_date > clock::timestamp_ms(clock),
            errors::maturity_in_past()
        );

        // Allocate the UID first so we can capture the object ID before sharing.
        let uid         = object::new(ctx);
        let pool_obj_id = object::uid_to_inner(&uid);

        let state = PoolState {
            id:                            uid,
            pool_obj_id,
            pool_id,
            originator,
            spv,
            total_pool_value,
            current_outstanding_principal: total_pool_value,
            interest_rate,
            maturity_date,
            asset_hash,
            pool_status:                   STATUS_CREATED,
            oracle_address,
            tranche_factory:               @0x0,
            issuance_contract:             @0x0,
            waterfall_engine:              @0x0,
            initialised:                   false,
        };

        // Register in the spv package registry BEFORE sharing so the ID is
        // captured while we still hold the value. The registry call emits a
        // PoolRegistered event defined in spv::events.
        spv_registry::register_pool(spv_registry, pool_obj_id, spv, clock, ctx);

        // Share the PoolState — after this point we no longer own the object.
        transfer::share_object(state);

        // Also emit a pool-creation event in the securitization event stream
        // so indexers consuming this package's events are notified too.
        events::emit_pool_initialised(
            pool_id,
            originator,
            spv,
            total_pool_value,
            clock::timestamp_ms(clock),
        );
    }

    // ─── Admin: link downstream contracts ────────────────────────────────────

    /// Set addresses of the three downstream contracts for a specific pool.
    /// Must be called before `initialise_pool`.
    ///
    /// # Parameters
    /// - `tranche_factory`    Address of the pool's `TrancheRegistry` object
    /// - `issuance_contract`  Address of the pool's `IssuanceState` object
    /// - `waterfall_engine`   Address of the pool's `WaterfallState` object
    /// - `oracle_address`     Address that will hold the `OracleCap`
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

    /// Finalise pool parameters and mint the per-pool `OracleCap`.
    ///
    /// Separated from `create_pool` so downstream contract addresses (which
    /// require the pool object ID to be known) can be linked first via
    /// `set_contracts`, and only then is the `OracleCap` minted and sent.
    ///
    /// Callable once per pool by the admin after `set_contracts`.
    public entry fun initialise_pool(
        _cap:  &AdminCap,
        state: &mut PoolState,
        clock: &Clock,
        ctx:   &mut TxContext,
    ) {
        assert!(!state.initialised,              errors::already_initialised());
        assert!(state.tranche_factory   != @0x0, errors::contracts_not_linked());
        assert!(state.issuance_contract != @0x0, errors::contracts_not_linked());
        assert!(state.waterfall_engine  != @0x0, errors::contracts_not_linked());

        state.initialised = true;

        // Mint a pool-scoped OracleCap — the pool_obj_id binding prevents
        // this cap from being used against any other pool.
        let oracle_cap = OracleCap {
            id:          object::new(ctx),
            pool_obj_id: state.pool_obj_id,
        };
        transfer::transfer(oracle_cap, state.oracle_address);

        events::emit_pool_initialised(
            state.pool_id,
            state.originator,
            state.spv,
            state.total_pool_value,
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
        assert!(state.initialised,                   errors::not_initialised());
        assert!(state.pool_status == STATUS_CREATED, errors::invalid_pool_status());
        assert!(state.tranche_factory   != @0x0,     errors::contracts_not_linked());
        assert!(state.issuance_contract != @0x0,     errors::contracts_not_linked());
        assert!(state.waterfall_engine  != @0x0,     errors::contracts_not_linked());

        state.pool_status = STATUS_ACTIVE;
        events::emit_pool_activated(state.pool_id, clock::timestamp_ms(clock));
    }

    /// Ingest updated repayment data from the oracle.
    /// Pool must be Active. Auto-matures if principal reaches zero past maturity.
    ///
    /// # Parameters
    /// - `new_outstanding_principal` Updated total unpaid principal
    /// - `oracle_timestamp`          Observation timestamp (ms) from oracle feed
    public entry fun update_performance_data(
        cap:                       &OracleCap,
        state:                     &mut PoolState,
        new_outstanding_principal: u64,
        oracle_timestamp:          u64,
        clock:                     &Clock,
    ) {
        assert!(cap.pool_obj_id == state.pool_obj_id, errors::not_oracle());
        assert!(state.pool_status == STATUS_ACTIVE,    errors::invalid_pool_status());
        let now = clock::timestamp_ms(clock);
        assert!(oracle_timestamp <= now,               errors::future_timestamp());

        state.current_outstanding_principal = new_outstanding_principal;
        events::emit_performance_data_updated(new_outstanding_principal, oracle_timestamp, now);

        // Auto-mature when fully repaid and past the maturity date
        if (now >= state.maturity_date && new_outstanding_principal == 0) {
            state.pool_status = STATUS_MATURED;
            events::emit_pool_closed(state.pool_id, now);
        };
    }

    /// Mark the pool as Defaulted — callable by the pool's oracle.
    public entry fun mark_default_oracle(
        cap:   &OracleCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(cap.pool_obj_id == state.pool_obj_id, errors::not_oracle());
        assert!(state.pool_status == STATUS_ACTIVE,    errors::invalid_pool_status());
        state.pool_status = STATUS_DEFAULTED;
        events::emit_pool_defaulted(state.pool_id, clock::timestamp_ms(clock));
    }

    /// Mark the pool as Defaulted — callable by the protocol admin.
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

    public fun pool_obj_id(s: &PoolState): ID            { s.pool_obj_id }
    public fun pool_id(s: &PoolState): vector<u8>        { s.pool_id }
    public fun originator(s: &PoolState): address        { s.originator }
    public fun spv(s: &PoolState): address               { s.spv }
    public fun total_pool_value(s: &PoolState): u64      { s.total_pool_value }
    public fun outstanding_principal(s: &PoolState): u64 { s.current_outstanding_principal }
    public fun interest_rate(s: &PoolState): u32         { s.interest_rate }
    public fun maturity_date(s: &PoolState): u64         { s.maturity_date }
    public fun asset_hash(s: &PoolState): vector<u8>     { s.asset_hash }
    public fun pool_status(s: &PoolState): u8            { s.pool_status }
    public fun oracle_address(s: &PoolState): address    { s.oracle_address }
    public fun is_active(s: &PoolState): bool            { s.pool_status == STATUS_ACTIVE }
    public fun is_defaulted(s: &PoolState): bool         { s.pool_status == STATUS_DEFAULTED }
    public fun is_matured(s: &PoolState): bool           { s.pool_status == STATUS_MATURED }
    public fun status_created(): u8                      { STATUS_CREATED }
    public fun status_active(): u8                       { STATUS_ACTIVE }
    public fun status_defaulted(): u8                    { STATUS_DEFAULTED }
    public fun status_matured(): u8                      { STATUS_MATURED }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
