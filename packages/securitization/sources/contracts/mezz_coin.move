/// # MezzCoin
///
/// Defines the one-time witness `MEZZ_COIN` used to create the Mezzanine
/// tranche fungible token via `coin::create_currency`.
///
/// Separating the OTW into its own module means `TrancheFactory` no longer
/// needs to own the witness struct, satisfying the IOTA Move requirement that
/// the OTW type and the `init` that consumes it live in the *same* module.
///
/// ## Integration
/// `tranche_factory` imports `MEZZ_COIN` as a phantom type parameter when
/// calling `coin::create_currency` inside this module's `init`.  The resulting
/// `TreasuryCap<MEZZ_COIN>` is transferred to `TrancheRegistry` via a
/// public entry that can only be called once (guarded by the OTW liveness).
#[allow(duplicate_alias, unused_use)]
module securitization::mezz_coin {
    use iota::coin::{Self, TreasuryCap, CoinMetadata};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};

    // ─── One-time witness ─────────────────────────────────────────────────────

    /// The OTW for the Mezzanine tranche token.
    /// Must be the module name in ALL_CAPS — enforced by the IOTA VM.
    public struct MEZZ_COIN has drop {}

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Runs once on publish.  Creates the `MEZZ_COIN` currency and transfers:
    ///   - `TreasuryCap<MEZZ_COIN>` → deployer  (picked up by TrancheFactory)
    ///   - `CoinMetadata<MEZZ_COIN>` → frozen shared object
    fun init(witness: MEZZ_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,                                              // decimals
            b"MEZZ",                                        // symbol
            b"Mezzanine Tranche Token",                     // name
            b"IOTA Securitization – Mezzanine Tranche",     // description
            option::none(),                                 // icon url
            ctx,
        );

        // Freeze metadata — nobody may mutate it after publication.
        transfer::public_freeze_object(metadata);

        // Send the treasury cap to the deployer so TrancheFactory can collect it.
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    /// Returns a `TreasuryCap<MEZZ_COIN>` built with the test-only bypass,
    /// which skips the `is_one_time_witness` VM check.
    /// Use this in test modules instead of calling `init` directly.
    #[test_only]
    public fun create_treasury_for_testing(
        ctx: &mut TxContext,
    ): TreasuryCap<MEZZ_COIN> {
        coin::create_treasury_cap_for_testing<MEZZ_COIN>(ctx)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let treasury_cap = coin::create_treasury_cap_for_testing<MEZZ_COIN>(ctx);
        transfer::public_transfer(treasury_cap, tx_context::sender(ctx));
    }
}
