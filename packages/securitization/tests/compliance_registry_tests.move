/// Comprehensive test suite for ComplianceRegistry.
///
/// Test coverage:
///  - Add investor: happy path, duplicate, invalid level, empty jurisdiction
///  - Remove investor: active→inactive, non-existent
///  - Transfer check: both parties whitelisted, sender not, recipient not,
///    sender deactivated, holding period not elapsed, restrictions disabled
///  - Accreditation level update
///  - Global restrictions toggle
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module securitization::compliance_registry_tests {
    use iota::test_scenario::{Self as ts};
    use iota::clock::{Self, Clock};
    use iota::object;
    use securitization::compliance_registry::{
        Self, ComplianceRegistry, ComplianceAdminCap,
    };
    use securitization::errors;

    // ─── Addresses ────────────────────────────────────────────────────────────
    const ADMIN:     address = @0xD0;
    const INVESTOR1: address = @0xD1;
    const INVESTOR2: address = @0xD2;
    const STRANGER:  address = @0xD3;

    // ─── Helpers ──────────────────────────────────────────────────────────────

    fun dummy_did(_ctx: &mut ts::Scenario): object::ID {
        // Generate a dummy object ID for DID document references
        object::id_from_address(@0xDEAD)
    }

    // publishes module, creates ComplianceAdminCap + ComplianceRegistry
    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            compliance_registry::init_for_testing(ts::ctx(scenario));
        };
    }

    fun add_investor_helper(
        scenario: &mut ts::Scenario,
        investor: address,
        clock: &Clock,
    ) {
        ts::next_tx(scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(scenario);
            compliance_registry::add_investor(
                &cap, &mut registry,
                investor,
                2,           // Professional
                b"US",
                object::id_from_address(@0xDEAD),
                0,           // use default holding period
                clock,
            );
            ts::return_shared(registry);
            ts::return_to_sender(scenario, cap);
        };
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  1. Add investor
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_add_investor_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            assert!(compliance_registry::is_whitelisted(&registry, INVESTOR1), 0);
            assert!(compliance_registry::accreditation_level(&registry, INVESTOR1) == 2, 1);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvestorAlreadyExists, location = securitization::compliance_registry)]
    fun test_add_duplicate_investor_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);
        // Add same investor again
        add_investor_helper(&mut scenario, INVESTOR1, &clock);
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvalidAccreditationLevel, location = securitization::compliance_registry)]
    fun test_add_investor_invalid_level_zero_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut registry, INVESTOR1,
                0, // invalid level
                b"US", object::id_from_address(@0xDEAD), 0, &clock,
            );
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvalidAccreditationLevel, location = securitization::compliance_registry)]
    fun test_add_investor_invalid_level_five_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut registry, INVESTOR1,
                5, // invalid level
                b"US", object::id_from_address(@0xDEAD), 0, &clock,
            );
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EEmptyJurisdiction, location = securitization::compliance_registry)]
    fun test_add_investor_empty_jurisdiction_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut registry, INVESTOR1,
                2, b"", // empty jurisdiction
                object::id_from_address(@0xDEAD), 0, &clock,
            );
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  2. Remove investor
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_remove_investor_deactivates() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::remove_investor(&cap, &mut registry, INVESTOR1, &clock);
            assert!(!compliance_registry::is_whitelisted(&registry, INVESTOR1), 0);
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = securitization::errors::EInvestorNotWhitelisted, location = securitization::compliance_registry)]
    fun test_remove_nonexistent_investor_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::remove_investor(&cap, &mut registry, STRANGER, &clock);
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };
        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  3. Transfer checks
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_transfer_allowed_both_whitelisted() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);
        add_investor_helper(&mut scenario, INVESTOR2, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            let result = compliance_registry::check_transfer_allowed(
                &registry, INVESTOR1, INVESTOR2, &clock,
            );
            assert!(compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_transfer_blocked_sender_not_whitelisted() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR2, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            let result = compliance_registry::check_transfer_allowed(
                &registry, STRANGER, INVESTOR2, &clock,
            );
            assert!(!compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_transfer_blocked_recipient_not_whitelisted() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            let result = compliance_registry::check_transfer_allowed(
                &registry, INVESTOR1, STRANGER, &clock,
            );
            assert!(!compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_transfer_blocked_by_holding_period() {
        let mut scenario = ts::begin(ADMIN);
        let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        clock::set_for_testing(&mut clock, 0);

        // Add investor with a 30-day holding period
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::add_investor(
                &cap, &mut registry, INVESTOR1, 2, b"US",
                object::id_from_address(@0xDEAD),
                30 * 24 * 3600 * 1000, // 30 days in ms
                &clock,
            );
            compliance_registry::add_investor(
                &cap, &mut registry, INVESTOR2, 2, b"US",
                object::id_from_address(@0xBEEF),
                0,
                &clock,
            );
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };

        // Try transfer before holding period ends
        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            let result = compliance_registry::check_transfer_allowed(
                &registry, INVESTOR1, INVESTOR2, &clock,
            );
            assert!(!compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        // Advance clock past holding period
        clock::set_for_testing(&mut clock, 31 * 24 * 3600 * 1000);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            let result = compliance_registry::check_transfer_allowed(
                &registry, INVESTOR1, INVESTOR2, &clock,
            );
            assert!(compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_transfer_allowed_when_restrictions_disabled() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);

        // Disable restrictions without adding any investors
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::set_transfer_restrictions(&cap, &mut registry, false, &clock);
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };

        ts::next_tx(&mut scenario, ADMIN);
        {
            let registry = ts::take_shared<ComplianceRegistry>(&scenario);
            // Neither party is whitelisted, but restrictions are off
            let result = compliance_registry::check_transfer_allowed(
                &registry, STRANGER, INVESTOR1, &clock,
            );
            assert!(compliance_registry::check_result_allowed(&result), 0);
            ts::return_shared(registry);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  4. Accreditation update
    // ═══════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_update_accreditation_level() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);
        ts::next_tx(&mut scenario, ADMIN);
        add_investor_helper(&mut scenario, INVESTOR1, &clock);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap          = ts::take_from_sender<ComplianceAdminCap>(&scenario);
            let mut registry = ts::take_shared<ComplianceRegistry>(&scenario);
            compliance_registry::update_accreditation(&cap, &mut registry, INVESTOR1, 4);
            assert!(compliance_registry::accreditation_level(&registry, INVESTOR1) == 4, 0);
            ts::return_shared(registry);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
