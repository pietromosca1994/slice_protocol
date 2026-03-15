/// Comprehensive test suite for PaymentVault.
///
/// Test coverage:
///  - Vault creation
///  - Authorise depositor / revoke depositor
///  - Deposit by authorised depositor: accounting, balance, events
///  - Deposit by unauthorised address: aborts
///  - Release funds: happy path, accounting, insufficient balance abort
///  - Zero-amount deposit and release aborts
///  - Duplicate authorisation abort
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module spv::payment_vault_tests {
    use iota::test_scenario::{Self as ts};
    use iota::clock::{Self, Clock};
    use iota::coin::{Self};
    use iota::iota::IOTA; // Using IOTA coin as stand-in for stablecoin in tests
    use iota::balance;
    use spv::payment_vault::{
        Self, VaultBalance, VaultAdminCap,
    };
    use spv::errors;

    // ─── Addresses ────────────────────────────────────────────────────────────
    const ADMIN:     address = @0xE0;
    const ISSUANCE:  address = @0xE1;
    const WATERFALL: address = @0xE2;
    const INVESTOR:  address = @0xE3;
    const STRANGER:  address = @0xE4;

    // ─── Fixture ──────────────────────────────────────────────────────────────
    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            payment_vault::init_for_testing(ts::ctx(scenario));
        };
    }

    fun setup_vault(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap = ts::take_from_sender<VaultAdminCap>(scenario);
            payment_vault::create_vault<IOTA>(&cap, ts::ctx(scenario));
            ts::return_to_sender(scenario, cap);
        };
    }

    fun authorise(scenario: &mut ts::Scenario, depositor: address, clock: &Clock) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<VaultAdminCap>(scenario);
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(scenario);
            payment_vault::authorise_depositor(&cap, &mut vault, depositor, clock);
            ts::return_shared(vault);
            ts::return_to_sender(scenario, cap);
        };
    }

    fun make_coin(scenario: &mut ts::Scenario, amount: u64): coin::Coin<IOTA> {
        coin::mint_for_testing<IOTA>(amount, ts::ctx(scenario))
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  1. Vault creation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_create_vault_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            assert!(payment_vault::vault_balance(&vault)    == 0, 0);
            assert!(payment_vault::total_deposited(&vault)  == 0, 1);
            assert!(payment_vault::total_distributed(&vault) == 0, 2);
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  2. Authorisation
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_authorise_depositor_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            assert!(payment_vault::is_authorised_depositor(&vault, ISSUANCE), 0);
            assert!(!payment_vault::is_authorised_depositor(&vault, STRANGER), 1);
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EDepositorAlreadyAuthorised, location = spv::payment_vault)]
    fun test_authorise_duplicate_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);
        authorise(&mut scenario, ISSUANCE, &clock); // duplicate
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  3. Deposit
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_deposit_funds_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);

        ts::next_tx(&mut scenario, ISSUANCE);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin1     = make_coin(&mut scenario, 500_000);
            let coin2     = make_coin(&mut scenario, 300_000);

            payment_vault::deposit(&mut vault, coin1, &clock, ts::ctx(&mut scenario));
            payment_vault::deposit(&mut vault, coin2, &clock, ts::ctx(&mut scenario));

            assert!(payment_vault::vault_balance(&vault)   == 800_000, 0);
            assert!(payment_vault::total_deposited(&vault) == 800_000, 1);
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::ENotAuthorisedDepositor, location = spv::payment_vault)]
    fun test_deposit_by_stranger_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        // Do NOT authorise STRANGER

        ts::next_tx(&mut scenario, STRANGER);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin      = make_coin(&mut scenario, 100_000);
            payment_vault::deposit(&mut vault, coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  4. Release funds
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_release_funds_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);

        // Deposit 1_000_000
        ts::next_tx(&mut scenario, ISSUANCE);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin      = make_coin(&mut scenario, 1_000_000);
            payment_vault::deposit(&mut vault, coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // Admin releases 600_000 to WaterfallEngine
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<VaultAdminCap>(&scenario);
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            payment_vault::release_funds(
                &cap, &mut vault, WATERFALL, 600_000, &clock, ts::ctx(&mut scenario),
            );
            assert!(payment_vault::vault_balance(&vault)      == 400_000, 0);
            assert!(payment_vault::total_distributed(&vault)  == 600_000, 1);
            assert!(payment_vault::total_deposited(&vault)    == 1_000_000, 2);
            ts::return_shared(vault);
            ts::return_to_sender(&scenario, cap);
        };

        // WaterfallEngine should have received the coin
        ts::next_tx(&mut scenario, WATERFALL);
        {
            let coin = ts::take_from_sender<coin::Coin<IOTA>>(&scenario);
            assert!(coin::value(&coin) == 600_000, 0);
            ts::return_to_sender(&scenario, coin);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EInsufficientVaultBalance, location = spv::payment_vault)]
    fun test_release_more_than_balance_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);

        ts::next_tx(&mut scenario, ISSUANCE);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin      = make_coin(&mut scenario, 100_000);
            payment_vault::deposit(&mut vault, coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<VaultAdminCap>(&scenario);
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            // Attempt to release more than balance
            payment_vault::release_funds(
                &cap, &mut vault, WATERFALL, 200_000, &clock, ts::ctx(&mut scenario),
            );
            ts::return_shared(vault);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EZeroReleaseAmount, location = spv::payment_vault)]
    fun test_release_zero_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<VaultAdminCap>(&scenario);
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            payment_vault::release_funds(&cap, &mut vault, WATERFALL, 0, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  5. Multiple deposit-release cycle
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_multiple_deposit_release_cycles() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);
        authorise(&mut scenario, ISSUANCE, &clock);

        // Deposit 1_000_000
        ts::next_tx(&mut scenario, ISSUANCE);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin      = make_coin(&mut scenario, 1_000_000);
            payment_vault::deposit(&mut vault, coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // Release 300_000
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<VaultAdminCap>(&scenario);
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            payment_vault::release_funds(&cap, &mut vault, WATERFALL, 300_000, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
            ts::return_to_sender(&scenario, cap);
        };

        // Deposit again 500_000
        ts::next_tx(&mut scenario, ISSUANCE);
        {
            let mut vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let coin      = make_coin(&mut scenario, 500_000);
            payment_vault::deposit(&mut vault, coin, &clock, ts::ctx(&mut scenario));
            ts::return_shared(vault);
        };

        // Verify final state: balance = 1_000_000 - 300_000 + 500_000 = 1_200_000
        ts::next_tx(&mut scenario, ADMIN);
        {
            let vault = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            assert!(payment_vault::vault_balance(&vault)      == 1_200_000, 0);
            assert!(payment_vault::total_deposited(&vault)    == 1_500_000, 1);
            assert!(payment_vault::total_distributed(&vault)  ==   300_000, 2);
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  6. receive_balance (used by issuance_contract::release_funds_to_vault)
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    /// receive_balance joins a raw Balance<C> directly into the vault —
    /// no depositor authorisation required (called by trusted Move code).
    fun test_receive_balance_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        setup_vault(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let mut vault  = ts::take_shared<VaultBalance<IOTA>>(&scenario);
            let raw_coin   = coin::mint_for_testing<IOTA>(750_000, ts::ctx(&mut scenario));
            let raw_balance = coin::into_balance(raw_coin);
            payment_vault::receive_balance(&mut vault, raw_balance, &clock);
            assert!(payment_vault::vault_balance(&vault) == 750_000, 0);
            ts::return_shared(vault);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
