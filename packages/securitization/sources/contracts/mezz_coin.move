/// # MezzCoin
///
/// Defines the one-time witness `MEZZ_COIN` used to create the Mezzanine
/// tranche fungible token via `coin::create_currency`.
///
/// ## Treasury cap handoff
///
/// Rather than transferring `TreasuryCap<MEZZ_COIN>` to the sender (which
/// would require a separate post-deploy `initialize_registry` call), this
/// module parks the cap in a shared `MezzTreasury` wrapper object during
/// `init`.  `tranche_factory::init` then claims it atomically in the same
/// publish transaction via the `public(friend)` `take_treasury` function.
///
/// `take_treasury` is gated as `public(friend)` so only `tranche_factory`
/// can call it.  The `Option` wrapper ensures the cap can only be extracted
/// once — a second call aborts.
#[allow(duplicate_alias, unused_use)]
module securitization::mezz_coin {
    use iota::coin::{Self, TreasuryCap};
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};

    // ─── One-time witness ─────────────────────────────────────────────────────

    /// The OTW for the Mezzanine tranche token.
    /// Must be the module name in ALL_CAPS — enforced by the IOTA VM.
    public struct MEZZ_COIN has drop {}

    // ─── Treasury parking object ──────────────────────────────────────────────

    /// Shared wrapper that holds the `TreasuryCap` until `tranche_factory::init`
    /// claims it in the same publish transaction.
    public struct MezzTreasury has key {
        id:  UID,
        cap: Option<TreasuryCap<MEZZ_COIN>>,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Runs once on publish.  Creates the `MEZZ_COIN` currency, freezes the
    /// metadata, and parks the `TreasuryCap` in a shared `MezzTreasury`
    /// wrapper for `tranche_factory::init` to claim.
    fun init(witness: MEZZ_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,
            b"MEZZ",
            b"Mezzanine Tranche Token",
            b"IOTA Securitization – Mezzanine Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(metadata);

        transfer::share_object(MezzTreasury {
            id:  object::new(ctx),
            cap: option::some(treasury_cap),
        });
    }

    // ─── Friend-only extraction ───────────────────────────────────────────────

    /// Extracts the `TreasuryCap` from the parking object.
    /// Callable only by `tranche_factory` (declared as friend above).
    /// Aborts on second call because `option::extract` panics on `None`.
    public(package) fun take_treasury(
        wrapper: &mut MezzTreasury,
    ): TreasuryCap<MEZZ_COIN> {
        option::extract(&mut wrapper.cap)
    }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    #[test_only]
    public fun create_treasury_for_testing(
        ctx: &mut TxContext,
    ): TreasuryCap<MEZZ_COIN> {
        coin::create_treasury_cap_for_testing<MEZZ_COIN>(ctx)
    }
}
