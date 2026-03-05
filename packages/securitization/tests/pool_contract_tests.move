/// Comprehensive test suite for PoolContract.
///
/// Test coverage:
///  - Happy-path full lifecycle (Created → Active → Matured)
///  - Default path (Created → Active → Defaulted → closed)
///  - All abort codes validated with expected error codes
///  - Oracle cap and admin cap separation enforced
///  - Auto-maturation when principal == 0 past maturity date
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module securitization::pool_contract_tests {
    use iota::test_scenario::{Self as ts, Scenario};
    use iota::clock::{Self, Clock};
    use securitization::pool_contract::{
        Self, PoolState, AdminCap, OracleCap,
    };
    use securitization::errors;

    // ─── Test addresses ────────────────────────────────────────────────────────
    const ADMIN:      address = @0xA0;
    const ORIGINATOR: address = @0xA1;
    const SPV:        address = @0xA2;
    const ORACLE:     address = @0xA3;
    const FACTORY:    address = @0xA4;
    const ISSUANCE:   address = @0xA5;
    const WATERFALL:  address = @0xA6;

    // ─── Fixture helpers ──────────────────────────────────────────────────────

    /// Standard asset hash (32 bytes represented as a vector)
    fun asset_hash(): vector<u8> {
        x"a665a45920422f9d417e4867efdc4fb8a04a1f3fff1fa07e998e86f7f7a27ae3"
    }

    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            pool_contract::init_for_testing(ts::ctx(scenario));
        };
    }

    /// Initialise the pool state with defaults and link contracts.
    /// Returns a configured scenario ready for lifecycle tests.
    fun setup_and_initialise(scenario: &mut Scenario, clock: &Clock) {
        // 1. Set contract links
        ts::next_tx(scenario, ADMIN);
        {
            let cap   = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::set_contracts(
                &cap, &mut state,
                FACTORY, ISSUANCE, WATERFALL, ORACLE
            );
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };

        // 2. Initialise pool
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::initialise_pool(
                &cap, &mut state,
                b"POOL-001",
                ORIGINATOR,
                SPV,
                1_000_000_000,  // 1,000 tokens at 6dp
                500,            // 5% annual in bps
                clock::timestamp_ms(clock) + 31_536_000_000, // +1 year in ms
                asset_hash(),
                clock,
                ts::ctx(scenario),
            );
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  1. Initialisation tests
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_initialise_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 

        // Module publish creates PoolState and sends AdminCap to ADMIN
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        // Verify stored values
        ts::next_tx(&mut scenario, ADMIN);
        {
            let state = ts::take_shared<PoolState>(&scenario);
            assert!(pool_contract::pool_id(&state)        == b"POOL-001",   0);
            assert!(pool_contract::originator(&state)     == ORIGINATOR,    1);
            assert!(pool_contract::spv(&state)            == SPV,           2);
            assert!(pool_contract::total_pool_value(&state) == 1_000_000_000, 3);
            assert!(pool_contract::outstanding_principal(&state) == 1_000_000_000, 4);
            assert!(pool_contract::interest_rate(&state)  == 500,           5);
            assert!(pool_contract::asset_hash(&state)     == asset_hash(),  6);
            assert!(pool_contract::pool_status(&state)    == pool_contract::status_created(), 7);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EAlreadyInitialised, location = securitization::pool_contract)]
    fun test_initialise_pool_twice_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        // Second initialise should abort
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::initialise_pool(
                &cap, &mut state, b"POOL-002", ORIGINATOR, SPV,
                500_000, 300, clock::timestamp_ms(&clock) + 1_000_000, asset_hash(),
                &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroPoolValue, location = securitization::pool_contract)]
    fun test_initialise_zero_pool_value_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::set_contracts(&cap, &mut state, FACTORY, ISSUANCE, WATERFALL, ORACLE);
            pool_contract::initialise_pool(
                &cap, &mut state, b"POOL-001", ORIGINATOR, SPV,
                0, // zero pool value
                500, clock::timestamp_ms(&clock) + 1_000_000, asset_hash(),
                &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EMaturityInPast, location = securitization::pool_contract)]
    fun test_initialise_maturity_in_past_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        clock::set_for_testing(&mut clock, 10_000_000); // advance clock
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::set_contracts(&cap, &mut state, FACTORY, ISSUANCE, WATERFALL, ORACLE);
            pool_contract::initialise_pool(
                &cap, &mut state, b"POOL-001", ORIGINATOR, SPV,
                1_000_000, 500,
                1, // maturity in the past
                asset_hash(), &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  2. Activation tests
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_activate_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
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
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        // Activate once
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            // Try to activate again — should abort
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EContractsNotLinked, location = securitization::pool_contract)]
    fun test_activate_without_contracts_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
        {
            // Initialise without setting contracts first
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::initialise_pool(
                &cap, &mut state, b"POOL-001", ORIGINATOR, SPV,
                1_000_000, 500, clock::timestamp_ms(&clock) + 1_000_000_000, asset_hash(),
                &clock, ts::ctx(&mut scenario),
            );
            // Try to activate without linked contracts
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  3. Performance data update tests
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_update_performance_data_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        // Activate pool
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // Oracle updates performance data
        ts::next_tx(&mut scenario, ORACLE);
        {
            let cap       = ts::take_from_sender<OracleCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(
                &cap, &mut state,
                800_000_000, // 20% repaid
                clock::timestamp_ms(&clock),
                &clock,
            );
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
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // ADMIN tries to take OracleCap — aborts because they don't have one
        ts::next_tx(&mut scenario, ADMIN);
        {
            let oracle_cap = ts::take_from_sender<OracleCap>(&scenario); // aborts here
            let mut state  = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(
                &oracle_cap, &mut state, 500_000_000,
                clock::timestamp_ms(&clock), &clock,
            );
            ts::return_shared(state);
            ts::return_to_sender(&scenario, oracle_cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  4. Default and close tests
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_mark_default_by_admin_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        ts::next_tx(&mut scenario, ADMIN);
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
        ts::next_tx(&mut scenario, ADMIN);
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
        ts::next_tx(&mut scenario, ADMIN);
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
        ts::next_tx(&mut scenario, ADMIN);
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
        ts::next_tx(&mut scenario, ADMIN);
        setup_and_initialise(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            // Close without activating first — should abort
            pool_contract::close_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  5. Auto-maturation test
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_auto_maturation_on_full_repayment() {
        let mut scenario  = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario); 
        // Set maturity to 1 year from now
        let maturity_ms = 31_536_000_000u64;
        clock::set_for_testing(&mut clock, 0);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::set_contracts(&cap, &mut state, FACTORY, ISSUANCE, WATERFALL, ORACLE);
            pool_contract::initialise_pool(
                &cap, &mut state, b"POOL-001", ORIGINATOR, SPV,
                1_000_000, 500, maturity_ms, asset_hash(),
                &clock, ts::ctx(&mut scenario),
            );
            pool_contract::activate_pool(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // Advance clock past maturity
        clock::set_for_testing(&mut clock, maturity_ms + 1);

        // Oracle reports principal == 0 → should auto-mature
        ts::next_tx(&mut scenario, ORACLE);
        {
            let cap       = ts::take_from_sender<OracleCap>(&scenario);
            let mut state = ts::take_shared<PoolState>(&scenario);
            pool_contract::update_performance_data(
                &cap, &mut state, 0, maturity_ms, &clock,
            );
            assert!(pool_contract::is_matured(&state), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
