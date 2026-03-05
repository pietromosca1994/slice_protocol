/// # TrancheFactory
///
/// Creates and manages the three classes of fungible tokens (Senior, Mezzanine,
/// Junior) representing the capital structure of the securitization.
///
/// ## Design-document alignment (v1.0)
///
/// | Spec variable                  | Implementation                        |
/// |--------------------------------|---------------------------------------|
/// | seniorTokenID / mezzTokenID / juniorTokenID | Implicit in Coin<SENIOR> /
/// |                                | Coin<MEZZ> / Coin<JUNIOR> type params  |
/// | seniorSupplyCap / mezzSupplyCap / juniorSupplyCap | TrancheRegistry fields |
/// | seniorMinted / mezzMinted / juniorMinted           | TrancheRegistry fields |
/// | mintingEnabled                 | TrancheRegistry.minting_enabled        |
/// | authorizedIssuanceContract     | TrancheRegistry.issuance_contract +    |
/// |                                | IssuanceAdminCap capability            |
///
/// ## Methods (spec → entry)
/// | Spec method        | Entry function          |
/// |--------------------|-------------------------|
/// | createTranches()   | create_tranches         |
/// | mint()             | mint                    |
/// | melt()             | melt_senior/mezz/junior |
/// | disableMinting()   | disable_minting         |
/// | getTrancheInfo()   | accessor functions      |
///
/// ## OTW / testing note
/// `coin::create_currency` enforces `is_one_time_witness`.  The test-only
/// helpers `new_senior_witness()`, `new_mezz_witness()`, `new_junior_witness()`
/// construct the witness values inside the *defining* module, which satisfies
/// the native OTW check.  `init_for_testing` accepts them as parameters so
/// that the test module never needs to fabricate them externally.
#[allow(duplicate_alias, unused_use, lint(self_transfer))]
module securitization::tranche_factory {
    use iota::coin::{Self, Coin, TreasuryCap, CoinMetadata};
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use securitization::errors;
    use securitization::events;

    // ─── Tranche type constants ───────────────────────────────────────────────
    const TRANCHE_SENIOR: u8 = 0;
    const TRANCHE_MEZZ:   u8 = 1;
    const TRANCHE_JUNIOR: u8 = 2;

    // ─── One-time witnesses ───────────────────────────────────────────────────
    public struct SENIOR has drop {}
    public struct MEZZ   has drop {}
    public struct JUNIOR has drop {}

    // ─── Capabilities ─────────────────────────────────────────────────────────

    /// Held by the admin; controls registry mutations and tranche setup.
    public struct TrancheAdminCap has key, store { id: UID }

    /// Transferred to the IssuanceContract address; grants minting rights.
    /// Corresponds to spec's `authorizedIssuanceContract` enforcement.
    public struct IssuanceAdminCap has key, store { id: UID }

    // ─── Shared registry ──────────────────────────────────────────────────────

    /// Shared object that holds treasury caps and all spec state variables.
    ///
    /// Spec variables carried here:
    ///   seniorSupplyCap / mezzSupplyCap / juniorSupplyCap
    ///   seniorMinted    / mezzMinted    / juniorMinted
    ///   mintingEnabled
    ///   authorizedIssuanceContract  (→ issuance_contract + IssuanceAdminCap)
    public struct TrancheRegistry has key {
        id:                UID,
        // Supply caps (spec: seniorSupplyCap, mezzSupplyCap, juniorSupplyCap)
        senior_supply_cap: u64,
        mezz_supply_cap:   u64,
        junior_supply_cap: u64,
        // Running minted totals (spec: seniorMinted, mezzMinted, juniorMinted)
        senior_minted:     u64,
        mezz_minted:       u64,
        junior_minted:     u64,
        // Treasury caps — back the IOTA coin foundries
        senior_treasury:   TreasuryCap<SENIOR>,
        mezz_treasury:     TreasuryCap<MEZZ>,
        junior_treasury:   TreasuryCap<JUNIOR>,
        // Spec: mintingEnabled — global minting gate
        minting_enabled:   bool,
        // Guards against calling create_tranches twice
        tranches_created:  bool,
        // Spec: authorizedIssuanceContract
        issuance_contract: address,
    }

    // ─── TrancheInfo return struct (spec: getTrancheInfo) ─────────────────────

    /// Mirrors the spec's `TrancheInfo` struct returned by `getTrancheInfo()`.
    public struct TrancheInfo has copy, drop {
        tranche_type:       u8,
        supply_cap:         u64,
        amount_minted:      u64,
        remaining_capacity: u64,
        minting_active:     bool,
    }

    // ─── Internal init helper ─────────────────────────────────────────────────

    /// Shared body used by both `init` and `init_for_testing`.
    /// Accepts the three OTW values so the caller controls their origin
    /// (real publish vs. test-only constructor).
    fun init_internal(
        senior: SENIOR,
        mezz:   MEZZ,
        junior: JUNIOR,
        ctx:    &mut TxContext,
    ) {
        let (senior_treasury, senior_meta) = coin::create_currency(
            senior,
            6,
            b"SNIOR",
            b"Senior Tranche Token",
            b"IOTA Securitization Senior Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(senior_meta);

        let (mezz_treasury, mezz_meta) = coin::create_currency(
            mezz,
            6,
            b"MEZZ",
            b"Mezzanine Tranche Token",
            b"IOTA Securitization Mezzanine Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(mezz_meta);

        let (junior_treasury, junior_meta) = coin::create_currency(
            junior,
            6,
            b"JNIOR",
            b"Junior Tranche Token",
            b"IOTA Securitization Junior Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(junior_meta);

        let registry = TrancheRegistry {
            id:                object::new(ctx),
            senior_supply_cap: 0,
            mezz_supply_cap:   0,
            junior_supply_cap: 0,
            senior_minted:     0,
            mezz_minted:       0,
            junior_minted:     0,
            senior_treasury,
            mezz_treasury,
            junior_treasury,
            minting_enabled:   false,
            tranches_created:  false,
            issuance_contract: @0x0,
        };
        transfer::share_object(registry);

        let admin_cap = TrancheAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        init_internal(SENIOR {}, MEZZ {}, JUNIOR {}, ctx);
    }

    // ─── Spec: createTranches() ───────────────────────────────────────────────

    /// Configures the three tranche supply caps and enables minting.
    /// Callable once (spec: "Callable once by PoolContract").
    /// Also issues IssuanceAdminCap to the authorizedIssuanceContract.
    ///
    /// Spec parameters: seniorCap, mezzCap, juniorCap
    /// Spec returns:    TokenID[3]  (implicit in Coin<T> types here)
    public entry fun create_tranches(
        _cap:              &TrancheAdminCap,
        registry:          &mut TrancheRegistry,
        senior_cap:        u64,
        mezz_cap:          u64,
        junior_cap:        u64,
        issuance_contract: address,
        clock:             &Clock,
        ctx:               &mut TxContext,
    ) {
        assert!(!registry.tranches_created, errors::tranches_already_created());
        assert!(senior_cap > 0,             errors::zero_supply_cap());
        assert!(mezz_cap   > 0,             errors::zero_supply_cap());
        assert!(junior_cap > 0,             errors::zero_supply_cap());
        assert!(issuance_contract != @0x0,  errors::not_issuance_contract());

        registry.senior_supply_cap = senior_cap;
        registry.mezz_supply_cap   = mezz_cap;
        registry.junior_supply_cap = junior_cap;
        registry.issuance_contract = issuance_contract;
        registry.minting_enabled   = true;
        registry.tranches_created  = true;

        // Deliver capability to the authorizedIssuanceContract
        let iac = IssuanceAdminCap { id: object::new(ctx) };
        transfer::transfer(iac, issuance_contract);

        events::emit_tranches_created(
            senior_cap, mezz_cap, junior_cap,
            clock::timestamp_ms(clock),
        );
    }

    // ─── Spec: mint() ─────────────────────────────────────────────────────────

    /// Mints `amount` tokens of `tranche_type` to `recipient`.
    ///
    /// Spec checks enforced:
    ///   - caller holds IssuanceAdminCap  (authorizedIssuanceContract)
    ///   - mintingEnabled == true
    ///   - amount <= remaining supply cap
    ///
    /// Spec parameters: trancheType, amount, recipient
    /// Spec returns:    bool  (aborts on failure, implicit true on success)
    public entry fun mint(
        _cap:         &IssuanceAdminCap,
        registry:     &mut TrancheRegistry,
        tranche_type: u8,
        amount:       u64,
        recipient:    address,
        clock:        &Clock,
        ctx:          &mut TxContext,
    ) {
        assert!(registry.minting_enabled,  errors::minting_disabled());
        assert!(registry.tranches_created, errors::tranches_not_created());

        if (tranche_type == TRANCHE_SENIOR) {
            assert!(
                registry.senior_minted + amount <= registry.senior_supply_cap,
                errors::supply_cap_exceeded()
            );
            registry.senior_minted = registry.senior_minted + amount;
            let coin = coin::mint(&mut registry.senior_treasury, amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else if (tranche_type == TRANCHE_MEZZ) {
            assert!(
                registry.mezz_minted + amount <= registry.mezz_supply_cap,
                errors::supply_cap_exceeded()
            );
            registry.mezz_minted = registry.mezz_minted + amount;
            let coin = coin::mint(&mut registry.mezz_treasury, amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else if (tranche_type == TRANCHE_JUNIOR) {
            assert!(
                registry.junior_minted + amount <= registry.junior_supply_cap,
                errors::supply_cap_exceeded()
            );
            registry.junior_minted = registry.junior_minted + amount;
            let coin = coin::mint(&mut registry.junior_treasury, amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else {
            abort errors::unknown_tranche_type()
        };

        events::emit_tokens_minted(
            tranche_type, amount, recipient,
            clock::timestamp_ms(clock),
        );
    }

    // ─── Spec: melt() ─────────────────────────────────────────────────────────
    //
    // The spec defines a single melt(trancheType, amount) method.
    // In IOTA Move the coin type must be statically known, so we provide three
    // typed entry points — each is callable by any token holder (spec: "Used
    // during redemption").

    /// Burns Senior tokens. Spec: melt(Senior, amount).
    public entry fun melt_senior(
        registry: &mut TrancheRegistry,
        coin:     Coin<SENIOR>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.senior_minted >= amount, errors::insufficient_minted());
        registry.senior_minted = registry.senior_minted - amount;
        coin::burn(&mut registry.senior_treasury, coin);
        events::emit_tokens_melted(TRANCHE_SENIOR, amount, clock::timestamp_ms(clock));
    }

    /// Burns Mezzanine tokens. Spec: melt(Mezz, amount).
    public entry fun melt_mezz(
        registry: &mut TrancheRegistry,
        coin:     Coin<MEZZ>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.mezz_minted >= amount, errors::insufficient_minted());
        registry.mezz_minted = registry.mezz_minted - amount;
        coin::burn(&mut registry.mezz_treasury, coin);
        events::emit_tokens_melted(TRANCHE_MEZZ, amount, clock::timestamp_ms(clock));
    }

    /// Burns Junior tokens. Spec: melt(Junior, amount).
    public entry fun melt_junior(
        registry: &mut TrancheRegistry,
        coin:     Coin<JUNIOR>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.junior_minted >= amount, errors::insufficient_minted());
        registry.junior_minted = registry.junior_minted - amount;
        coin::burn(&mut registry.junior_treasury, coin);
        events::emit_tokens_melted(TRANCHE_JUNIOR, amount, clock::timestamp_ms(clock));
    }

    // ─── Spec: disableMinting() ───────────────────────────────────────────────

    /// Permanently sets mintingEnabled to false.
    /// Spec: "Called by PoolContract upon pool closure or default. Irreversible."
    public entry fun disable_minting(
        _cap:     &TrancheAdminCap,
        registry: &mut TrancheRegistry,
        clock:    &Clock,
    ) {
        registry.minting_enabled = false;
        events::emit_minting_disabled(clock::timestamp_ms(clock));
    }

    // ─── Spec: getTrancheInfo() ───────────────────────────────────────────────

    /// Returns tokenID, supply cap, amount minted, remaining capacity, and
    /// current mint status for the specified tranche type.
    /// Spec: getTrancheInfo(trancheType) → struct TrancheInfo
    public fun get_tranche_info(
        registry:     &TrancheRegistry,
        tranche_type: u8,
    ): TrancheInfo {
        assert!(
            tranche_type == TRANCHE_SENIOR ||
            tranche_type == TRANCHE_MEZZ   ||
            tranche_type == TRANCHE_JUNIOR,
            errors::unknown_tranche_type()
        );

        let (supply_cap, amount_minted) = if (tranche_type == TRANCHE_SENIOR) {
            (registry.senior_supply_cap, registry.senior_minted)
        } else if (tranche_type == TRANCHE_MEZZ) {
            (registry.mezz_supply_cap, registry.mezz_minted)
        } else {
            (registry.junior_supply_cap, registry.junior_minted)
        };

        TrancheInfo {
            tranche_type,
            supply_cap,
            amount_minted,
            remaining_capacity: supply_cap - amount_minted,
            minting_active: registry.minting_enabled,
        }
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun senior_supply_cap(r: &TrancheRegistry): u64  { r.senior_supply_cap }
    public fun mezz_supply_cap(r: &TrancheRegistry): u64    { r.mezz_supply_cap }
    public fun junior_supply_cap(r: &TrancheRegistry): u64  { r.junior_supply_cap }
    public fun senior_minted(r: &TrancheRegistry): u64      { r.senior_minted }
    public fun mezz_minted(r: &TrancheRegistry): u64        { r.mezz_minted }
    public fun junior_minted(r: &TrancheRegistry): u64      { r.junior_minted }
    public fun minting_enabled(r: &TrancheRegistry): bool   { r.minting_enabled }
    public fun tranches_created(r: &TrancheRegistry): bool  { r.tranches_created }
    public fun issuance_contract(r: &TrancheRegistry): address { r.issuance_contract }

    public fun senior_remaining(r: &TrancheRegistry): u64 {
        r.senior_supply_cap - r.senior_minted
    }
    public fun mezz_remaining(r: &TrancheRegistry): u64 {
        r.mezz_supply_cap - r.mezz_minted
    }
    public fun junior_remaining(r: &TrancheRegistry): u64 {
        r.junior_supply_cap - r.junior_minted
    }

    // TrancheInfo field accessors
    public fun info_tranche_type(i: &TrancheInfo): u8       { i.tranche_type }
    public fun info_supply_cap(i: &TrancheInfo): u64        { i.supply_cap }
    public fun info_amount_minted(i: &TrancheInfo): u64     { i.amount_minted }
    public fun info_remaining(i: &TrancheInfo): u64         { i.remaining_capacity }
    public fun info_minting_active(i: &TrancheInfo): bool   { i.minting_active }

    public fun tranche_senior(): u8 { TRANCHE_SENIOR }
    public fun tranche_mezz(): u8   { TRANCHE_MEZZ }
    public fun tranche_junior(): u8 { TRANCHE_JUNIOR }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    /// Constructs SENIOR OTW from within the defining module — the only valid
    /// way to satisfy `is_one_time_witness` in an external test module.
    /// Test-only init that uses `coin::create_treasury_cap_for_testing` to
    /// construct TreasuryCap<T> values without invoking `create_currency` and
    /// therefore without triggering the `is_one_time_witness` VM-level check.
    /// This is the canonical pattern for testing Coin-based modules in IOTA Move.
    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let senior_treasury = coin::create_treasury_cap_for_testing<SENIOR>(ctx);
        let mezz_treasury   = coin::create_treasury_cap_for_testing<MEZZ>(ctx);
        let junior_treasury = coin::create_treasury_cap_for_testing<JUNIOR>(ctx);

        let registry = TrancheRegistry {
            id:                object::new(ctx),
            senior_supply_cap: 0,
            mezz_supply_cap:   0,
            junior_supply_cap: 0,
            senior_minted:     0,
            mezz_minted:       0,
            junior_minted:     0,
            senior_treasury,
            mezz_treasury,
            junior_treasury,
            minting_enabled:   false,
            tranches_created:  false,
            issuance_contract: @0x0,
        };
        transfer::share_object(registry);

        let admin_cap = TrancheAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }
}
