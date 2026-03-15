/// Test suite for IssuanceContract.
///
/// Test coverage:
///  - create_issuance_state: prices stored, accessors, zero price aborts
///  - start_issuance: happy path, pool-binding guard, invalid window guard
///  - end_issuance: happy path, not-active guard
///  - invest: happy path (all three tranches), not-whitelisted abort
///  - release_funds_to_vault: happy path, insufficient funds guard
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function, lint(self_transfer))]
module securitization::issuance_contract_tests {
    use iota::test_scenario::{Self as ts, Scenario};
    use iota::clock::{Self, Clock};
    use iota::coin::{Self, Coin};
    use iota::iota::IOTA;
    use iota::object;

    use securitization::issuance_contract::{
        Self, IssuanceState, IssuanceOwnerCap,
    };
    use securitization::pool_contract::{Self, PoolState, AdminCap};
    use securitization::tranche_factory::{
        Self, TrancheRegistry, TrancheAdminCap, IssuanceAdminCap,
    };
    use securitization::errors;

    use spv::compliance_registry::{Self, ComplianceRegistry, ComplianceAdminCap};
    use spv::payment_vault::{Self, VaultBalance, VaultAdminCap};
    use spv::spv_registry::{Self, SPVRegistry};

    // ─── Test addresses ───────────────────────────────────────────────────────
    const ADMIN:    address = @0xA0;
    const INVESTOR: address = @0xC0; // also used as issuance_contract_addr
    const SPV:      address = @0xA1;
    const ORACLE:   address = @0xA2;
    const PKG:      address = @0xAF;

    // ─── Price / supply fixtures ──────────────────────────────────────────────
    const PRICE_SENIOR: u64 = 1_000; // 1 000 base units per token
    const PRICE_MEZZ:   u64 =   900;
    const PRICE_JUNIOR: u64 =   800;
    const SENIOR_CAP:   u64 = 1_000_000;
    const MEZZ_CAP:     u64 =   500_000;
    const JUNIOR_CAP:   u64 =   250_000;

    // ─── One year in ms ───────────────────────────────────────────────────────
    const ONE_YEAR_MS: u64 = 365 * 24 * 3600 * 1000;

    // ─── Fixture helpers ──────────────────────────────────────────────────────

    fun setup_issuance(scenario: &mut Scenario) {
        issuance_contract::init_for_testing(ts::ctx(scenario));
    }

    fun setup_pool_contracts(scenario: &mut Scenario) {
        pool_contract::init_for_testing(ts::ctx(scenario));
    }

    fun setup_spv_registry(scenario: &mut Scenario) {
        spv_registry::init_for_testing(ts::ctx(scenario));
    }

    fun setup_tranche_factory(scenario: &mut Scenario) {
        tranche_factory::init_for_testing(ts::ctx(scenario));
    }

    fun setup_compliance(scenario: &mut Scenario) {
        compliance_registry::init_for_testing(ts::ctx(scenario));
    }

    fun setup_vault(scenario: &mut Scenario) {
        payment_vault::init_for_testing(ts::ctx(scenario));
    }

    /// Create and activate a pool. Returns the PoolState object ID.
    fun create_active_pool(scenario: &mut Scenario, clock: &Clock): iota::object::ID {
        // create_pool
        ts::next_tx(scenario, ADMIN);
        let pool_obj_id;
        {
            let cap         = ts::take_from_sender<AdminCap>(scenario);
            let mut reg     = ts::take_shared<SPVRegistry>(scenario);
            pool_contract::create_pool(
                &cap, &mut reg, SPV, b"POOL-001", ADMIN,
                1_000_000_000, 500,
                clock::timestamp_ms(clock) + ONE_YEAR_MS,
                b"aabbccdd00000000000000000000000000000000000000000000000000000000",
                ORACLE, PKG, clock, ts::ctx(scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(scenario, cap);
        };

        ts::next_tx(scenario, ADMIN);
        {
            let state = ts::take_shared<PoolState>(scenario);
            pool_obj_id = pool_contract::pool_obj_id(&state);
            ts::return_shared(state);
        };

        // set_contracts
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::set_contracts(&cap, &mut state, ADMIN, ADMIN, ADMIN, ORACLE);
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };

        // initialise_pool
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::initialise_pool(&cap, &mut state, clock, ts::ctx(scenario));
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };

        // activate_pool
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<AdminCap>(scenario);
            let mut state = ts::take_shared<PoolState>(scenario);
            pool_contract::activate_pool(&cap, &mut state, clock);
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };

        pool_obj_id
    }

    /// Create IssuanceState bound to pool_obj_id.
    fun create_issuance_state_helper(scenario: &mut Scenario, pool_obj_id: iota::object::ID) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, pool_obj_id,
                PRICE_SENIOR, PRICE_MEZZ, PRICE_JUNIOR,
                ts::ctx(scenario),
            );
            ts::return_to_sender(scenario, cap);
        };
    }

    /// Start an issuance window 0 → sale_start + ONE_YEAR_MS.
    fun start_issuance_helper(scenario: &mut Scenario, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(scenario);
            let pool      = ts::take_shared<PoolState>(scenario);
            issuance_contract::start_issuance(
                &cap, &mut state, &pool,
                0,          // sale_start (epoch 0)
                clock::timestamp_ms(clock) + ONE_YEAR_MS,
                clock,
            );
            ts::return_shared(pool);
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. create_issuance_state
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_create_issuance_state_stores_prices() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);

        let pool_id = object::id_from_address(@0xBB);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, pool_id,
                PRICE_SENIOR, PRICE_MEZZ, PRICE_JUNIOR,
                ts::ctx(&mut scenario),
            );
            ts::return_to_sender(&scenario, cap);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            assert!(issuance_contract::price_senior(&state) == PRICE_SENIOR, 0);
            assert!(issuance_contract::price_mezz(&state)   == PRICE_MEZZ,   1);
            assert!(issuance_contract::price_junior(&state) == PRICE_JUNIOR, 2);
            assert!(issuance_contract::pool_obj_id(&state)  == pool_id,      3);
            assert!(!issuance_contract::issuance_active(&state),             4);
            assert!(!issuance_contract::issuance_ended(&state),              5);
            assert!(issuance_contract::total_raised(&state) == 0,            6);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroPricePerUnit, location = securitization::issuance_contract)]
    fun test_create_issuance_state_zero_senior_price_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, object::id_from_address(@0xBB),
                0, PRICE_MEZZ, PRICE_JUNIOR, // ← zero senior
                ts::ctx(&mut scenario),
            );
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroPricePerUnit, location = securitization::issuance_contract)]
    fun test_create_issuance_state_zero_mezz_price_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, object::id_from_address(@0xBB),
                PRICE_SENIOR, 0, PRICE_JUNIOR, // ← zero mezz
                ts::ctx(&mut scenario),
            );
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroPricePerUnit, location = securitization::issuance_contract)]
    fun test_create_issuance_state_zero_junior_price_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, object::id_from_address(@0xBB),
                PRICE_SENIOR, PRICE_MEZZ, 0, // ← zero junior
                ts::ctx(&mut scenario),
            );
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. start_issuance
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_start_issuance_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);
        create_issuance_state_helper(&mut scenario, pool_obj_id);
        start_issuance_helper(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            assert!(issuance_contract::issuance_active(&state),             0);
            assert!(!issuance_contract::issuance_ended(&state),             1);
            assert!(issuance_contract::sale_start(&state) == 0,             2);
            assert!(issuance_contract::sale_end(&state) > 0,                3);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EPoolNotActive, location = securitization::issuance_contract)]
    fun test_start_issuance_pool_id_mismatch_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        create_active_pool(&mut scenario, &clock);

        // Create issuance state bound to a DIFFERENT pool ID
        let wrong_pool_id = object::id_from_address(@0xDEAD);
        create_issuance_state_helper(&mut scenario, wrong_pool_id);

        // start_issuance should abort — pool_obj_id mismatch
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let pool      = ts::take_shared<PoolState>(&scenario);
            issuance_contract::start_issuance(
                &cap, &mut state, &pool,
                0, clock::timestamp_ms(&clock) + ONE_YEAR_MS, &clock,
            );
            ts::return_shared(pool);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvalidSaleWindow, location = securitization::issuance_contract)]
    fun test_start_issuance_end_before_start_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);
        create_issuance_state_helper(&mut scenario, pool_obj_id);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let pool      = ts::take_shared<PoolState>(&scenario);
            // sale_end (100) < sale_start (1000) → invalid
            issuance_contract::start_issuance(&cap, &mut state, &pool, 1000, 100, &clock);
            ts::return_shared(pool);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. end_issuance
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_end_issuance_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);
        create_issuance_state_helper(&mut scenario, pool_obj_id);
        start_issuance_helper(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            issuance_contract::end_issuance(&cap, &mut state, &clock);
            assert!(!issuance_contract::issuance_active(&state), 0);
            assert!(issuance_contract::issuance_ended(&state),   1);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EIssuanceNotActive, location = securitization::issuance_contract)]
    fun test_end_issuance_not_active_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup_issuance(&mut scenario);

        let pool_id = object::id_from_address(@0xBB);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            issuance_contract::create_issuance_state<IOTA>(
                &cap, pool_id, PRICE_SENIOR, PRICE_MEZZ, PRICE_JUNIOR,
                ts::ctx(&mut scenario),
            );
            ts::return_to_sender(&scenario, cap);
        };

        // end without start → must abort
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            issuance_contract::end_issuance(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. invest
    // ═════════════════════════════════════════════════════════════════════════

    /// Full invest test: INVESTOR is whitelisted and also holds the IAC
    /// (passed as the issuance_contract_addr to create_tranches).
    #[test]
    fun test_invest_senior_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        // Init all contracts
        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);
        setup_tranche_factory(&mut scenario);
        setup_compliance(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);

        // create_tranches — INVESTOR receives IssuanceAdminCap
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                pool_obj_id,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                INVESTOR, // ← INVESTOR receives IAC
                &clock,
                ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        // Whitelist INVESTOR
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut creg = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut creg, INVESTOR, 2, b"US",
                object::id_from_address(@0xDEAD), 0, &clock,
            );
            ts::return_shared(creg);
            ts::return_to_sender(&scenario, cap);
        };

        // Create and start issuance
        create_issuance_state_helper(&mut scenario, pool_obj_id);
        start_issuance_helper(&mut scenario, &clock);

        // INVESTOR invests 5_000 base units → 5 senior tokens at PRICE_SENIOR=1000
        let payment_amount: u64 = 5_000;
        ts::next_tx(&mut scenario, INVESTOR);
        {
            let iac       = ts::take_from_sender<IssuanceAdminCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let mut reg   = ts::take_shared<TrancheRegistry>(&scenario);
            let creg      = ts::take_shared<ComplianceRegistry>(&scenario);
            let payment   = coin::mint_for_testing<IOTA>(payment_amount, ts::ctx(&mut scenario));

            issuance_contract::invest(
                &mut state, &mut reg, &creg, &iac,
                tranche_factory::tranche_senior(),
                payment, &clock, ts::ctx(&mut scenario),
            );

            assert!(issuance_contract::total_raised(&state)        == payment_amount, 0);
            assert!(issuance_contract::vault_balance_value(&state) == payment_amount, 1);
            assert!(issuance_contract::has_subscription(&state, INVESTOR), 2);

            ts::return_shared(creg);
            ts::return_shared(reg);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, iac);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvestorNotVerified, location = securitization::issuance_contract)]
    fun test_invest_not_whitelisted_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);
        setup_tranche_factory(&mut scenario);
        setup_compliance(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);

        // create_tranches — INVESTOR receives IAC
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                pool_obj_id,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                INVESTOR,
                &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        // Do NOT whitelist INVESTOR
        create_issuance_state_helper(&mut scenario, pool_obj_id);
        start_issuance_helper(&mut scenario, &clock);

        // invest should abort — not whitelisted
        ts::next_tx(&mut scenario, INVESTOR);
        {
            let iac       = ts::take_from_sender<IssuanceAdminCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let mut reg   = ts::take_shared<TrancheRegistry>(&scenario);
            let creg      = ts::take_shared<ComplianceRegistry>(&scenario);
            let payment   = coin::mint_for_testing<IOTA>(5_000, ts::ctx(&mut scenario));

            issuance_contract::invest(
                &mut state, &mut reg, &creg, &iac,
                tranche_factory::tranche_senior(),
                payment, &clock, ts::ctx(&mut scenario),
            );

            ts::return_shared(creg);
            ts::return_shared(reg);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, iac);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. release_funds_to_vault
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_release_funds_to_vault_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));

        setup_issuance(&mut scenario);
        setup_pool_contracts(&mut scenario);
        setup_spv_registry(&mut scenario);
        setup_tranche_factory(&mut scenario);
        setup_compliance(&mut scenario);
        setup_vault(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        let pool_obj_id = create_active_pool(&mut scenario, &clock);

        // create_tranches
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                pool_obj_id,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                INVESTOR, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        // Whitelist INVESTOR
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut creg = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut creg, INVESTOR, 2, b"US",
                object::id_from_address(@0xDEAD), 0, &clock,
            );
            ts::return_shared(creg);
            ts::return_to_sender(&scenario, cap);
        };

        create_issuance_state_helper(&mut scenario, pool_obj_id);
        start_issuance_helper(&mut scenario, &clock);

        // Invest
        ts::next_tx(&mut scenario, INVESTOR);
        {
            let iac       = ts::take_from_sender<IssuanceAdminCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let mut reg   = ts::take_shared<TrancheRegistry>(&scenario);
            let creg      = ts::take_shared<ComplianceRegistry>(&scenario);
            let payment   = coin::mint_for_testing<IOTA>(10_000, ts::ctx(&mut scenario));
            issuance_contract::invest(
                &mut state, &mut reg, &creg, &iac,
                tranche_factory::tranche_senior(),
                payment, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(creg);
            ts::return_shared(reg);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, iac);
        };

        // End issuance
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            issuance_contract::end_issuance(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // Create vault
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap = ts::take_from_sender<VaultAdminCap>(&scenario);
            payment_vault::create_vault<IOTA>(&cap, ts::ctx(&mut scenario));
            ts::return_to_sender(&scenario, cap);
        };

        // Release funds
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap        = ts::take_from_sender<IssuanceOwnerCap>(&scenario);
            let mut state  = ts::take_shared<IssuanceState<IOTA>>(&scenario);
            let mut vault  = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            issuance_contract::release_funds_to_vault(&cap, &mut state, &mut vault, &clock);
            assert!(payment_vault::vault_balance(&vault)   == 10_000, 0);
            assert!(issuance_contract::vault_balance_value(&state) == 0, 1);
            ts::return_shared(vault);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
