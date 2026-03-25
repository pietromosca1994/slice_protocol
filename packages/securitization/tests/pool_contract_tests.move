/// Comprehensive test suite for PoolContract.
///
/// Test coverage:
///  - create_pool: stores fields, registers in SPVRegistry, abort guards
///  - set_contracts / initialise_pool: happy path and abort guards
///  - set_contract_objects: all four IDs (including payment_vault_obj)
///  - activate_pool, mark_default (admin + oracle), close_pool
///  - update_performance_data: oracle cap enforcement
///  - auto-maturation when principal == 0 past maturity date
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module securitization::pool_contract_tests {
    use iota::test_scenario::{Self as ts, Scenario};
    use iota::clock::{Self, Clock};
    use iota::object;
    use securitization::pool_contract::{Self, PoolState, AdminCap, OracleCap};
    use securitization::errors;
    use spv::spv_registry::{Self, SPVRegistry};

    // ─── Test addresses ───────────────────────────────────────────────────────
    const ADMIN:      address = @0xA0;
    const ORIGINATOR: address = @0xA1;
    const SPV:        address = @0xA2;
    const ORACLE:     address = @0xA3;
    const FACTORY:    address = @0xA4;
    const ISSUANCE:   address = @0xA5;
    const WATERFALL:  address = @0xA6;
    const PKG:        address = @0xAF;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    fun asset_hash(): vector<u8> {
        x"a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3"
    }

    fun setup(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        { pool_contract::init_for_testing(ts::ctx(scenario)); };
        ts::next_tx(scenario, ADMIN);
        { spv_registry::init_for_testing(ts::ctx(scenario)); };
    }

    fun do_create_pool(scenario: &mut Scenario, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<AdminCap>(scenario);
            let mut reg = ts::take_shared<SPVRegistry>(scenario);
            pool_contract::create_pool(
                &cap, &mut reg, SPV, b"POOL-001", ORIGINATOR,
                1_000_000_000, 500,
                clock::timestamp_ms(clock) + 31_536_000_000,
                asset_hash(), ORACLE, PKG, clock, ts::ctx(scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(scenario, cap);
        };
    }

    fun do_set_contracts(scenario: &mut Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::set_contracts(&cap, &mut state, FACTORY, ISSUANCE, WATERFALL, ORACLE);
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };
    }

    fun do_initialise(scenario: &mut Scenario, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::initialise_pool(&cap, &mut state, clock, ts::ctx(scenario));
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };
    }

    fun setup_and_initialise(scenario: &mut Scenario, clock: &Clock) {
        do_create_pool(scenario, clock);
        do_set_contracts(scenario);
        do_initialise(scenario, clock);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  1. Pool creation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_create_pool_stores_fields() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        do_create_pool(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let state = ts::take_shared<PoolState>(&scenario);
            assert!(pool_contract::pool_id(&state)             == b"POOL-001",     0);
            assert!(pool_contract::originator(&state)          == ORIGINATOR,       1);
            assert!(pool_contract::spv(&state)                 == SPV,              2);
            assert!(pool_contract::total_pool_value(&state)    == 1_000_000_000,    3);
            assert!(pool_contract::outstanding_principal(&state) == 1_000_000_000,  4);
            assert!(pool_contract::interest_rate(&state)       == 500,              5);
            assert!(pool_contract::asset_hash(&state)          == asset_hash(),     6);
            assert!(pool_contract::pool_status(&state) == pool_contract::status_created(), 7);
            assert!(!pool_contract::is_active(&state),                              8);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_create_pool_registers_in_spv_registry() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        do_create_pool(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let state    = ts::take_shared<PoolState>(&scenario);
            let registry = ts::take_shared<SPVRegistry>(&scenario);
            let pid      = pool_contract::pool_obj_id(&state);
            assert!(spv_registry::pool_exists(&registry, pid), 0);
            assert!(spv_registry::pool_count(&registry) == 1,  1);
            ts::return_shared(state);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroPoolValue, location = securitization::pool_contract)]
    fun test_create_pool_zero_value_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<AdminCap>(&scenario);
            let mut reg = ts::take_shared<SPVRegistry>(&scenario);
            pool_contract::create_pool(
                &cap, &mut reg, SPV, b"POOL-001", ORIGINATOR,
                0, 500, clock::timestamp_ms(&clock) + 1_000_000,
                asset_hash(), ORACLE, PKG, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EMaturityInPast, location = securitization::pool_contract)]
    fun test_create_pool_maturity_in_past_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 10_000_000);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<AdminCap>(&scenario);
            let mut reg = ts::take_shared<SPVRegistry>(&scenario);
            pool_contract::create_pool(
                &cap, &mut reg, SPV, b"POOL-001", ORIGINATOR,
                1_000_000, 500,
                1, // maturity in past
                asset_hash(), ORACLE, PKG, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  2. Initialisation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_initialise_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        // OracleCap should land in ORACLE's inventory
        ts::next_tx(&mut scenario, ORACLE);
        { assert!(ts::has_most_recent_for_sender<OracleCap>(&scenario), 0); };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EAlreadyInitialised, location = securitization::pool_contract)]
    fun test_initialise_pool_twice_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::initialise_pool(&cap, &mut state, &clock, ts::ctx(&mut scenario));
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EContractsNotLinked, location = securitization::pool_contract)]
    fun test_initialise_without_contracts_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        do_create_pool(&mut scenario, &clock);
        // Skip set_contracts — initialise_pool must abort

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::initialise_pool(&cap, &mut state, &clock, ts::ctx(&mut scenario));
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  3. set_contract_objects (4 IDs including payment_vault_obj)
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_set_contract_objects_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        let tf_id  = object::id_from_address(@0xB1);
        let isc_id = object::id_from_address(@0xB2);
        let wf_id  = object::id_from_address(@0xB3);
        let pv_id  = object::id_from_address(@0xB4);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::set_contract_objects(&cap, &mut state, tf_id, isc_id, wf_id, pv_id);
            assert!(pool_contract::tranche_factory_obj(&state)   == tf_id,  0);
            assert!(pool_contract::issuance_contract_obj(&state) == isc_id, 1);
            assert!(pool_contract::waterfall_engine_obj(&state)  == wf_id,  2);
            assert!(pool_contract::payment_vault_obj(&state)     == pv_id,  3);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EContractsNotLinked, location = securitization::pool_contract)]
    fun test_set_contract_objects_zero_vault_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::set_contract_objects(
                &cap, &mut state,
                object::id_from_address(@0xB1),
                object::id_from_address(@0xB2),
                object::id_from_address(@0xB3),
                object::id_from_address(@0x0), // zero vault id → abort
            );
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  4. Activation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_activate_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            assert!(pool_contract::is_active(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvalidPoolStatus, location = securitization::pool_contract)]
    fun test_activate_already_active_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            pool_contract::activate_pool(&cap, &mut state, &clock); // second → abort
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  5. Performance data update
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_update_performance_data_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        ts::next_tx(&mut scenario, ORACLE);
        {
            let cap       = ts::take_from_sender<OracleCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(&cap, &mut state, 800_000_000, 0, &clock);
            assert!(pool_contract::outstanding_principal(&state) == 800_000_000, 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = iota::test_scenario::EEmptyInventory, location = iota::test_scenario)]
    fun test_update_performance_non_oracle_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // ADMIN has no OracleCap — take_from_sender aborts
        ts::next_tx(&mut scenario, ADMIN);
        {
            let oracle_cap = ts::take_from_sender<OracleCap>(&scenario); // aborts here
            let mut state  = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(&oracle_cap, &mut state, 500_000_000, 0, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, oracle_cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  6. Default and close
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_mark_default_by_admin_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            pool_contract::mark_default_admin(&cap, &mut state, &clock);
            assert!(pool_contract::is_defaulted(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_mark_default_by_oracle_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        ts::next_tx(&mut scenario, ORACLE);
        {
            let cap       = ts::take_from_sender<OracleCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::mark_default_oracle(&cap, &mut state, &clock);
            assert!(pool_contract::is_defaulted(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_close_pool_from_active() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            pool_contract::close_pool(&cap, &mut state, &clock);
            assert!(pool_contract::is_matured(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_close_pool_from_defaulted() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            pool_contract::mark_default_admin(&cap, &mut state, &clock);
            pool_contract::close_pool(&cap, &mut state, &clock);
            assert!(pool_contract::is_matured(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvalidPoolStatus, location = securitization::pool_contract)]
    fun test_close_pool_from_created_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::close_pool(&cap, &mut state, &clock); // not active → abort
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  7. Auto-maturation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_auto_maturation_on_full_repayment() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        let maturity_ms = 31_536_000_000u64;
        clock::set_for_testing(&mut clock, 0);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<AdminCap>(&scenario);
            let mut reg = ts::take_shared<SPVRegistry>(&scenario);
            pool_contract::create_pool(
                &cap, &mut reg, SPV, b"POOL-001", ORIGINATOR,
                1_000_000, 500, maturity_ms,
                asset_hash(), ORACLE, PKG, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        do_set_contracts(&mut scenario);
        do_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::set_for_testing(&mut clock, maturity_ms + 1);

        ts::next_tx(&mut scenario, ORACLE);
        {
            let cap       = ts::take_from_sender<OracleCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(&cap, &mut state, 0, maturity_ms, &clock);
            assert!(pool_contract::is_matured(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
