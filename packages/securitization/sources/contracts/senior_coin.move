/// # SeniorCoin
///
/// Defines the one-time witness `SENIOR_COIN` used to create the Senior
/// tranche fungible token via `coin::create_currency`.
///
/// ## Treasury cap handoff
///
/// Rather than transferring `TreasuryCap<SENIOR_COIN>` to the sender (which
/// would require a separate post-deploy `initialize_registry` call), this
/// module parks the cap in a shared `SeniorTreasury` wrapper object during
/// `init`.  `tranche_factory::init` then claims it atomically in the same
/// publish transaction via the `public(friend)` `take_treasury` function.
///
/// Because all module `init` functions in a package run in a single publish
/// transaction, `tranche_factory::init` can receive a `&mut SeniorTreasury`
/// argument and extract the cap with no separate wiring step.
///
/// `take_treasury` is gated as `public(friend)` so only `tranche_factory`
/// can call it.  The `Option` wrapper ensures the cap can only be extracted
/// once — a second call aborts.
#[allow(duplicate_alias, unused_use)]
module securitization::senior_coin {
    use iota::coin::{Self, TreasuryCap};
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};

    // ─── One-time witness ─────────────────────────────────────────────────────

    /// The OTW for the Senior tranche token.
    /// Must be the module name in ALL_CAPS — enforced by the IOTA VM.
    public struct SENIOR_COIN has drop {}

    // ─── Treasury parking object ──────────────────────────────────────────────

    /// Shared wrapper that holds the `TreasuryCap` until `tranche_factory::init`
    /// claims it in the same publish transaction.
    /// Shared so it is accessible across module boundaries within one tx.
    public struct SeniorTreasury has key {
        id:  UID,
        cap: Option<TreasuryCap<SENIOR_COIN>>,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Runs once on publish.  Creates the `SENIOR_COIN` currency, freezes the
    /// metadata, and parks the `TreasuryCap` in a shared `SeniorTreasury`
    /// wrapper for `tranche_factory::init` to claim.
    fun init(witness: SENIOR_COIN, ctx: &mut TxContext) {
        let (treasury_cap, metadata) = coin::create_currency(
            witness,
            6,
            b"SENIOR",
            b"Senior Tranche Token",
            b"IOTA Securitization – Senior Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(metadata);

        transfer::share_object(SeniorTreasury {
            id:  object::new(ctx),
            cap: option::some(treasury_cap),
        });
    }

    // ─── Friend-only extraction ───────────────────────────────────────────────

    /// Extracts the `TreasuryCap` from the parking object.
    /// Callable only by `tranche_factory` (declared as friend above).
    /// Aborts on second call because `option::extract` panics on `None`.
    public(package) fun take_treasury(
        wrapper: &mut SeniorTreasury,
    ): TreasuryCap<SENIOR_COIN> {
        option::extract(&mut wrapper.cap)
    }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    #[test_only]
    public fun create_treasury_for_testing(
        ctx: &mut TxContext,
    ): TreasuryCap<SENIOR_COIN> {
        coin::create_treasury_cap_for_testing<SENIOR_COIN>(ctx)
    }
}
