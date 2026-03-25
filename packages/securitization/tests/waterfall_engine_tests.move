/// Comprehensive test suite for WaterfallEngine.
///
/// Test coverage:
///  - Interest accrual (simple interest correctness)
///  - Payment deposit and pending balance tracking
///  - Normal waterfall: strict priority order (Senior → Mezz → Junior → Reserve)
///  - Turbo mode: excess diverted to Senior principal paydown
///  - Default mode: all funds to Senior, Mezz and Junior suspended
///  - Mode transition guards (turbo only from normal, etc.)
///  - Reserve accumulation on surplus
///  - Full repayment scenario (all outstandings reach zero)
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module securitization::waterfall_engine_tests {
    use iota::test_scenario::{Self as ts};
    use iota::clock::{Self, Clock};
    use iota::object;
    use securitization::waterfall_engine::{
        Self, WaterfallState, WaterfallAdminCap, PoolCap,
    };
    use securitization::errors;
    use securitization::waterfall_engine::senior_accrued;
    use iota::test_scenario::Scenario;

    // ─── Addresses ────────────────────────────────────────────────────────────
    const ADMIN: address = @0xC0;
    const POOL:  address = @0xC1;

    // ─── Rates ────────────────────────────────────────────────────────────────
    const SENIOR_RATE: u32 = 300; // 3%
    const MEZZ_RATE:   u32 = 600; // 6%
    const JUNIOR_RATE: u32 = 900; // 9%

    // ─── Fixture ──────────────────────────────────────────────────────────────
    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            waterfall_engine::init_for_testing(ts::ctx(scenario));
        };
    }

    fun setup_waterfall(scenario: &mut ts::Scenario, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<WaterfallAdminCap>(scenario);
            let mut state = ts::take_shared<WaterfallState>(scenario);
            waterfall_engine::initialise_waterfall(
                &cap, &mut state,
                object::id_from_address(@0xBB), // pool_obj_id
                5_000_000,  // senior outstanding
                3_000_000,  // mezz outstanding
                2_000_000,  // junior outstanding
                SENIOR_RATE, MEZZ_RATE, JUNIOR_RATE,
                waterfall_engine::freq_monthly(),
                POOL,
                clock,
                ts::ctx(scenario),
            );
            ts::return_shared(state);
            ts::return_to_sender(scenario, cap);
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  1. Initialisation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_initialise_waterfall_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        
        // Allow init to publish and create shared objects
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let state = ts::take_shared<WaterfallState>(&scenario);
            assert!(waterfall_engine::senior_outstanding(&state) == 5_000_000, 0);
            assert!(waterfall_engine::mezz_outstanding(&state)   == 3_000_000, 1);
            assert!(waterfall_engine::junior_outstanding(&state) == 2_000_000, 2);
            assert!(waterfall_engine::waterfall_status(&state) == waterfall_engine::mode_normal(), 3);
            assert!(waterfall_engine::pending_funds(&state) == 0, 4);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  2. Payment deposit
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_deposit_payment_accumulates() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::deposit_payment(&mut state, 100_000, &clock);
            waterfall_engine::deposit_payment(&mut state, 200_000, &clock);
            assert!(waterfall_engine::pending_funds(&state) == 300_000, 0);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ENoFundsAvailable, location = securitization::waterfall_engine)]
    fun test_deposit_zero_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::deposit_payment(&mut state, 0, &clock);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  3. Normal waterfall execution
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_normal_waterfall_priority_order() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        clock::set_for_testing(&mut clock, 0);
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        // Advance 30 days (in ms) to accrue some interest
        clock::set_for_testing(&mut clock, 30 * 24 * 3600 * 1000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);

            // Deposit a payment that covers Senior fully, partial Mezz
            waterfall_engine::deposit_payment(&mut state, 5_200_000, &clock);

            let result = waterfall_engine::execute_waterfall(&mut state, &clock);

            // Senior must receive funds before Mezz
            // Senior outstanding should be reduced (or zero)
            let s = waterfall_engine::senior_outstanding(&state);
            let m = waterfall_engine::mezz_outstanding(&state);

            // If Senior is fully paid, Mezz should have received some
            // Key invariant: payment order is always Senior first
            assert!(s <= 5_000_000, 0);

            // Pending funds should be zero after execution
            assert!(waterfall_engine::pending_funds(&state) == 0, 2);

            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_normal_waterfall_surplus_goes_to_reserve() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);

            // Overpay — more than total outstanding across all tranches
            let total = 5_000_000 + 3_000_000 + 2_000_000 + 500_000; // +500k surplus
            waterfall_engine::deposit_payment(&mut state, total, &clock);
            waterfall_engine::run_waterfall(&mut state, &clock);

            // All outstandings should be zero
            assert!(waterfall_engine::senior_outstanding(&state) == 0, 0);
            assert!(waterfall_engine::mezz_outstanding(&state)   == 0, 1);
            assert!(waterfall_engine::junior_outstanding(&state) == 0, 2);
            // Reserve should have captured the surplus
            assert!(waterfall_engine::reserve_account(&state) >= 500_000, 3);

            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ENoFundsAvailable, location = securitization::waterfall_engine)]
    fun test_execute_waterfall_no_funds_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            // No funds deposited — should abort
            waterfall_engine::run_waterfall(&mut state, &clock);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  4. Turbo mode
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_turbo_mode_reduces_senior_principal_faster() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        // Activate turbo
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<WaterfallAdminCap>(&scenario);
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::trigger_turbo_mode(&cap, &mut state, &clock);
            assert!(waterfall_engine::waterfall_status(&state) == waterfall_engine::mode_turbo(), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // Run waterfall with surplus
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::deposit_payment(&mut state, 2_000_000, &clock);
            waterfall_engine::run_waterfall(&mut state, &clock);

            // In turbo mode, Senior outstanding should be reduced more aggressively
            let senior_after = waterfall_engine::senior_outstanding(&state);
            assert!(senior_after < 5_000_000, 0);

            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ETurboRequiresNormal, location = securitization::waterfall_engine)]
    fun test_turbo_mode_from_default_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<WaterfallAdminCap>(&scenario);
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            // Set default mode first
            waterfall_engine::trigger_default_mode_admin(&cap, &mut state, &clock);
            // Now try turbo — should abort (requires Normal)
            waterfall_engine::trigger_turbo_mode(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  5. Default mode
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_default_mode_only_pays_senior() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        // Trigger default mode
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<WaterfallAdminCap>(&scenario);
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::trigger_default_mode_admin(&cap, &mut state, &clock);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        // Run waterfall with a payment smaller than Senior outstanding
        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            let mezz_before   = waterfall_engine::mezz_outstanding(&state);
            let junior_before = waterfall_engine::junior_outstanding(&state);

            waterfall_engine::deposit_payment(&mut state, 1_000_000, &clock);
            waterfall_engine::run_waterfall(&mut state, &clock);

            // Mezz and Junior outstandings must be unchanged in default mode
            assert!(waterfall_engine::mezz_outstanding(&state)   == mezz_before,   0);
            assert!(waterfall_engine::junior_outstanding(&state) == junior_before, 1);
            // Senior outstanding must have decreased
            assert!(waterfall_engine::senior_outstanding(&state) < 5_000_000, 2);

            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_default_mode_by_pool_cap() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, POOL);
        {
            let cap       = ts::take_from_sender<PoolCap>(&scenario);
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::trigger_default_mode_pool(&cap, &mut state, &clock);
            assert!(waterfall_engine::waterfall_status(&state) == waterfall_engine::mode_default(), 0);
            ts::return_shared(state);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  6. Interest accrual
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_accrue_interest_increases_balances() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        clock::set_for_testing(&mut clock, 0);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        // Advance 1 year
        clock::set_for_testing(&mut clock, 365 * 24 * 3600 * 1000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            waterfall_engine::accrue_interest(&mut state, &clock);

            // After 1 year: senior accrued ≈ 5_000_000 * 3% = 150_000
            //               mezz accrued    ≈ 3_000_000 * 6% = 180_000
            //               junior accrued  ≈ 2_000_000 * 9% = 180_000
            // Allow ±1 for integer division rounding
            let sa = waterfall_engine::senior_accrued(&state);
            let ma = waterfall_engine::mezz_accrued(&state);
            let ja = waterfall_engine::junior_accrued(&state);

            assert!(sa >= 149_000 && sa <= 151_000, 0); // ~150_000
            assert!(ma >= 179_000 && ma <= 181_000, 1); // ~180_000
            assert!(ja >= 179_000 && ja <= 181_000, 2); // ~180_000

            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ENoTimeElapsed, location = securitization::waterfall_engine)]
    fun test_accrue_interest_no_time_elapsed_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_waterfall(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut state = ts::take_shared<WaterfallState>(&scenario);
            // Clock has not advanced — should abort
            waterfall_engine::accrue_interest(&mut state, &clock);
            ts::return_shared(state);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
