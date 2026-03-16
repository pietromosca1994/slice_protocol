/// # PaymentVault
///
/// Secure custody layer for all capital flows in the securitisation protocol.
///
/// ## Responsibilities
/// - Holding investor subscription proceeds during issuance
/// - Receiving periodic pool repayments from the borrower/servicer
/// - Releasing funds to the WaterfallEngine for distribution to tranche holders
/// - Maintaining a full accounting trail (total deposited, total distributed)
///
/// ## IOTA Move design notes
/// - The vault is generic over coin type `C` (the stablecoin).
/// - `VaultBalance<C>` is a shared object holding a `Balance<C>`.
/// - `VaultAdminCap` controls privileged operations (releaseFunds, authorise).
/// - An `AuthorisedDepositorRecord` stored in a `Table` controls who may deposit.
/// - The vault enforces that only registered depositors can call `deposit_funds`.
#[allow(duplicate_alias)]
module spv::payment_vault {
    use iota::balance::{Self, Balance};
    use iota::coin::{Self, Coin};
    use iota::object::{Self, UID, ID};
    use iota::table::{Self, Table};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use spv::errors;
    use spv::events;

    // ─── Capability ───────────────────────────────────────────────────────────

    public struct VaultAdminCap has key, store { id: UID }

    // ─── Shared vault ─────────────────────────────────────────────────────────

    public struct VaultBalance<phantom C> has key {
        id:                   UID,
        balance:              Balance<C>,
        total_deposited:      u64,
        total_distributed:    u64,
        authorised_depositors: Table<address, bool>,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let cap = VaultAdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    /// Create and share a new VaultBalance for stablecoin type C.
    /// Call once per deployment.
    public entry fun create_vault<C>(
        _cap: &VaultAdminCap,
        ctx:  &mut TxContext,
    ) {
        let vault = VaultBalance<C> {
            id:                    object::new(ctx),
            balance:               balance::zero<C>(),
            total_deposited:       0,
            total_distributed:     0,
            authorised_depositors: table::new(ctx),
        };
        transfer::share_object(vault);
    }

    /// Unsealed variant: returns VaultBalance by value without sharing.
    /// Use in a single-PTB setup flow; call `share_vault` as the last step.
    public fun create_vault_unsealed<C>(
        _cap: &VaultAdminCap,
        ctx:  &mut TxContext,
    ): VaultBalance<C> {
        VaultBalance<C> {
            id:                    object::new(ctx),
            balance:               balance::zero<C>(),
            total_deposited:       0,
            total_distributed:     0,
            authorised_depositors: table::new(ctx),
        }
    }

    /// Returns the object ID of a VaultBalance (its own UID).
    /// Used in PTB to get the ID before sharing, so it can be wired into PoolState.
    public fun object_id<C>(v: &VaultBalance<C>): ID { object::uid_to_inner(&v.id) }

    /// Shares an unsealed VaultBalance. Call after all PTB wiring is complete.
    public fun share_vault<C>(vault: VaultBalance<C>) {
        transfer::share_object(vault);
    }

    // ─── Depositor management ─────────────────────────────────────────────────

    /// Grant deposit rights to an address (e.g., IssuanceContract, servicer).
    public entry fun authorise_depositor<C>(
        _cap:     &VaultAdminCap,
        vault:    &mut VaultBalance<C>,
        depositor: address,
        clock:    &Clock,
    ) {
        assert!(
            !table::contains(&vault.authorised_depositors, depositor),
            errors::depositor_already_authorised()
        );
        table::add(&mut vault.authorised_depositors, depositor, true);
        events::emit_depositor_authorised(depositor, clock::timestamp_ms(clock));
    }

    /// Revoke deposit rights.
    public entry fun revoke_depositor<C>(
        _cap:     &VaultAdminCap,
        vault:    &mut VaultBalance<C>,
        depositor: address,
    ) {
        assert!(
            table::contains(&vault.authorised_depositors, depositor),
            errors::not_authorised_depositor()
        );
        table::remove(&mut vault.authorised_depositors, depositor);
    }

    // ─── Core vault functions ─────────────────────────────────────────────────

    /// Deposit stablecoin into the vault.
    /// Caller must be an authorised depositor.
    ///
    /// # Parameters
    /// - `payment` Coin<C> from the caller's wallet
    /// Returns new vault balance after deposit.
    public fun deposit_funds<C>(
        vault:   &mut VaultBalance<C>,
        payment: Coin<C>,
        clock:   &Clock,
        ctx:     &TxContext,
    ): u64 {
        let depositor = tx_context::sender(ctx);
        assert!(
            table::contains(&vault.authorised_depositors, depositor),
            errors::not_authorised_depositor()
        );
        let amount = coin::value(&payment);
        assert!(amount > 0, errors::zero_deposit_amount());

        balance::join(&mut vault.balance, coin::into_balance(payment));
        vault.total_deposited = vault.total_deposited + amount;

        let new_balance = balance::value(&vault.balance);
        events::emit_funds_deposited(depositor, amount, new_balance, clock::timestamp_ms(clock));
        new_balance
    }

    /// Entry wrapper for deposit_funds — accepts Coin directly from a transaction.
    public entry fun deposit<C>(
        vault:   &mut VaultBalance<C>,
        payment: Coin<C>,
        clock:   &Clock,
        ctx:     &mut TxContext,
    ) {
        deposit_funds(vault, payment, clock, ctx);
    }

    /// Release `amount` stablecoin to `recipient`.
    /// Only the VaultAdminCap holder (WaterfallEngine controller) may call this.
    ///
    /// # Parameters
    /// - `recipient` Destination address (typically WaterfallEngine or tranche holder)
    /// - `amount`    Amount to release in base units
    public entry fun release_funds<C>(
        _cap:      &VaultAdminCap,
        vault:     &mut VaultBalance<C>,
        recipient: address,
        amount:    u64,
        clock:     &Clock,
        ctx:       &mut TxContext,
    ) {
        assert!(amount > 0, errors::zero_release_amount());
        assert!(
            balance::value(&vault.balance) >= amount,
            errors::insufficient_vault_balance()
        );

        let coin = coin::take(&mut vault.balance, amount, ctx);
        transfer::public_transfer(coin, recipient);
        vault.total_distributed = vault.total_distributed + amount;

        let new_balance = balance::value(&vault.balance);
        events::emit_funds_released(recipient, amount, new_balance, clock::timestamp_ms(clock));
    }

    /// Accept a `Balance<C>` transferred directly from another Move module
    /// (e.g. `issuance_contract::release_funds_to_vault`).
    ///
    /// This is `public` but NOT `entry` — only Move code that already holds a
    /// `Balance<C>` (extracted from an owned `IssuanceState`) can call it.
    /// No depositor authorisation check is needed: physical possession of the
    /// `Balance` value is proof of authority.
    public fun receive_balance<C>(
        vault: &mut VaultBalance<C>,
        funds: Balance<C>,
        clock: &Clock,
    ) {
        let amount      = balance::value(&funds);
        balance::join(&mut vault.balance, funds);
        vault.total_deposited = vault.total_deposited + amount;
        let new_balance = balance::value(&vault.balance);
        events::emit_funds_deposited(@0x0, amount, new_balance, clock::timestamp_ms(clock));
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun vault_balance<C>(vault: &VaultBalance<C>): u64 {
        balance::value(&vault.balance)
    }
    public fun total_deposited<C>(vault: &VaultBalance<C>): u64  { vault.total_deposited }
    public fun total_distributed<C>(vault: &VaultBalance<C>): u64 { vault.total_distributed }
    public fun is_authorised_depositor<C>(vault: &VaultBalance<C>, depositor: address): bool {
        table::contains(&vault.authorised_depositors, depositor)
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
