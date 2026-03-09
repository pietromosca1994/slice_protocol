/// # JuniorCoin
///
/// Defines the one-time witness `JUNIOR_COIN` used to create the Junior
/// tranche fungible token via `coin::create_currency`.
///
/// Separating the OTW into its own module means `TrancheFactory` no longer
/// needs to own the witness struct, satisfying the IOTA Move requirement that
/// the OTW type and the `init` that consumes it live in the *same* module.
///
/// ## Integration
/// `tranche_factory` imports `JUNIOR_COIN` as a phantom type parameter when
/// calling `coin::create_currency` inside this module's `init`.  The resulting
/// `TreasuryCap<JUNIOR_COIN>` is transferred to `TrancheRegistry` via a
/// public entry that can only be called once (guarded by the OTW liveness).
#[allow(duplicate_alias, unused_use)]
module securitization::junior_coin {
    use iota::coin::{Self, TreasuryCap, CoinMetadata};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};

    // ─── One-time witness ─────────────────────────────────────────────────────

    /// The OTW for the Junior tranche token.
    /// Must be the module name in ALL_CAPS — enforced by the IOTA VM.
    public struct JUNIOR_COIN has drop {}

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Runs once on publish.  Creates the `JUNIOR_COIN` currency and transfers:
    ///   - `TreasuryCap<JUNIOR_COIN>` → deployer  (picked up by TrancheFactory)
    ///   - `CoinMetadata<JUNIOR_COIN>` → frozen shared object
    fun init(witness: JUNIOR_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,                                          // decimals
            b"JUNIOR",                                  // symbol
            b"Junior Tranche Token",                    // name
            b"IOTA Securitization – Junior Tranche",    // description
            option::none(),                             // icon url
            ctx,
        );

        // Freeze metadata — nobody may mutate it after publication.
        transfer::public_freeze_object(metadata);

        // Send the treasury cap to the deployer so TrancheFactory can collect it.
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    /// Returns a `TreasuryCap<JUNIOR_COIN>` built with the test-only bypass,
    /// which skips the `is_one_time_witness` VM check.
    /// Use this in test modules instead of calling `init` directly.
    #[test_only]
    public fun create_treasury_for_testing(
        ctx: &mut TxContext,
    ): TreasuryCap<JUNIOR_COIN> {
        coin::create_treasury_cap_for_testing<JUNIOR_COIN>(ctx)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let treasury_cap = coin::create_treasury_cap_for_testing<JUNIOR_COIN>(ctx);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }
}
