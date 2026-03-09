#[allow(duplicate_alias, unused_use, lint(self_transfer))]
module securitization::tranche_factory {
    use iota::coin::{Self, Coin, TreasuryCap};
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use securitization::errors;
    use securitization::events;

    use securitization::senior_coin::{Self, SENIOR_COIN, SeniorTreasury};
    use securitization::mezz_coin::{Self,   MEZZ_COIN,   MezzTreasury};
    use securitization::junior_coin::{Self,  JUNIOR_COIN,  JuniorTreasury};

    const TRANCHE_SENIOR: u8 = 0;
    const TRANCHE_MEZZ:   u8 = 1;
    const TRANCHE_JUNIOR: u8 = 2;

    public struct TrancheAdminCap has key, store { id: UID }
    public struct IssuanceAdminCap has key, store { id: UID }

    /// Uses Option<TreasuryCap<T>> so the registry can be shared before
    /// treasuries are injected by `bootstrap`.
    public struct TrancheRegistry has key {
        id:                UID,
        senior_supply_cap: u64,
        mezz_supply_cap:   u64,
        junior_supply_cap: u64,
        senior_minted:     u64,
        mezz_minted:       u64,
        junior_minted:     u64,
        senior_treasury:   Option<TreasuryCap<SENIOR_COIN>>,
        mezz_treasury:     Option<TreasuryCap<MEZZ_COIN>>,
        junior_treasury:   Option<TreasuryCap<JUNIOR_COIN>>,
        minting_enabled:   bool,
        tranches_created:  bool,
        issuance_contract: address,
        bootstrapped:      bool,
    }

    public struct TrancheInfo has copy, drop {
        tranche_type:       u8,
        supply_cap:         u64,
        amount_minted:      u64,
        remaining_capacity: u64,
        minting_active:     bool,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Only the OTW + TxContext pattern is valid here.
    /// Creates an empty registry shell; `bootstrap` must be called next.
    public struct TRANCHE_FACTORY has drop {}

    fun init(_witness: TRANCHE_FACTORY, ctx: &mut TxContext) {
        let registry = TrancheRegistry {
            id:                object::new(ctx),
            senior_supply_cap: 0,
            mezz_supply_cap:   0,
            junior_supply_cap: 0,
            senior_minted:     0,
            mezz_minted:       0,
            junior_minted:     0,
            senior_treasury:   option::none(),
            mezz_treasury:     option::none(),
            junior_treasury:   option::none(),
            minting_enabled:   false,
            tranches_created:  false,
            issuance_contract: @0x0,
            bootstrapped:      false,
        };
        transfer::share_object(registry);

        let admin_cap = TrancheAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Bootstrap (replaces the invalid init wiring) ─────────────────────────

    /// Callable once by the admin immediately after publish.
    /// Extracts the TreasuryCaps from the coin parking wrappers and
    /// injects them into the registry. Can be called in the same publish
    /// transaction or a subsequent one.
    public entry fun bootstrap(
        _cap:           &TrancheAdminCap,
        registry:       &mut TrancheRegistry,
        senior_wrapper: &mut SeniorTreasury,
        mezz_wrapper:   &mut MezzTreasury,
        junior_wrapper: &mut JuniorTreasury,
        _ctx:           &mut TxContext,
    ) {
        assert!(!registry.bootstrapped, errors::tranches_already_created());

        option::fill(&mut registry.senior_treasury, senior_coin::take_treasury(senior_wrapper));
        option::fill(&mut registry.mezz_treasury,   mezz_coin::take_treasury(mezz_wrapper));
        option::fill(&mut registry.junior_treasury,  junior_coin::take_treasury(junior_wrapper));

        registry.bootstrapped = true;
    }

    // ─── Internal helpers to unwrap Option<TreasuryCap<T>> ───────────────────

    fun senior_treasury_mut(registry: &mut TrancheRegistry): &mut TreasuryCap<SENIOR_COIN> {
        option::borrow_mut(&mut registry.senior_treasury)
    }
    fun mezz_treasury_mut(registry: &mut TrancheRegistry): &mut TreasuryCap<MEZZ_COIN> {
        option::borrow_mut(&mut registry.mezz_treasury)
    }
    fun junior_treasury_mut(registry: &mut TrancheRegistry): &mut TreasuryCap<JUNIOR_COIN> {
        option::borrow_mut(&mut registry.junior_treasury)
    }

    // ─── create_tranches, mint, melt_*, disable_minting, get_tranche_info ─────
    // (unchanged from your original — just ensure bootstrap guard where needed)

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
        assert!(registry.bootstrapped,      errors::tranches_not_created()); // must bootstrap first
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

        let iac = IssuanceAdminCap { id: object::new(ctx) };
        transfer::transfer(iac, issuance_contract);

        events::emit_tranches_created(
            senior_cap, mezz_cap, junior_cap,
            clock::timestamp_ms(clock),
        );
    }

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
            let coin = coin::mint(senior_treasury_mut(registry), amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else if (tranche_type == TRANCHE_MEZZ) {
            assert!(
                registry.mezz_minted + amount <= registry.mezz_supply_cap,
                errors::supply_cap_exceeded()
            );
            registry.mezz_minted = registry.mezz_minted + amount;
            let coin = coin::mint(mezz_treasury_mut(registry), amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else if (tranche_type == TRANCHE_JUNIOR) {
            assert!(
                registry.junior_minted + amount <= registry.junior_supply_cap,
                errors::supply_cap_exceeded()
            );
            registry.junior_minted = registry.junior_minted + amount;
            let coin = coin::mint(junior_treasury_mut(registry), amount, ctx);
            transfer::public_transfer(coin, recipient);

        } else {
            abort errors::unknown_tranche_type()
        };

        events::emit_tokens_minted(
            tranche_type, amount, recipient,
            clock::timestamp_ms(clock),
        );
    }

    public entry fun melt_senior(
        registry: &mut TrancheRegistry,
        coin:     Coin<SENIOR_COIN>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.senior_minted >= amount, errors::insufficient_minted());
        registry.senior_minted = registry.senior_minted - amount;
        coin::burn(senior_treasury_mut(registry), coin);
        events::emit_tokens_melted(TRANCHE_SENIOR, amount, clock::timestamp_ms(clock));
    }

    public entry fun melt_mezz(
        registry: &mut TrancheRegistry,
        coin:     Coin<MEZZ_COIN>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.mezz_minted >= amount, errors::insufficient_minted());
        registry.mezz_minted = registry.mezz_minted - amount;
        coin::burn(mezz_treasury_mut(registry), coin);
        events::emit_tokens_melted(TRANCHE_MEZZ, amount, clock::timestamp_ms(clock));
    }

    public entry fun melt_junior(
        registry: &mut TrancheRegistry,
        coin:     Coin<JUNIOR_COIN>,
        clock:    &Clock,
    ) {
        let amount = coin::value(&coin);
        assert!(registry.junior_minted >= amount, errors::insufficient_minted());
        registry.junior_minted = registry.junior_minted - amount;
        coin::burn(junior_treasury_mut(registry), coin);
        events::emit_tokens_melted(TRANCHE_JUNIOR, amount, clock::timestamp_ms(clock));
    }

    public entry fun disable_minting(
        _cap:     &TrancheAdminCap,
        registry: &mut TrancheRegistry,
        clock:    &Clock,
    ) {
        registry.minting_enabled = false;
        events::emit_minting_disabled(clock::timestamp_ms(clock));
    }

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

    // ─── Read-only accessors (unchanged) ─────────────────────────────────────
    public fun senior_supply_cap(r: &TrancheRegistry): u64     { r.senior_supply_cap }
    public fun mezz_supply_cap(r: &TrancheRegistry): u64       { r.mezz_supply_cap }
    public fun junior_supply_cap(r: &TrancheRegistry): u64     { r.junior_supply_cap }
    public fun senior_minted(r: &TrancheRegistry): u64         { r.senior_minted }
    public fun mezz_minted(r: &TrancheRegistry): u64           { r.mezz_minted }
    public fun junior_minted(r: &TrancheRegistry): u64         { r.junior_minted }
    public fun minting_enabled(r: &TrancheRegistry): bool      { r.minting_enabled }
    public fun tranches_created(r: &TrancheRegistry): bool     { r.tranches_created }
    public fun issuance_contract(r: &TrancheRegistry): address { r.issuance_contract }
    public fun bootstrapped(r: &TrancheRegistry): bool         { r.bootstrapped }

    public fun senior_remaining(r: &TrancheRegistry): u64 { r.senior_supply_cap - r.senior_minted }
    public fun mezz_remaining(r: &TrancheRegistry): u64   { r.mezz_supply_cap - r.mezz_minted }
    public fun junior_remaining(r: &TrancheRegistry): u64 { r.junior_supply_cap - r.junior_minted }

    public fun info_tranche_type(i: &TrancheInfo): u8     { i.tranche_type }
    public fun info_supply_cap(i: &TrancheInfo): u64      { i.supply_cap }
    public fun info_amount_minted(i: &TrancheInfo): u64   { i.amount_minted }
    public fun info_remaining(i: &TrancheInfo): u64       { i.remaining_capacity }
    public fun info_minting_active(i: &TrancheInfo): bool { i.minting_active }

    public fun tranche_senior(): u8 { TRANCHE_SENIOR }
    public fun tranche_mezz(): u8   { TRANCHE_MEZZ }
    public fun tranche_junior(): u8 { TRANCHE_JUNIOR }

    // ─── Test-only helpers ────────────────────────────────────────────────────

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        let registry = TrancheRegistry {
            id:                object::new(ctx),
            senior_supply_cap: 0,
            mezz_supply_cap:   0,
            junior_supply_cap: 0,
            senior_minted:     0,
            mezz_minted:       0,
            junior_minted:     0,
            senior_treasury:   option::some(senior_coin::create_treasury_for_testing(ctx)),
            mezz_treasury:     option::some(mezz_coin::create_treasury_for_testing(ctx)),
            junior_treasury:   option::some(junior_coin::create_treasury_for_testing(ctx)),
            minting_enabled:   false,
            tranches_created:  false,
            issuance_contract: @0x0,
            bootstrapped:      true,
        };
        transfer::share_object(registry);

        let admin_cap = TrancheAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }
}