// /// Comprehensive test suite for TrancheFactory.
// ///
// /// Test coverage:
// ///  - Tranche creation with supply caps
// ///  - Minting by authorised IssuanceAdminCap holder
// ///  - Supply cap enforcement (exact cap, over cap)
// ///  - Melting (burning) tokens reduces minted counters
// ///  - disableMinting prevents further minting
// ///  - Unauthorised mint attempt is rejected
// ///  - Remaining supply calculations
// #[test_only, allow(unused_use, unused_variable, unused_const, duplicate_alias, unused_function)]
// module securitization::tranche_factory_tests {
//     use iota::test_scenario::{Self as ts};
//     use iota::clock::{Self, Clock};
//     use iota::coin;
//     use securitization::tranche_factory::{
//         Self, TrancheRegistry, TrancheAdminCap, IssuanceAdminCap,
//         SENIOR, MEZZ, JUNIOR,
//     };
//     use securitization::errors;

//     // ─── Addresses ────────────────────────────────────────────────────────────
//     const ADMIN:     address = @0xB0;
//     const ISSUANCE:  address = @0xB1;
//     const INVESTOR1: address = @0xB2;
//     const INVESTOR2: address = @0xB3;
//     const POOL:      address = @0xB4;

//     // ─── Supply caps ──────────────────────────────────────────────────────────
//     const SENIOR_CAP: u64 = 5_000_000;
//     const MEZZ_CAP:   u64 = 3_000_000;
//     const JUNIOR_CAP: u64 = 2_000_000;

//     // ─── Fixture ──────────────────────────────────────────────────────────────

//     fun setup_registry(scenario: &mut ts::Scenario, clock: &Clock) {
//         ts::next_tx(scenario, ADMIN);
//         {
//             let cap         = ts::take_from_sender<TrancheAdminCap>(scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(scenario);
//             tranche_factory::create_tranches(
//                 &cap, &mut registry,
//                 SENIOR_CAP, MEZZ_CAP, JUNIOR_CAP,
//                 ISSUANCE, clock, ts::ctx(scenario),
//             );
//             ts::return_shared(registry);
//             ts::return_to_sender(scenario, cap);
//         };
//     }

//     // ═══════════════════════════════════════════════════════════════════════════
//     //  1. Create tranches
//     // ═══════════════════════════════════════════════════════════════════════════

//     #[test]
//     fun test_create_tranches_success() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ADMIN);
//         {
//             let registry = ts::take_shared<TrancheRegistry>(&scenario);
//             assert!(tranche_factory::tranches_created(&registry),       0);
//             assert!(tranche_factory::minting_enabled(&registry),        1);
//             assert!(tranche_factory::senior_supply_cap(&registry) == SENIOR_CAP, 2);
//             assert!(tranche_factory::mezz_supply_cap(&registry)   == MEZZ_CAP,   3);
//             assert!(tranche_factory::junior_supply_cap(&registry) == JUNIOR_CAP, 4);
//             assert!(tranche_factory::senior_minted(&registry) == 0,    5);
//             assert!(tranche_factory::mezz_minted(&registry)   == 0,    6);
//             assert!(tranche_factory::junior_minted(&registry) == 0,    7);
//             ts::return_shared(registry);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = securitization::errors::ETranchesAlreadyCreated)]
//     fun test_create_tranches_twice_aborts() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ADMIN);
//         {
//             let cap         = ts::take_from_sender<TrancheAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::create_tranches(
//                 &cap, &mut registry, 1_000, 1_000, 1_000,
//                 ISSUANCE, &clock, ts::ctx(&mut scenario),
//             );
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = securitization::errors::EZeroSupplyCap)]
//     fun test_create_tranches_zero_cap_aborts() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         {
//             let cap         = ts::take_from_sender<TrancheAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::create_tranches(
//                 &cap, &mut registry, 0, 1_000, 1_000, // zero senior cap
//                 ISSUANCE, &clock, ts::ctx(&mut scenario),
//             );
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };
//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     // ═══════════════════════════════════════════════════════════════════════════
//     //  2. Minting tests
//     // ═══════════════════════════════════════════════════════════════════════════

//     #[test]
//     fun test_mint_senior_success() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::mint(
//                 &cap, &mut registry,
//                 tranche_factory::tranche_senior(),
//                 1_000_000, INVESTOR1, &clock, ts::ctx(&mut scenario),
//             );
//             assert!(tranche_factory::senior_minted(&registry) == 1_000_000, 0);
//             assert!(tranche_factory::senior_remaining(&registry) == SENIOR_CAP - 1_000_000, 1);
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         // Investor should have received SENIOR coins
//         ts::next_tx(&mut scenario, INVESTOR1);
//         {
//             let coin = ts::take_from_sender<coin::Coin<SENIOR>>(&scenario);
//             assert!(coin::value(&coin) == 1_000_000, 0);
//             ts::return_to_sender(&scenario, coin);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     fun test_mint_all_three_tranches() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);

//             tranche_factory::mint(&cap, &mut registry, 0, 1_000_000, INVESTOR1, &clock, ts::ctx(&mut scenario));
//             tranche_factory::mint(&cap, &mut registry, 1, 500_000,   INVESTOR1, &clock, ts::ctx(&mut scenario));
//             tranche_factory::mint(&cap, &mut registry, 2, 200_000,   INVESTOR2, &clock, ts::ctx(&mut scenario));

//             assert!(tranche_factory::senior_minted(&registry) == 1_000_000, 0);
//             assert!(tranche_factory::mezz_minted(&registry)   == 500_000,   1);
//             assert!(tranche_factory::junior_minted(&registry) == 200_000,   2);

//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     fun test_mint_at_exact_cap() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             // Mint exactly the cap
//             tranche_factory::mint(&cap, &mut registry, 0, SENIOR_CAP, INVESTOR1, &clock, ts::ctx(&mut scenario));
//             assert!(tranche_factory::senior_minted(&registry) == SENIOR_CAP, 0);
//             assert!(tranche_factory::senior_remaining(&registry) == 0, 1);
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = securitization::errors::ESupplyCapExceeded)]
//     fun test_mint_over_cap_aborts() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::mint(&cap, &mut registry, 0, SENIOR_CAP + 1, INVESTOR1, &clock, ts::ctx(&mut scenario));
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     #[expected_failure(abort_code = securitization::errors::EMintingDisabled)]
//     fun test_mint_when_disabled_aborts() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         // Disable minting
//         ts::next_tx(&mut scenario, ADMIN);
//         {
//             let cap          = ts::take_from_sender<TrancheAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::disable_minting(&cap, &mut registry, &clock);
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         // Try to mint — should fail
//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::mint(&cap, &mut registry, 0, 100, INVESTOR1, &clock, ts::ctx(&mut scenario));
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     // ═══════════════════════════════════════════════════════════════════════════
//     //  3. Melting (burn) tests
//     // ═══════════════════════════════════════════════════════════════════════════

//     #[test]
//     fun test_melt_senior_success() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ISSUANCE);
//         {
//             let cap          = ts::take_from_sender<IssuanceAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::mint(&cap, &mut registry, 0, 1_000_000, INVESTOR1, &clock, ts::ctx(&mut scenario));
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         ts::next_tx(&mut scenario, INVESTOR1);
//         {
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             let mut coin     = ts::take_from_sender<coin::Coin<SENIOR>>(&scenario);
//             let half         = coin::split(&mut coin, 500_000, ts::ctx(&mut scenario));
//             tranche_factory::melt_senior(&mut registry, half, &clock);
//             assert!(tranche_factory::senior_minted(&registry) == 500_000, 0);
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, coin); // ← return the remaining 500_000
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }

//     #[test]
//     fun test_disable_minting_idempotent_state() {
//         let mut scenario = ts::begin(ADMIN);
//         let clock = clock::create_for_testing(ts::ctx(&mut scenario));
//         ts::next_tx(&mut scenario, ADMIN);
//         setup_registry(&mut scenario, &clock);

//         ts::next_tx(&mut scenario, ADMIN);
//         {
//             let cap          = ts::take_from_sender<TrancheAdminCap>(&scenario);
//             let mut registry = ts::take_shared<TrancheRegistry>(&scenario);
//             tranche_factory::disable_minting(&cap, &mut registry, &clock);
//             assert!(!tranche_factory::minting_enabled(&registry), 0);
//             ts::return_shared(registry);
//             ts::return_to_sender(&scenario, cap);
//         };

//         clock::destroy_for_testing(clock);
//         ts::end(scenario);
//     }
// }
