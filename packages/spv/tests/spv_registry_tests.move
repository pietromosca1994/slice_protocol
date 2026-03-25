/// Comprehensive test suite for SPVRegistry.
///
/// Test coverage:
///  - register_pool: happy path, pool_count increment, per-SPV index
///  - register_pool: duplicate pool_obj_id aborts
///  - register_pool: duplicate pool_id (business string) aborts
///  - pool_exists, pool_id_taken, all_pool_ids, pools_for_spv accessors
///  - get_pool_entry: field correctness, unknown pool aborts
///  - deactivate_pool / reactivate_pool: state transitions, unknown pool aborts
#[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
module spv::spv_registry_tests {
    use iota::test_scenario::{Self as ts};
    use iota::clock::{Self, Clock};
    use iota::object;
    use spv::spv_registry::{
        Self, SPVRegistry, SPVRegistryAdminCap, PoolEntry,
    };
    use spv::errors;

    // ─── Addresses ────────────────────────────────────────────────────────────
    const ADMIN: address = @0xF0;
    const SPV1:  address = @0xF1;
    const SPV2:  address = @0xF2;
    const PKG:   address = @0xAF;

    // ─── Fixture ──────────────────────────────────────────────────────────────

    fun setup(scenario: &mut ts::Scenario) {
        ts::next_tx(scenario, ADMIN);
        {
            spv_registry::init_for_testing(ts::ctx(scenario));
        };
    }

    /// Register a pool directly (calls public register_pool).
    fun register(
        scenario:    &mut ts::Scenario,
        clock:       &Clock,
        pool_obj_id: object::ID,
        pool_id:     vector<u8>,
        spv:         address,
    ) {
        ts::next_tx(scenario, ADMIN);
        {
            let mut reg = ts::take_shared<SPVRegistry>(scenario);
            spv_registry::register_pool(&mut reg, pool_obj_id, pool_id, spv, PKG, clock, ts::ctx(scenario));
            ts::return_shared(reg);
        };
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  1. Post-init state
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_init_state() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(spv_registry::pool_count(&reg) == 0, 0);
            assert!(vector::length(spv_registry::all_pool_ids(&reg)) == 0, 1);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  2. register_pool
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_register_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id = object::id_from_address(@0xBB);
        register(&mut scenario, &clock, pool_obj_id, b"POOL-001", SPV1);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(spv_registry::pool_count(&reg) == 1,              0);
            assert!(spv_registry::pool_exists(&reg, pool_obj_id),     1);
            assert!(spv_registry::pool_id_taken(&reg, b"POOL-001"),   2);
            assert!(vector::length(spv_registry::all_pool_ids(&reg)) == 1, 3);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_register_two_pools_increments_count() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id_1 = object::id_from_address(@0xBB);
        let pool_obj_id_2 = object::id_from_address(@0xCC);
        register(&mut scenario, &clock, pool_obj_id_1, b"POOL-001", SPV1);
        register(&mut scenario, &clock, pool_obj_id_2, b"POOL-002", SPV2);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(spv_registry::pool_count(&reg) == 2, 0);
            assert!(spv_registry::pool_exists(&reg, pool_obj_id_1), 1);
            assert!(spv_registry::pool_exists(&reg, pool_obj_id_2), 2);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EPoolAlreadyRegistered, location = spv::spv_registry)]
    fun test_register_duplicate_pool_obj_id_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id = object::id_from_address(@0xBB);
        register(&mut scenario, &clock, pool_obj_id, b"POOL-001", SPV1);
        // Same object ID, different string pool_id → aborts on duplicate object ID
        register(&mut scenario, &clock, pool_obj_id, b"POOL-002", SPV1);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EPoolIdAlreadyExists, location = spv::spv_registry)]
    fun test_register_duplicate_pool_id_string_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        // Different object IDs but the same business pool_id string → aborts
        register(&mut scenario, &clock, object::id_from_address(@0xBB), b"POOL-001", SPV1);
        register(&mut scenario, &clock, object::id_from_address(@0xCC), b"POOL-001", SPV2);

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  3. Per-SPV index
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_pools_for_spv_returns_correct_ids() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id_1 = object::id_from_address(@0xBB);
        let pool_obj_id_2 = object::id_from_address(@0xCC);
        let pool_obj_id_3 = object::id_from_address(@0xDD);

        register(&mut scenario, &clock, pool_obj_id_1, b"POOL-001", SPV1);
        register(&mut scenario, &clock, pool_obj_id_2, b"POOL-002", SPV1); // same SPV
        register(&mut scenario, &clock, pool_obj_id_3, b"POOL-003", SPV2); // different SPV

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);

            let spv1_pools = spv_registry::pools_for_spv(&reg, SPV1);
            assert!(vector::length(&spv1_pools) == 2, 0);

            let spv2_pools = spv_registry::pools_for_spv(&reg, SPV2);
            assert!(vector::length(&spv2_pools) == 1, 1);

            // Unknown SPV returns empty list
            let spv3_pools = spv_registry::pools_for_spv(&reg, @0xF9);
            assert!(vector::length(&spv3_pools) == 0, 2);

            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  4. get_pool_entry accessors
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_get_pool_entry_fields() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id = object::id_from_address(@0xBB);
        register(&mut scenario, &clock, pool_obj_id, b"POOL-001", SPV1);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg   = ts::take_shared<SPVRegistry>(&scenario);
            let entry = spv_registry::get_pool_entry(&reg, pool_obj_id);

            assert!(spv_registry::entry_pool_obj_id(entry) == pool_obj_id, 0);
            assert!(spv_registry::entry_spv(entry)         == SPV1,        1);
            assert!(spv_registry::entry_active(entry),                      2);
            assert!(spv_registry::entry_securitization_package_id(entry) == PKG, 3);

            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EPoolNotRegistered, location = spv::spv_registry)]
    fun test_get_pool_entry_unknown_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg   = ts::take_shared<SPVRegistry>(&scenario);
            let _     = spv_registry::get_pool_entry(&reg, object::id_from_address(@0xBB));
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  5. deactivate_pool / reactivate_pool
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_deactivate_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id = object::id_from_address(@0xBB);
        register(&mut scenario, &clock, pool_obj_id, b"POOL-001", SPV1);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<SPVRegistryAdminCap>(&scenario);
            let mut reg   = ts::take_shared<SPVRegistry>(&scenario);
            spv_registry::deactivate_pool(&cap, &mut reg, pool_obj_id);
            let entry = spv_registry::get_pool_entry(&reg, pool_obj_id);
            assert!(!spv_registry::entry_active(entry), 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_reactivate_pool_success() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        let pool_obj_id = object::id_from_address(@0xBB);
        register(&mut scenario, &clock, pool_obj_id, b"POOL-001", SPV1);

        // Deactivate then reactivate
        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap       = ts::take_from_sender<SPVRegistryAdminCap>(&scenario);
            let mut reg   = ts::take_shared<SPVRegistry>(&scenario);
            spv_registry::deactivate_pool(&cap, &mut reg, pool_obj_id);
            spv_registry::reactivate_pool(&cap, &mut reg, pool_obj_id);
            let entry = spv_registry::get_pool_entry(&reg, pool_obj_id);
            assert!(spv_registry::entry_active(entry), 0);
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EPoolNotRegistered, location = spv::spv_registry)]
    fun test_deactivate_unknown_pool_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<SPVRegistryAdminCap>(&scenario);
            let mut reg = ts::take_shared<SPVRegistry>(&scenario);
            spv_registry::deactivate_pool(&cap, &mut reg, object::id_from_address(@0xBB));
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = spv::errors::EPoolNotRegistered, location = spv::spv_registry)]
    fun test_reactivate_unknown_pool_aborts() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let cap     = ts::take_from_sender<SPVRegistryAdminCap>(&scenario);
            let mut reg = ts::take_shared<SPVRegistry>(&scenario);
            spv_registry::reactivate_pool(&cap, &mut reg, object::id_from_address(@0xBB));
            ts::return_shared(reg);
            ts::return_to_sender(&scenario, cap);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    // ═════════════════════════════════════════════════════════════════════════
    //  6. pool_exists / pool_id_taken edge cases
    // ═════════════════════════════════════════════════════════════════════════

    #[test]
    fun test_pool_exists_returns_false_for_unknown() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(!spv_registry::pool_exists(&reg, object::id_from_address(@0xBB)), 0);
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }

    #[test]
    fun test_pool_id_taken_false_for_unknown_true_after_register() {
        let mut scenario = ts::begin(ADMIN);
        let clock = clock::create_for_testing(ts::ctx(&mut scenario));
        setup(&mut scenario);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(!spv_registry::pool_id_taken(&reg, b"POOL-001"), 0);
            ts::return_shared(reg);
        };

        register(&mut scenario, &clock, object::id_from_address(@0xBB), b"POOL-001", SPV1);

        ts::next_tx(&mut scenario, ADMIN);
        {
            let reg = ts::take_shared<SPVRegistry>(&scenario);
            assert!(spv_registry::pool_id_taken(&reg, b"POOL-001"),  0);
            assert!(!spv_registry::pool_id_taken(&reg, b"POOL-002"), 1); // different ID still free
            ts::return_shared(reg);
        };

        clock::destroy_for_testing(clock);
        ts::end(scenario);
    }
}
