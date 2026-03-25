/// # IssuanceContract
///
/// Manages the primary issuance phase of tokenised securitisation tranches.
///
/// ## Responsibilities
/// - Opening and closing a timed subscription window
/// - Accepting stablecoin investments and issuing tranche tokens in return
/// - Verifying investor eligibility via the ComplianceRegistry
/// - Handling refunds for cancelled / undersubscribed issuances
/// - Custodying raised funds in the PaymentVault
///
/// ## Multi-pool change
/// - `IssuanceState` now stores `pool_obj_id: ID`, binding this issuance
///   instance to exactly one `PoolState`.
/// - `create_issuance_state` requires `pool_obj_id` so the binding is
///   established at creation time and emitted in events.
/// - This allows the UI to find all `IssuanceState` objects for a given pool
///   via indexed queries or event-based lookups.
///
/// ## IOTA Move design notes
/// - `IssuanceState<C>` is a shared object generic over the stablecoin type.
/// - `IssuanceAdminCap` (from TrancheFactory) is passed to `invest` because
///   this contract calls `tranche_factory::mint` on behalf of investors.
#[allow(duplicate_alias)]
module securitization::issuance_contract {
    use iota::coin::{Self, Coin};
    use iota::object::{Self, UID, ID};
    use iota::table::{Self, Table};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use iota::balance::{Self, Balance};
    use securitization::errors;
    use securitization::events;
    use securitization::math;
    use securitization::pool_contract::{Self, PoolState};
    use securitization::tranche_factory::{
        TrancheRegistry, IssuanceAdminCap, mint
    };
    use spv::compliance_registry::{Self, ComplianceRegistry};
    use spv::payment_vault::{Self, VaultBalance};

    // ─── Subscription record ──────────────────────────────────────────────────

    public struct Subscription has store {
        tranche_type:  u8,
        amount_paid:   u64,
        tokens_issued: u64,
        refunded:      bool,
    }

    // ─── Capability ───────────────────────────────────────────────────────────

    public struct IssuanceOwnerCap has key, store { id: UID }

    // ─── Shared issuance state ────────────────────────────────────────────────

    public struct IssuanceState<phantom C> has key {
        id:                    UID,
        /// Object ID of the `PoolState` this issuance belongs to.
        pool_obj_id:           ID,
        /// Object ID of the `VaultBalance` that receives proceeds on release.
        vault_obj_id:          ID,
        price_per_unit_senior: u64,
        price_per_unit_mezz:   u64,
        price_per_unit_junior: u64,
        sale_start:            u64,   // ms timestamp
        sale_end:              u64,   // ms timestamp
        total_raised:          u64,
        issuance_active:       bool,
        issuance_ended:        bool,
        /// Stablecoin balance held until released to PaymentVault
        vault_balance:         Balance<C>,
        /// Per-investor subscription records
        subscriptions:         Table<address, Subscription>,
        /// Whether the issuance met its minimum raise (set on end)
        succeeded:             bool,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let cap = IssuanceOwnerCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    /// Create and share a new `IssuanceState` for coin type C.
    /// Called once per pool deployment by the admin.
    ///
    /// # Multi-pool change
    /// `pool_obj_id` is now required so this state object is bound to exactly
    /// one pool and can be discovered by pool ID in the UI.
    ///
    /// # Interface change
    /// Prices are now set at creation time rather than at `start_issuance`,
    /// so the waterfall outstanding principal can be derived as
    /// `supply_cap × price` during pool setup without requiring the operator
    /// to supply redundant explicit values.
    ///
    /// # Parameters
    /// - `pool_obj_id`   Object ID of the owning `PoolState`
    /// - `price_senior`  Price in stablecoin base units per Senior token
    /// - `price_mezz`    Price in stablecoin base units per Mezz token
    /// - `price_junior`  Price in stablecoin base units per Junior token
    public entry fun create_issuance_state<C>(
        _cap:         &IssuanceOwnerCap,
        pool_obj_id:  ID,
        vault_obj_id: ID,
        price_senior: u64,
        price_mezz:   u64,
        price_junior: u64,
        ctx:          &mut TxContext,
    ) {
        assert!(price_senior > 0, errors::zero_price_per_unit());
        assert!(price_mezz   > 0, errors::zero_price_per_unit());
        assert!(price_junior > 0, errors::zero_price_per_unit());

        let state = IssuanceState<C> {
            id:                    object::new(ctx),
            pool_obj_id,
            vault_obj_id,
            price_per_unit_senior: price_senior,
            price_per_unit_mezz:   price_mezz,
            price_per_unit_junior: price_junior,
            sale_start:            0,
            sale_end:              0,
            total_raised:          0,
            issuance_active:       false,
            issuance_ended:        false,
            vault_balance:         balance::zero<C>(),
            subscriptions:         table::new(ctx),
            succeeded:             false,
        };
        transfer::share_object(state);
    }

    /// Unsealed variant: returns IssuanceState by value without sharing.
    /// Use in a single-PTB setup flow; call `share_issuance_state` as the last step.
    public fun create_issuance_state_unsealed<C>(
        _cap:         &IssuanceOwnerCap,
        pool_obj_id:  ID,
        vault_obj_id: ID,
        price_senior: u64,
        price_mezz:   u64,
        price_junior: u64,
        ctx:          &mut TxContext,
    ): IssuanceState<C> {
        assert!(price_senior > 0, errors::zero_price_per_unit());
        assert!(price_mezz   > 0, errors::zero_price_per_unit());
        assert!(price_junior > 0, errors::zero_price_per_unit());

        IssuanceState<C> {
            id:                    object::new(ctx),
            pool_obj_id,
            vault_obj_id,
            price_per_unit_senior: price_senior,
            price_per_unit_mezz:   price_mezz,
            price_per_unit_junior: price_junior,
            sale_start:            0,
            sale_end:              0,
            total_raised:          0,
            issuance_active:       false,
            issuance_ended:        false,
            vault_balance:         balance::zero<C>(),
            subscriptions:         table::new(ctx),
            succeeded:             false,
        }
    }

    /// Returns the object ID of an IssuanceState (its own UID, not pool_obj_id).
    /// Used in PTB to get the ID before sharing, so it can be wired into PoolState.
    public fun object_id<C>(s: &IssuanceState<C>): ID { object::uid_to_inner(&s.id) }

    /// Shares an unsealed IssuanceState. Call after all PTB wiring is complete.
    public fun share_issuance_state<C>(state: IssuanceState<C>) {
        transfer::share_object(state);
    }

    // ─── Lifecycle ────────────────────────────────────────────────────────────

    /// Open the subscription window. Prices were fixed at `create_issuance_state`
    /// and cannot change here.
    ///
    /// # Parameters
    /// - `sale_start`  Earliest timestamp (ms) at which `invest` is accepted
    /// - `sale_end`    Latest timestamp (ms); after this `invest` is rejected
    public entry fun start_issuance<C>(
        _cap:       &IssuanceOwnerCap,
        state:      &mut IssuanceState<C>,
        pool:       &PoolState,
        sale_start: u64,
        sale_end:   u64,
        clock:      &Clock,
    ) {
        // Ensure this issuance state is bound to the provided pool
        assert!(state.pool_obj_id == pool_contract::pool_obj_id(pool), errors::pool_not_active());
        assert!(!state.issuance_active,                                 errors::issuance_already_active());
        assert!(!state.issuance_ended,                                  errors::issuance_already_ended());
        assert!(pool_contract::is_active(pool),                         errors::pool_not_active());
        assert!(sale_end > sale_start,                                  errors::invalid_sale_window());
        assert!(sale_end > clock::timestamp_ms(clock),                  errors::invalid_sale_window());
        // Prices must have been set at creation
        assert!(state.price_per_unit_senior > 0,                        errors::zero_price_per_unit());
        assert!(state.price_per_unit_mezz   > 0,                        errors::zero_price_per_unit());
        assert!(state.price_per_unit_junior > 0,                        errors::zero_price_per_unit());

        state.sale_start      = sale_start;
        state.sale_end        = sale_end;
        state.issuance_active = true;

        events::emit_issuance_started(
            sale_start, sale_end,
            state.price_per_unit_senior, state.price_per_unit_mezz, state.price_per_unit_junior,
            clock::timestamp_ms(clock),
        );
    }

    /// Close the subscription window, finalise accounting, mark success/failure.
    public entry fun end_issuance<C>(
        _cap:  &IssuanceOwnerCap,
        state: &mut IssuanceState<C>,
        clock: &Clock,
    ) {
        assert!(state.issuance_active, errors::issuance_not_active());
        state.issuance_active = false;
        state.issuance_ended  = true;
        state.succeeded       = true; // protocol-level: all closed issuances succeed
        events::emit_issuance_ended(state.total_raised, clock::timestamp_ms(clock));
    }

    /// Invest in a tranche. Transfers stablecoin from investor, mints tokens.
    ///
    /// # Parameters
    /// - `tranche_type`  0 = Senior, 1 = Mezz, 2 = Junior
    /// - `payment`       Coin<C> from the investor's wallet
    public entry fun invest<C>(
        state:        &mut IssuanceState<C>,
        registry:     &mut TrancheRegistry,
        compliance:   &ComplianceRegistry,
        iac:          &IssuanceAdminCap,
        tranche_type: u8,
        payment:      Coin<C>,
        clock:        &Clock,
        ctx:          &mut TxContext,
    ) {
        let investor = tx_context::sender(ctx);
        let now      = clock::timestamp_ms(clock);

        assert!(state.issuance_active,               errors::issuance_not_active());
        assert!(now >= state.sale_start,             errors::issuance_not_active());
        assert!(now <= state.sale_end,               errors::issuance_not_active());
        assert!(
            compliance_registry::is_whitelisted(compliance, investor),
            errors::investor_not_verified()
        );

        let amount = coin::value(&payment);
        assert!(amount > 0, errors::zero_price_per_unit());

        let price = if (tranche_type == 0)      { state.price_per_unit_senior }
                    else if (tranche_type == 1) { state.price_per_unit_mezz }
                    else                        { state.price_per_unit_junior };

        let tokens_issued = math::tokens_for_amount(amount, price);
        assert!(tokens_issued > 0, errors::zero_tokens_calculated());

        // Custody the stablecoin in the vault balance
        balance::join(&mut state.vault_balance, coin::into_balance(payment));
        state.total_raised = state.total_raised + amount;

        // Mint tranche tokens to the investor
        mint(iac, registry, tranche_type, tokens_issued, investor, clock, ctx);

        // Record subscription
        if (table::contains(&state.subscriptions, investor)) {
            let sub = table::borrow_mut(&mut state.subscriptions, investor);
            sub.amount_paid   = sub.amount_paid + amount;
            sub.tokens_issued = sub.tokens_issued + tokens_issued;
        } else {
            table::add(&mut state.subscriptions, investor, Subscription {
                tranche_type,
                amount_paid:   amount,
                tokens_issued,
                refunded:      false,
            });
        };

        events::emit_investment_made(investor, tranche_type, amount, tokens_issued, now);
    }

    /// Issue a refund if the issuance was cancelled (succeeded == false after end).
    public entry fun refund<C>(
        state:    &mut IssuanceState<C>,
        investor: address,
        clock:    &Clock,
        ctx:      &mut TxContext,
    ) {
        assert!(state.issuance_ended,  errors::issuance_not_active());
        assert!(!state.succeeded,      errors::refund_not_permitted());
        assert!(
            table::contains(&state.subscriptions, investor),
            errors::no_subscription()
        );

        let sub = table::borrow_mut(&mut state.subscriptions, investor);
        assert!(!sub.refunded, errors::refund_not_permitted());

        let refund_amount = sub.amount_paid;
        sub.refunded = true;

        let refund_coin = coin::take(&mut state.vault_balance, refund_amount, ctx);
        transfer::public_transfer(refund_coin, investor);

        events::emit_refund_issued(investor, refund_amount, clock::timestamp_ms(clock));
    }

    /// Release all issuance proceeds into the `PaymentVault` after a successful issuance.
    ///
    /// Takes a direct mutable reference to `VaultBalance<C>` rather than an address.
    /// Using an address would send a `Coin` to the vault's object ID via
    /// `transfer::public_transfer`, but `VaultBalance` has no object-receive
    /// mechanism — the coin would be permanently inaccessible. Instead we extract
    /// the `Balance<C>` primitive and pass it to `payment_vault::receive_balance`,
    /// which joins it directly into the vault's internal balance.
    public entry fun release_funds_to_vault<C>(
        _cap:  &IssuanceOwnerCap,
        state: &mut IssuanceState<C>,
        vault: &mut VaultBalance<C>,
        clock: &Clock,
    ) {
        assert!(state.issuance_ended,                                 errors::issuance_not_active());
        assert!(state.succeeded,                                      errors::refund_not_permitted());
        assert!(payment_vault::object_id(vault) == state.vault_obj_id, errors::wrong_vault());
        let total = balance::value(&state.vault_balance);
        assert!(total > 0,                                            errors::no_subscription());
        let funds = balance::split(&mut state.vault_balance, total);
        payment_vault::receive_balance(vault, funds, clock);
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun pool_obj_id<C>(s: &IssuanceState<C>): ID          { s.pool_obj_id }
    public fun vault_obj_id<C>(s: &IssuanceState<C>): ID         { s.vault_obj_id }
    public fun total_raised<C>(s: &IssuanceState<C>): u64        { s.total_raised }
    public fun issuance_active<C>(s: &IssuanceState<C>): bool    { s.issuance_active }
    public fun issuance_ended<C>(s: &IssuanceState<C>): bool     { s.issuance_ended }
    public fun sale_start<C>(s: &IssuanceState<C>): u64          { s.sale_start }
    public fun sale_end<C>(s: &IssuanceState<C>): u64            { s.sale_end }
    public fun price_senior<C>(s: &IssuanceState<C>): u64        { s.price_per_unit_senior }
    public fun price_mezz<C>(s: &IssuanceState<C>): u64          { s.price_per_unit_mezz }
    public fun price_junior<C>(s: &IssuanceState<C>): u64        { s.price_per_unit_junior }
    public fun vault_balance_value<C>(s: &IssuanceState<C>): u64 {
        balance::value(&s.vault_balance)
    }
    public fun has_subscription<C>(s: &IssuanceState<C>, investor: address): bool {
        table::contains(&s.subscriptions, investor)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) { init(ctx); }
}
