/// # SeniorCoin
///
/// Defines the one-time witness `SENIOR_COIN` used to create the Senior
/// tranche fungible token via `coin::create_currency`.
///
/// Separating the OTW into its own module means `TrancheFactory` no longer
/// needs to own the witness struct, satisfying the IOTA Move requirement that
/// the OTW type and the `init` that consumes it live in the *same* module.
///
/// ## Integration
/// `tranche_factory` imports `SENIOR_COIN` as a phantom type parameter when
/// calling `coin::create_currency` inside this module's `init`.  The resulting
/// `TreasuryCap<SENIOR_COIN>` is transferred to `TrancheRegistry` via a
/// public entry that can only be called once (guarded by the OTW liveness).
#[allow(duplicate_alias, unused_use)]
module securitization::senior_coin {
    use iota::coin::{Self, TreasuryCap, CoinMetadata};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};

    // ─── One-time witness ─────────────────────────────────────────────────────

    /// The OTW for the Senior tranche token.
    /// Must be the module name in ALL_CAPS — enforced by the IOTA VM.
    public struct SENIOR_COIN has drop {}

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Runs once on publish.  Creates the `SENIOR_COIN` currency and transfers:
    ///   - `TreasuryCap<SENIOR_COIN>` → deployer  (picked up by TrancheFactory)
    ///   - `CoinMetadata<SENIOR_COIN>` → frozen shared object
    fun init(witness: SENIOR_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,                                          // decimals
            b"SENIOR",                                  // symbol
            b"Senior Tranche Token",                    // name
            b"IOTA Securitization – Senior Tranche",    // description
            option::none(),                             // icon url
            ctx,
        );

        // Freeze metadata — nobody may mutate it after publication.
        transfer::public_freeze_object(metadata);

        // Send the treasury cap to the deployer so TrancheFactory can collect it.
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    /// Returns a `TreasuryCap<SENIOR_COIN>` built with the test-only bypass,
    /// which skips the `is_one_time_witness` VM check.
    /// Use this in test modules instead of calling `init` directly.
    #[test_only]
    public fun create_treasury_for_testing(
        ctx: &mut TxContext,
    ): TreasuryCap<SENIOR_COIN> {
        coin::create_treasury_cap_for_testing<SENIOR_COIN>(ctx)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let treasury_cap = coin::create_treasury_cap_for_testing<SENIOR_COIN>(ctx);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }
}
