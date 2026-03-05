/// # TrancheFactory
///
/// Creates and manages the three classes of fungible tokens (Senior, Mezzanine,
/// Junior) representing the capital structure of the securitization.
///
/// ## IOTA Move design notes
/// - Each tranche token is implemented as an IOTA Coin<T> using the `iota::coin`
///   framework. Three one-time-witness types (SENIOR, MEZZ, JUNIOR) gate the
///   `TreasuryCap` that controls minting and burning.
/// - Supply caps are enforced in the `TrancheRegistry` shared object.
/// - The `IssuanceAdminCap` is a capability transferred to the IssuanceContract
///   address, granting it the right to call `mint`.
/// - `melt` is callable by any token holder (they must pass their Coin in).
#[allow(duplicate_alias)]
module securitization::tranche_factory {
    use iota::coin::{Self, Coin, TreasuryCap};
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
    // Each OTW is used once at publish time to create the coin metadata and
    // a TreasuryCap that lives inside TrancheRegistry.

    public struct SENIOR has drop {}
    public struct MEZZ   has drop {}
    public struct JUNIOR has drop {}

    // ─── Capability ───────────────────────────────────────────────────────────

    /// Held by the admin; controls registry mutations.
    public struct TrancheAdminCap has key, store { id: UID }

    /// Transferred to the IssuanceContract address; grants minting rights.
    public struct IssuanceAdminCap has key, store { id: UID }

    // ─── Shared registry ──────────────────────────────────────────────────────

    /// Shared object that holds treasury caps and supply accounting.
    public struct TrancheRegistry has key {
        id:               UID,
        // Supply caps
        senior_supply_cap: u64,
        mezz_supply_cap:   u64,
        junior_supply_cap: u64,
        // Running minted totals
        senior_minted:    u64,
        mezz_minted:      u64,
        junior_minted:    u64,
        // Treasury caps (grant ability to mint/burn)
        senior_treasury:  TreasuryCap<SENIOR>,
        mezz_treasury:    TreasuryCap<MEZZ>,
        junior_treasury:  TreasuryCap<JUNIOR>,
        // Flags
        minting_enabled:  bool,
        tranches_created: bool,
        // Authorised issuance contract address
        issuance_contract: address,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    /// Called at publish time. Creates coin metadata for all three tranches,
    /// stores treasury caps in a new shared TrancheRegistry, and sends
    /// TrancheAdminCap to the deployer.
    fun init(ctx: &mut TxContext) {
        // Create SENIOR coin
        let (senior_treasury, senior_meta) = coin::create_currency(
            SENIOR {},
            6,                        // decimals
            b"SNIOR",                 // symbol
            b"Senior Tranche Token",  // name
            b"IOTA Securitization Senior Tranche", // description
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(senior_meta);

        // Create MEZZ coin
        let (mezz_treasury, mezz_meta) = coin::create_currency(
            MEZZ {},
            6,
            b"MEZZ",
            b"Mezzanine Tranche Token",
            b"IOTA Securitization Mezzanine Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(mezz_meta);

        // Create JUNIOR coin
        let (junior_treasury, junior_meta) = coin::create_currency(
            JUNIOR {},
            6,
            b"JNIOR",
            b"Junior Tranche Token",
            b"IOTA Securitization Junior Tranche",
            option::none(),
            ctx,
        );
        transfer::public_freeze_object(junior_meta);

        // Build shared registry
        let registry = TrancheRegistry {
            id:               object::new(ctx),
            senior_supply_cap: 0,
            mezz_supply_cap:   0,
            junior_supply_cap: 0,
            senior_minted:    0,
            mezz_minted:      0,
            junior_minted:    0,
            senior_treasury,
            mezz_treasury,
            junior_treasury,
            minting_enabled:  false,
            tranches_created: false,
            issuance_contract: @0x0,
        };
        transfer::share_object(registry);

        let admin_cap = TrancheAdminCap { id: object::new(ctx) };
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ─── Admin setup ──────────────────────────────────────────────────────────

    /// Configures the three tranche supply caps and enables minting.
    /// Callable once. Also creates and transfers IssuanceAdminCap.
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

        // Send IssuanceAdminCap to the IssuanceContract's controlling address
        let iac = IssuanceAdminCap { id: object::new(ctx) };
        transfer::transfer(iac, issuance_contract);

        events::emit_tranches_created(senior_cap, mezz_cap, junior_cap, clock::timestamp_ms(clock));
    }

    // ─── Minting ──────────────────────────────────────────────────────────────

    /// Mint `amount` tokens of the specified tranche to `recipient`.
    /// Only callable by the holder of IssuanceAdminCap.
    ///
    /// # Parameters
    /// - `tranche_type`  0 = Senior, 1 = Mezz, 2 = Junior
    /// - `amount`        Number of base units to mint
    /// - `recipient`     Destination address
    public entry fun mint(
        _cap:         &IssuanceAdminCap,
        registry:     &mut TrancheRegistry,
        tranche_type: u8,
        amount:       u64,
        recipient:    address,
        clock:        &Clock,
        ctx:          &mut TxContext,
    ) {
        assert!(registry.minting_enabled,   errors::minting_disabled());
        assert!(registry.tranches_created,  errors::tranches_not_created());

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

        events::emit_tokens_minted(tranche_type, amount, recipient, clock::timestamp_ms(clock));
    }

    // ─── Melting (burning) ────────────────────────────────────────────────────

    /// Burn (melt) Senior tokens. Callable by any holder passing their Coin in.
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

    /// Burn (melt) Mezzanine tokens.
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

    /// Burn (melt) Junior tokens.
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

    /// Permanently disable minting. Called by PoolContract upon pool closure.
    public entry fun disable_minting(
        _cap:     &TrancheAdminCap,
        registry: &mut TrancheRegistry,
        clock:    &Clock,
    ) {
        registry.minting_enabled = false;
        events::emit_minting_disabled(clock::timestamp_ms(clock));
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

    public fun senior_remaining(r: &TrancheRegistry): u64 {
        r.senior_supply_cap - r.senior_minted
    }
    public fun mezz_remaining(r: &TrancheRegistry): u64 {
        r.mezz_supply_cap - r.mezz_minted
    }
    public fun junior_remaining(r: &TrancheRegistry): u64 {
        r.junior_supply_cap - r.junior_minted
    }
    public fun tranche_senior(): u8 { TRANCHE_SENIOR }
    public fun tranche_mezz(): u8   { TRANCHE_MEZZ }
    public fun tranche_junior(): u8 { TRANCHE_JUNIOR }

    // #[test_only]
    // public fun init_for_testing(ctx: &mut TxContext) {
    //     init(ctx);
    // }
}
