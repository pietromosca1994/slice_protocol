/// # PoolContract
///
/// Foundational layer of the IOTA Securitization Protocol.
///
/// ## API change in this version
/// `PoolState` now stores the **object IDs** of its three downstream shared
/// objects alongside their deployer addresses:
///
///   - `tranche_factory_obj`   ID  — object ID of the TrancheRegistry
///   - `issuance_contract_obj` ID  — object ID of the IssuanceState
///   - `waterfall_engine_obj`  ID  — object ID of the WaterfallState
///
/// This makes the on-chain data fully self-contained: given only the
/// SPVRegistry object ID, the API can traverse to every linked object
/// without any off-chain configuration. The existing `address` fields
/// (`tranche_factory`, `issuance_contract`, `waterfall_engine`) are kept
/// because `set_contracts` already uses them as deployer address references;
/// the new `_obj` fields carry the actual shared-object IDs set by a
/// separate call to `set_contract_objects`.
#[allow(duplicate_alias)]
module securitization::pool_contract {
    use iota::clock::{Self, Clock};
    use iota::object::{Self, UID, ID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use spv::spv_registry::{Self, SPVRegistry};
    use securitization::errors;
    use securitization::events;

    // ─── Status constants ─────────────────────────────────────────────────────
    const STATUS_CREATED:   u8 = 0;
    const STATUS_ACTIVE:    u8 = 1;
    const STATUS_DEFAULTED: u8 = 2;
    const STATUS_MATURED:   u8 = 3;

    // ─── Capabilities ─────────────────────────────────────────────────────────

    public struct AdminCap has key, store { id: UID }

    public struct OracleCap has key, store {
        id:          UID,
        pool_obj_id: ID,
    }

    // ─── Core shared state ────────────────────────────────────────────────────

    public struct PoolState has key {
        id:                            UID,
        pool_obj_id:                   ID,
        pool_id:                       vector<u8>,
        originator:                    address,
        spv:                           address,
        total_pool_value:              u64,
        current_outstanding_principal: u64,
        interest_rate:                 u32,
        maturity_date:                 u64,
        asset_hash:                    vector<u8>,
        pool_status:                   u8,
        oracle_address:                address,
        // Deployer addresses (set via set_contracts)
        tranche_factory:               address,
        issuance_contract:             address,
        waterfall_engine:              address,
        // Shared object IDs of the linked contracts (set via set_contract_objects)
        // These are what the off-chain API uses to fetch downstream state.
        tranche_factory_obj:           ID,
        issuance_contract_obj:         ID,
        waterfall_engine_obj:          ID,
        payment_vault_obj:             ID,
        initialised:                   bool,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Pool creation ────────────────────────────────────────────────────────

    public entry fun create_pool(
        _cap:                        &AdminCap,
        spv_registry:                &mut SPVRegistry,
        spv:                         address,
        pool_id:                     vector<u8>,
        originator:                  address,
        total_pool_value:            u64,
        interest_rate:               u32,
        maturity_date:               u64,
        asset_hash:                  vector<u8>,
        oracle_address:              address,
        securitization_package_id:   address,
        clock:                       &Clock,
        ctx:                         &mut TxContext,
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

        let uid         = object::new(ctx);
        let pool_obj_id = object::uid_to_inner(&uid);

        // Sentinel zero ID — filled in by set_contract_objects
        let zero_id = object::id_from_address(@0x0);

        let state = PoolState {
            id: uid,
            pool_obj_id,
            pool_id,
            originator,
            spv,
            total_pool_value,
            current_outstanding_principal: total_pool_value,
            interest_rate,
            maturity_date,
            asset_hash,
            pool_status:          STATUS_CREATED,
            oracle_address,
            tranche_factory:      @0x0,
            issuance_contract:    @0x0,
            waterfall_engine:     @0x0,
            tranche_factory_obj:   zero_id,
            issuance_contract_obj: zero_id,
            waterfall_engine_obj:  zero_id,
            payment_vault_obj:     zero_id,
            initialised:           false,
        };

        spv_registry::register_pool(spv_registry, pool_obj_id, spv, securitization_package_id, clock, ctx);
        transfer::share_object(state);

        events::emit_pool_initialised(
            pool_id, originator, spv, total_pool_value,
            clock::timestamp_ms(clock),
        );
    }

    // ─── Admin: link downstream contracts ────────────────────────────────────

    /// Set deployer addresses of the three downstream contracts.
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

    /// Set the shared object IDs of all four downstream contracts.
    /// Called once after the shared objects have been created and their IDs are
    /// known. This is what the off-chain API reads to traverse from a PoolState
    /// to its TrancheRegistry, IssuanceState, WaterfallState, and PaymentVault
    /// without any external configuration.
    public entry fun set_contract_objects(
        _cap:                  &AdminCap,
        state:                 &mut PoolState,
        tranche_factory_obj:   ID,
        issuance_contract_obj: ID,
        waterfall_engine_obj:  ID,
        payment_vault_obj:     ID,
    ) {
        let zero_id = object::id_from_address(@0x0);
        assert!(tranche_factory_obj   != zero_id, errors::contracts_not_linked());
        assert!(issuance_contract_obj != zero_id, errors::contracts_not_linked());
        assert!(waterfall_engine_obj  != zero_id, errors::contracts_not_linked());
        assert!(payment_vault_obj     != zero_id, errors::contracts_not_linked());

        state.tranche_factory_obj   = tranche_factory_obj;
        state.issuance_contract_obj = issuance_contract_obj;
        state.waterfall_engine_obj  = waterfall_engine_obj;
        state.payment_vault_obj     = payment_vault_obj;
    }

    // ─── Core lifecycle ───────────────────────────────────────────────────────

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

        let oracle_cap = OracleCap {
            id:          object::new(ctx),
            pool_obj_id: state.pool_obj_id,
        };
        transfer::transfer(oracle_cap, state.oracle_address);

        events::emit_pool_initialised(
            state.pool_id, state.originator, state.spv,
            state.total_pool_value, clock::timestamp_ms(clock),
        );
    }

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

        if (now >= state.maturity_date && new_outstanding_principal == 0) {
            state.pool_status = STATUS_MATURED;
            events::emit_pool_closed(state.pool_id, now);
        };
    }

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

    public entry fun mark_default_admin(
        _cap:  &AdminCap,
        state: &mut PoolState,
        clock: &Clock,
    ) {
        assert!(state.pool_status == STATUS_ACTIVE, errors::invalid_pool_status());
        state.pool_status = STATUS_DEFAULTED;
        events::emit_pool_defaulted(state.pool_id, clock::timestamp_ms(clock));
    }

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

    public fun pool_obj_id(s: &PoolState): ID              { s.pool_obj_id }
    public fun pool_id(s: &PoolState): vector<u8>          { s.pool_id }
    public fun originator(s: &PoolState): address          { s.originator }
    public fun spv(s: &PoolState): address                 { s.spv }
    public fun total_pool_value(s: &PoolState): u64        { s.total_pool_value }
    public fun outstanding_principal(s: &PoolState): u64   { s.current_outstanding_principal }
    public fun interest_rate(s: &PoolState): u32           { s.interest_rate }
    public fun maturity_date(s: &PoolState): u64           { s.maturity_date }
    public fun asset_hash(s: &PoolState): vector<u8>       { s.asset_hash }
    public fun pool_status(s: &PoolState): u8              { s.pool_status }
    public fun oracle_address(s: &PoolState): address      { s.oracle_address }
    public fun tranche_factory_obj(s: &PoolState): ID      { s.tranche_factory_obj }
    public fun issuance_contract_obj(s: &PoolState): ID    { s.issuance_contract_obj }
    public fun waterfall_engine_obj(s: &PoolState): ID     { s.waterfall_engine_obj }
    public fun payment_vault_obj(s: &PoolState): ID        { s.payment_vault_obj }
    public fun is_active(s: &PoolState): bool              { s.pool_status == STATUS_ACTIVE }
    public fun is_defaulted(s: &PoolState): bool           { s.pool_status == STATUS_DEFAULTED }
    public fun is_matured(s: &PoolState): bool             { s.pool_status == STATUS_MATURED }
    public fun status_created(): u8                        { STATUS_CREATED }
    public fun status_active(): u8                         { STATUS_ACTIVE }
    public fun status_defaulted(): u8                      { STATUS_DEFAULTED }
    public fun status_matured(): u8                        { STATUS_MATURED }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
}
