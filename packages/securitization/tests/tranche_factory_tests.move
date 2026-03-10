/// Comprehensive test suite for TrancheFactory.
///
/// Covers every method and state variable specified in the design document
/// (ISC Contract Reference v1.0 — TrancheFactory section):
///
///   createTranches()   → create_tranches
///   mint()             → mint
///   melt()             → melt_senior / melt_mezz / melt_junior
///   disableMinting()   → disable_minting
///   getTrancheInfo()   → get_tranche_info
///
/// ## OTW / architecture change
///
/// The three OTW structs (`SENIOR_COIN`, `MEZZ_COIN`, `JUNIOR_COIN`) now live
/// in their own modules (`senior_coin`, `mezz_coin`, `junior_coin`).  Each
/// coin module exposes a `#[test_only]` `create_treasury_for_testing` helper
/// that constructs a `TreasuryCap<T>` via the framework bypass, skipping the
/// `is_one_time_witness` VM check.
///
/// `tranche_factory::init_for_testing` still creates the `TrancheAdminCap`,
/// but no longer creates the `TrancheRegistry` — that now requires
/// `initialize_registry` to be called with the three treasury caps.
///
/// `setup()` therefore:
///   1. Calls `tranche_factory::init_for_testing` (emits `TrancheAdminCap`)
///   2. Advances one transaction as ADMIN
///   3. Calls `initialize_registry` with test treasury caps to produce the
///      shared `TrancheRegistry`
///
/// ## Test groups
///
///   1.  Post-init state
///   2.  createTranches — happy path
///   3.  createTranches — abort guards
///   4.  mint — happy paths (all three tranches)
///   5.  mint — abort guards
///   6.  melt — happy paths (partial, full, remint cycle)
///   7.  disableMinting
///   8.  getTrancheInfo — struct fields
///   9.  Access control (stranger cannot hold admin / issuance caps)
///   10. Read-only accessors and tranche-type constants
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function, lint(self_transfer))]
module securitization::tranche_factory_tests {
    use iota::test_scenario::{Self as ts, Scenario};
    use iota::clock::{Self, Clock};
    use iota::coin::{Self, Coin};

    // Coin types now come from their own modules
    use securitization::senior_coin::SENIOR_COIN;
    use securitization::mezz_coin::MEZZ_COIN;
    use securitization::junior_coin::JUNIOR_COIN;

    use securitization::tranche_factory::{
        Self,
        TrancheAdminCap,
        IssuanceAdminCap,
        TrancheRegistry,
        TrancheInfo,
    };
    use securitization::errors;

    // ─── Test addresses ───────────────────────────────────────────────────────
    const ADMIN:             address = @0xA0;
    const ISSUANCE_CONTRACT: address = @0xB0;
    const INVESTOR:          address = @0xC0;
    const STRANGER:          address = @0xD0;

    // ─── Supply cap fixtures (6 decimal places) ───────────────────────────────
    const SENIOR_CAP: u64 = 1_000_000_000; // 1 000 tokens
    const MEZZ_CAP:   u64 =   500_000_000; //   500 tokens
    const JUNIOR_CAP: u64 =   250_000_000; //   250 tokens

    // ─── Fixture helpers ──────────────────────────────────────────────────────

    /// Sets up the full registry in a single call.
    ///
    /// `tranche_factory::init_for_testing` internally creates the
    /// `TrancheAdminCap` and the shared `TrancheRegistry` (using each coin
    /// module's `create_treasury_for_testing` bypass) — mirroring what the
    /// production `init` does via the parking-object handoff, but without
    /// needing parking wrappers or an explicit two-step flow.
    ///
    /// Must be called immediately after `ts::begin`, before any other
    /// `next_tx` call in the test body.
    fun setup(scenario: &mut Scenario) {
        tranche_factory::init_for_testing(ts::ctx(scenario));
    }

    /// Calls create_tranches with standard caps. Advances one transaction.
    fun setup_and_create(scenario: &mut Scenario, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                ISSUANCE_CONTRACT,
                clock,
                ts::ctx(scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(scenario, cap);
        };
    }

    /// Mints `amount` of `tranche_type` to `recipient` via IssuanceAdminCap.
    fun mint_tokens(
        scenario:     &mut Scenario,
        clock:        &Clock,
        tranche_type: u8,
        amount:       u64,
        recipient:    address,
    ) {
        ts::next_tx(scenario, ISSUANCE_CONTRACT);
        {
            let iac     = ts::take_from_sender<IssuanceAdminCap>(scenario);
            let mut reg = ts::take_shared<TrancheRegistry>(scenario);
            tranche_factory::mint(
                &iac, &mut reg,
                tranche_type, amount, recipient,
                clock,
                ts::ctx(scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(scenario, iac);
        };
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. Post-init state
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// After init_for_testing: all counters zero, minting disabled, admin cap delivered.
    fun test_init_state() {
        let mut scenario = ts::begin(ADMIN);
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);

            // spec variables: mintingEnabled == false before createTranches
            assert!(!tranche_factory::minting_enabled(&reg),           0);
            assert!(!tranche_factory::tranches_created(&reg),          1);

            // spec variables: supply caps and minted counters all zero
            assert!(tranche_factory::senior_supply_cap(&reg) == 0,     2);
            assert!(tranche_factory::mezz_supply_cap(&reg)   == 0,     3);
            assert!(tranche_factory::junior_supply_cap(&reg) == 0,     4);
            assert!(tranche_factory::senior_minted(&reg)     == 0,     5);
            assert!(tranche_factory::mezz_minted(&reg)       == 0,     6);
            assert!(tranche_factory::junior_minted(&reg)     == 0,     7);

            ts::return_shared(reg);

            // Admin cap must land in deployer's inventory
            assert!(ts::has_most_recent_for_sender<TrancheAdminCap>(&scenario), 8);
        };

        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. createTranches — happy path
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// Supply caps stored, mintingEnabled becomes true, remaining == cap.
    fun test_create_tranches_sets_caps_and_enables_minting() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);

            // spec: mintingEnabled == true after createTranches
            assert!(tranche_factory::minting_enabled(&reg),                 0);
            assert!(tranche_factory::tranches_created(&reg),                1);

            // spec: seniorSupplyCap / mezzSupplyCap / juniorSupplyCap
            assert!(tranche_factory::senior_supply_cap(&reg) == SENIOR_CAP, 2);
            assert!(tranche_factory::mezz_supply_cap(&reg)   == MEZZ_CAP,   3);
            assert!(tranche_factory::junior_supply_cap(&reg) == JUNIOR_CAP, 4);

            // remaining capacity == cap when nothing minted yet
            assert!(tranche_factory::senior_remaining(&reg) == SENIOR_CAP,  5);
            assert!(tranche_factory::mezz_remaining(&reg)   == MEZZ_CAP,    6);
            assert!(tranche_factory::junior_remaining(&reg) == JUNIOR_CAP,  7);

            // spec: authorizedIssuanceContract stored
            assert!(tranche_factory::issuance_contract(&reg) == ISSUANCE_CONTRACT, 8);

            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// IssuanceAdminCap (= authorizedIssuanceContract capability) must be
    /// delivered to the issuance contract address after createTranches.
    fun test_create_tranches_sends_issuance_admin_cap() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ISSUANCE_CONTRACT);
        {
            assert!(ts::has_most_recent_for_sender<IssuanceAdminCap>(&scenario), 0);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. createTranches — abort guards
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = securitization::errors::ETranchesAlreadyCreated, location = securitization::tranche_factory)]
    /// Spec: callable once. Second call must abort.
    fun test_create_tranches_twice_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                ISSUANCE_CONTRACT, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroSupplyCap, location = securitization::tranche_factory)]
    fun test_create_tranches_zero_senior_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                0, MEZZ_CAP, JUNIOR_CAP,          // ← zero senior cap
                ISSUANCE_CONTRACT, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroSupplyCap, location = securitization::tranche_factory)]
    fun test_create_tranches_zero_mezz_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, 0, JUNIOR_CAP,        // ← zero mezz cap
                ISSUANCE_CONTRACT, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EZeroSupplyCap, location = securitization::tranche_factory)]
    fun test_create_tranches_zero_junior_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, MEZZ_CAP, 0,          // ← zero junior cap
                ISSUANCE_CONTRACT, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ENotIssuanceContract, location = securitization::tranche_factory)]
    /// spec: authorizedIssuanceContract must not be the zero address.
    fun test_create_tranches_zero_issuance_address_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                @0x0,                              // ← zero address
                &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. mint() — happy paths
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// spec: mint updates seniorMinted and remaining capacity.
    fun test_mint_senior_updates_counters() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let amount = 100_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), amount, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::senior_minted(&reg)    == amount,              0);
            assert!(tranche_factory::senior_remaining(&reg) == SENIOR_CAP - amount, 1);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// spec: mint updates mezzMinted and remaining capacity.
    fun test_mint_mezz_updates_counters() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let amount = 50_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(), amount, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::mezz_minted(&reg)    == amount,            0);
            assert!(tranche_factory::mezz_remaining(&reg) == MEZZ_CAP - amount, 1);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// spec: mint updates juniorMinted and remaining capacity.
    fun test_mint_junior_updates_counters() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let amount = 25_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_junior(), amount, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::junior_minted(&reg)    == amount,              0);
            assert!(tranche_factory::junior_remaining(&reg) == JUNIOR_CAP - amount, 1);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// Mint exactly to the supply cap — boundary must succeed.
    fun test_mint_senior_exactly_at_cap() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), SENIOR_CAP, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::senior_minted(&reg)    == SENIOR_CAP, 0);
            assert!(tranche_factory::senior_remaining(&reg) == 0,          1);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// spec: mint delivers Coin<SENIOR_COIN> to `recipient`.
    fun test_mint_delivers_coin_to_recipient() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let amount = 100_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), amount, INVESTOR);

        ts::next_tx(&mut scenario, INVESTOR);
        {
            // Coin type is now SENIOR_COIN from the external coin module
            let coin = ts::take_from_sender<Coin<SENIOR_COIN>>(&scenario);
            assert!(coin::value(&coin) == amount, 0);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// All three tranche counters are independent of one another.
    fun test_mint_all_three_tranches_independent() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let s_amt = 100_000_000u64;
        let m_amt =  50_000_000u64;
        let j_amt =  25_000_000u64;

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), s_amt, INVESTOR);
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(),   m_amt, INVESTOR);
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_junior(), j_amt, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::senior_minted(&reg)    == s_amt,              0);
            assert!(tranche_factory::mezz_minted(&reg)      == m_amt,              1);
            assert!(tranche_factory::junior_minted(&reg)    == j_amt,              2);
            assert!(tranche_factory::senior_remaining(&reg) == SENIOR_CAP - s_amt, 3);
            assert!(tranche_factory::mezz_remaining(&reg)   == MEZZ_CAP   - m_amt, 4);
            assert!(tranche_factory::junior_remaining(&reg) == JUNIOR_CAP  - j_amt, 5);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. mint() — abort guards
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = securitization::errors::EMintingDisabled, location = securitization::tranche_factory)]
    /// spec: mint checks mintingEnabled.
    /// Disables minting right after first successful mint, verifies second aborts.
    fun test_mint_while_minting_disabled_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        // First mint succeeds
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), 1, INVESTOR);

        // Admin disables minting (spec: disableMinting is irreversible)
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::disable_minting(&cap, &mut reg, &clock);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        // Second mint must abort with EMintingDisabled
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ESupplyCapExceeded, location = securitization::tranche_factory)]
    /// spec: mint checks supply cap — one token over must abort.
    fun test_mint_senior_exceeds_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), SENIOR_CAP, INVESTOR);
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ESupplyCapExceeded, location = securitization::tranche_factory)]
    fun test_mint_mezz_exceeds_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(), MEZZ_CAP, INVESTOR);
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(), 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::ESupplyCapExceeded, location = securitization::tranche_factory)]
    fun test_mint_junior_exceeds_cap_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_junior(), JUNIOR_CAP, INVESTOR);
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_junior(), 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EUnknownTrancheType, location = securitization::tranche_factory)]
    fun test_mint_unknown_tranche_type_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, 99u8, 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EMintingDisabled, location = securitization::tranche_factory)]
    /// spec: disableMinting is irreversible — mint must abort after it.
    fun test_mint_after_disable_minting_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::disable_minting(&cap, &mut reg, &clock);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), 1, INVESTOR);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  6. melt() — happy paths
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// spec: melt reduces seniorMinted counter by the burned amount.
    fun test_melt_senior_partial_reduces_counter() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let mint_amt = 200_000_000u64;
        let burn_amt = 100_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), mint_amt, INVESTOR);

        ts::next_tx(&mut scenario, INVESTOR);
        {
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            let mut coin = ts::take_from_sender<Coin<SENIOR_COIN>>(&scenario);
            let burn     = coin::split(&mut coin, burn_amt, ts::ctx(&mut scenario));
            tranche_factory::melt_senior(&mut reg, burn, &clock);
            assert!(tranche_factory::senior_minted(&reg) == mint_amt - burn_amt, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// spec: melt reduces mezzMinted counter.
    fun test_melt_mezz_partial_reduces_counter() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let mint_amt = 100_000_000u64;
        let burn_amt =  50_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(), mint_amt, INVESTOR);

        ts::next_tx(&mut scenario, INVESTOR);
        {
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            let mut coin = ts::take_from_sender<Coin<MEZZ_COIN>>(&scenario);
            let burn     = coin::split(&mut coin, burn_amt, ts::ctx(&mut scenario));
            tranche_factory::melt_mezz(&mut reg, burn, &clock);
            assert!(tranche_factory::mezz_minted(&reg) == mint_amt - burn_amt, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// spec: melt reduces juniorMinted counter.
    fun test_melt_junior_partial_reduces_counter() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let mint_amt = 50_000_000u64;
        let burn_amt = 25_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_junior(), mint_amt, INVESTOR);

        ts::next_tx(&mut scenario, INVESTOR);
        {
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            let mut coin = ts::take_from_sender<Coin<JUNIOR_COIN>>(&scenario);
            let burn     = coin::split(&mut coin, burn_amt, ts::ctx(&mut scenario));
            tranche_factory::melt_junior(&mut reg, burn, &clock);
            assert!(tranche_factory::junior_minted(&reg) == mint_amt - burn_amt, 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// Burn the entire minted supply — counter reaches zero.
    fun test_melt_senior_full_supply_zeroes_counter() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), SENIOR_CAP, INVESTOR);

        ts::next_tx(&mut scenario, INVESTOR);
        {
            let mut reg = ts::take_shared<TrancheRegistry>(&scenario);
            let coin    = ts::take_from_sender<Coin<SENIOR_COIN>>(&scenario);
            tranche_factory::melt_senior(&mut reg, coin, &clock);
            assert!(tranche_factory::senior_minted(&reg) == 0, 0);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// Melt all → re-mint to cap: freed capacity must be reusable.
    /// Validates that minted counter correctly tracks burn-then-remint.
    fun test_melt_then_remint_restores_capacity() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        // Fill cap
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), SENIOR_CAP, INVESTOR);

        // Burn all
        ts::next_tx(&mut scenario, INVESTOR);
        {
            let mut reg = ts::take_shared<TrancheRegistry>(&scenario);
            let coin    = ts::take_from_sender<Coin<SENIOR_COIN>>(&scenario);
            tranche_factory::melt_senior(&mut reg, coin, &clock);
            ts::return_shared(reg);
        };

        // Re-mint to cap — must succeed
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_senior(), SENIOR_CAP, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::senior_minted(&reg) == SENIOR_CAP, 0);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  7. disableMinting()
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// spec: disableMinting sets mintingEnabled to false. Irreversible.
    fun test_disable_minting_sets_flag() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::minting_enabled(&reg), 0); // sanity
            tranche_factory::disable_minting(&cap, &mut reg, &clock);
            assert!(!tranche_factory::minting_enabled(&reg), 1);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  8. getTrancheInfo() — struct fields
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    /// spec: getTrancheInfo returns tokenID, supply cap, amount minted,
    /// remaining capacity, and current mint status.
    fun test_get_tranche_info_senior_before_any_mint() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg  = ts::take_shared<TrancheRegistry>(&scenario);
            let info = tranche_factory::get_tranche_info(&reg, tranche_factory::tranche_senior());

            assert!(tranche_factory::info_tranche_type(&info)  == tranche_factory::tranche_senior(), 0);
            assert!(tranche_factory::info_supply_cap(&info)    == SENIOR_CAP,  1);
            assert!(tranche_factory::info_amount_minted(&info) == 0,           2);
            assert!(tranche_factory::info_remaining(&info)     == SENIOR_CAP,  3);
            assert!(tranche_factory::info_minting_active(&info),               4);

            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// getTrancheInfo reflects minted amount and reduced remaining after a mint.
    fun test_get_tranche_info_mezz_after_partial_mint() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        let amount = 50_000_000u64;
        mint_tokens(&mut scenario, &clock, tranche_factory::tranche_mezz(), amount, INVESTOR);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg  = ts::take_shared<TrancheRegistry>(&scenario);
            let info = tranche_factory::get_tranche_info(&reg, tranche_factory::tranche_mezz());

            assert!(tranche_factory::info_supply_cap(&info)    == MEZZ_CAP,          0);
            assert!(tranche_factory::info_amount_minted(&info) == amount,            1);
            assert!(tranche_factory::info_remaining(&info)     == MEZZ_CAP - amount, 2);
            assert!(tranche_factory::info_minting_active(&info),                     3);

            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    /// getTrancheInfo shows minting_active == false after disableMinting.
    fun test_get_tranche_info_reflects_minting_disabled() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario);
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::disable_minting(&cap, &mut reg, &clock);
            let info = tranche_factory::get_tranche_info(&reg, tranche_factory::tranche_junior());
            assert!(!tranche_factory::info_minting_active(&info), 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EUnknownTrancheType, location = securitization::tranche_factory)]
    /// getTrancheInfo must abort on unknown tranche type.
    fun test_get_tranche_info_unknown_type_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            let _   = tranche_factory::get_tranche_info(&reg, 99u8);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  9. Access control
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    #[expected_failure(abort_code = iota::test_scenario::EEmptyInventory, location = iota::test_scenario)]
    /// STRANGER has no TrancheAdminCap → take_from_sender aborts.
    fun test_stranger_cannot_call_create_tranches() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, STRANGER);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario); // aborts here
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::create_tranches(
                &cap, &mut reg,
                SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
                ISSUANCE_CONTRACT, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = iota::test_scenario::EEmptyInventory, location = iota::test_scenario)]
    /// spec: only authorizedIssuanceContract may call mint.
    /// STRANGER has no IssuanceAdminCap → take_from_sender aborts.
    fun test_stranger_cannot_call_mint() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, STRANGER);
        {
            let iac     = ts::take_from_sender<IssuanceAdminCap>(&scenario); // aborts here
            let mut reg = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::mint(
                &iac, &mut reg,
                tranche_factory::tranche_senior(), 1, STRANGER,
                &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, iac);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = iota::test_scenario::EEmptyInventory, location = iota::test_scenario)]
    /// STRANGER has no TrancheAdminCap → cannot call disableMinting.
    fun test_stranger_cannot_disable_minting() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, STRANGER);
        {
            let cap      = ts::take_from_sender<TrancheAdminCap>(&scenario); // aborts here
            let mut reg  = ts::take_shared<TrancheRegistry>(&scenario);
            tranche_factory::disable_minting(&cap, &mut reg, &clock);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  10. Read-only accessors and type constants
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_tranche_type_constants() {
        assert!(tranche_factory::tranche_senior() == 0, 0);
        assert!(tranche_factory::tranche_mezz()   == 1, 1);
        assert!(tranche_factory::tranche_junior()  == 2, 2);
    }

    #[test]
    /// issuance_contract accessor reflects the value set by createTranches.
    fun test_issuance_contract_accessor() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        setup_and_create(&mut scenario, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<TrancheRegistry>(&scenario);
            assert!(tranche_factory::issuance_contract(&reg) == ISSUANCE_CONTRACT, 0);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
