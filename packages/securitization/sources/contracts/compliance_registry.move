/// # ComplianceRegistry
///
/// Enforces KYC/AML and regulatory compliance for the securitisation protocol
/// using IOTA Identity (DID) principles adapted to the Move object model.
///
/// ## Responsibilities
/// - Maintaining a whitelist of verified investors with accreditation levels,
///   jurisdictions, and mandatory holding-period lock-ups
/// - Gating every token transfer via `check_transfer_allowed`
/// - Integrating with IOTA Identity by storing DID document object IDs
///
/// ## Accreditation levels
/// | Level | Type                  |
/// |-------|-----------------------|
/// | 1     | Retail                |
/// | 2     | Professional          |
/// | 3     | Institutional         |
/// | 4     | Qualified Purchaser   |
///
/// ## IOTA Move design notes
/// - `ComplianceRegistry` is a shared object; any contract in the protocol
///   can read it to perform transfer eligibility checks.
/// - The `ComplianceAdminCap` capability is the only key that allows mutations.
/// - Holding periods are stored as absolute UNIX timestamps (ms) after which
///   the investor may freely transfer.
/// - `did_object_id` stores the IOTA Identity DID document object ID for each
///   investor, enabling off-chain resolvers to verify credentials.
#[allow(duplicate_alias)]
module securitization::compliance_registry {
    use iota::object::{Self, UID, ID};
    use iota::table::{Self, Table};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use securitization::errors;
    use securitization::events;
    use std::string::{Self, String};

    // ─── Investor record ──────────────────────────────────────────────────────

    public struct InvestorRecord has store {
        accreditation_level: u8,
        jurisdiction:        String,          // ISO-3166-1 country code
        holding_period_end:  u64,             // ms timestamp; 0 = no lock
        did_object_id:       ID,              // IOTA Identity DID document object
        active:              bool,
    }

    // ─── Capability ───────────────────────────────────────────────────────────

    public struct ComplianceAdminCap has key, store { id: UID }

    // ─── Shared state ─────────────────────────────────────────────────────────

    public struct ComplianceRegistry has key {
        id:                        UID,
        investors:                 Table<address, InvestorRecord>,
        transfer_restrictions_on:  bool,
        // Default holding period applied to new investors (in ms)
        default_holding_period_ms: u64,
    }

    // ─── Transfer check result ─────────────────────────────────────────────────

    public struct TransferCheckResult has copy, drop {
        allowed: bool,
        reason:  String,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let registry = ComplianceRegistry {
            id:                        object::new(ctx),
            investors:                 table::new(ctx),
            transfer_restrictions_on:  true,
            default_holding_period_ms: 0,
        };
        transfer::share_object(registry);

        let cap = ComplianceAdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    // ─── Admin config ─────────────────────────────────────────────────────────

    /// Set the global transfer restriction flag.
    /// When false, compliance checks are bypassed (emergency use only).
    public entry fun set_transfer_restrictions(
        _cap:    &ComplianceAdminCap,
        registry: &mut ComplianceRegistry,
        enabled: bool,
        clock:   &Clock,
    ) {
        registry.transfer_restrictions_on = enabled;
        events::emit_transfer_restrictions_updated(enabled, clock::timestamp_ms(clock));
    }

    /// Set the default holding period applied to newly added investors.
    public entry fun set_default_holding_period(
        _cap:               &ComplianceAdminCap,
        registry:           &mut ComplianceRegistry,
        holding_period_ms:  u64,
    ) {
        registry.default_holding_period_ms = holding_period_ms;
    }

    // ─── Investor management ──────────────────────────────────────────────────

    /// Add a verified investor to the whitelist.
    ///
    /// # Parameters
    /// - `investor`            Wallet address of the investor
    /// - `accreditation_level` 1–4 (see table above)
    /// - `jurisdiction`        ISO-3166-1 alpha-2 country code (e.g., b"US")
    /// - `did_object_id`       Object ID of the investor's IOTA Identity DID document
    /// - `custom_holding_ms`   Custom lock-up in ms; 0 uses the registry default
    public entry fun add_investor(
        _cap:               &ComplianceAdminCap,
        registry:           &mut ComplianceRegistry,
        investor:           address,
        accreditation_level: u8,
        jurisdiction:       vector<u8>,
        did_object_id:      ID,
        custom_holding_ms:  u64,
        clock:              &Clock,
    ) {
        assert!(
            !table::contains(&registry.investors, investor),
            errors::investor_already_exists()
        );
        assert!(
            accreditation_level >= 1 && accreditation_level <= 4,
            errors::invalid_accreditation_level()
        );
        assert!(jurisdiction != vector[], errors::empty_jurisdiction());

        let holding_ms = if (custom_holding_ms > 0) {
            custom_holding_ms
        } else {
            registry.default_holding_period_ms
        };

        let record = InvestorRecord {
            accreditation_level,
            jurisdiction: string::utf8(jurisdiction),
            holding_period_end: clock::timestamp_ms(clock) + holding_ms,
            did_object_id,
            active: true,
        };
        table::add(&mut registry.investors, investor, record);

        events::emit_investor_added(
            investor,
            accreditation_level,
            jurisdiction,
            clock::timestamp_ms(clock),
        );
    }

    /// Remove an investor from the whitelist (e.g., sanctions compliance).
    public entry fun remove_investor(
        _cap:     &ComplianceAdminCap,
        registry: &mut ComplianceRegistry,
        investor: address,
        clock:    &Clock,
    ) {
        assert!(table::contains(&registry.investors, investor), errors::investor_not_whitelisted());
        let record = table::borrow_mut(&mut registry.investors, investor);
        record.active = false;
        events::emit_investor_removed(investor, clock::timestamp_ms(clock));
    }

    /// Update an investor's accreditation level.
    public entry fun update_accreditation(
        _cap:               &ComplianceAdminCap,
        registry:           &mut ComplianceRegistry,
        investor:           address,
        new_level:          u8,
    ) {
        assert!(table::contains(&registry.investors, investor), errors::investor_not_whitelisted());
        assert!(new_level >= 1 && new_level <= 4, errors::invalid_accreditation_level());
        let record = table::borrow_mut(&mut registry.investors, investor);
        record.accreditation_level = new_level;
    }

    // ─── Transfer eligibility checks ──────────────────────────────────────────

    /// Check whether a transfer from `from` to `to` is allowed.
    /// Returns a `TransferCheckResult` with a boolean and human-readable reason.
    public fun check_transfer_allowed(
        registry: &ComplianceRegistry,
        from:     address,
        to:       address,
        clock:    &Clock,
    ): TransferCheckResult {
        // If restrictions are off, allow everything
        if (!registry.transfer_restrictions_on) {
            return TransferCheckResult {
                allowed: true,
                reason:  string::utf8(b"Restrictions disabled"),
            }
        };

        // Sender must be whitelisted and active
        if (!table::contains(&registry.investors, from)) {
            return TransferCheckResult {
                allowed: false,
                reason:  string::utf8(b"Sender not whitelisted"),
            }
        };
        let from_record = table::borrow(&registry.investors, from);
        if (!from_record.active) {
            return TransferCheckResult {
                allowed: false,
                reason:  string::utf8(b"Sender removed from whitelist"),
            }
        };

        // Sender must have passed their holding period
        let now = clock::timestamp_ms(clock);
        if (from_record.holding_period_end > now) {
            return TransferCheckResult {
                allowed: false,
                reason:  string::utf8(b"Sender in holding period"),
            }
        };

        // Recipient must be whitelisted and active
        if (!table::contains(&registry.investors, to)) {
            return TransferCheckResult {
                allowed: false,
                reason:  string::utf8(b"Recipient not whitelisted"),
            }
        };
        let to_record = table::borrow(&registry.investors, to);
        if (!to_record.active) {
            return TransferCheckResult {
                allowed: false,
                reason:  string::utf8(b"Recipient removed from whitelist"),
            }
        };

        TransferCheckResult {
            allowed: true,
            reason:  string::utf8(b"Transfer allowed"),
        }
    }

    /// Assert that a transfer is allowed; aborts with ETransferBlocked if not.
    public fun assert_transfer_allowed(
        registry: &ComplianceRegistry,
        from:     address,
        to:       address,
        clock:    &Clock,
    ) {
        let result = check_transfer_allowed(registry, from, to, clock);
        assert!(result.allowed, errors::transfer_blocked());
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun is_whitelisted(registry: &ComplianceRegistry, investor: address): bool {
        if (!table::contains(&registry.investors, investor)) { return false };
        let r = table::borrow(&registry.investors, investor);
        r.active
    }

    public fun accreditation_level(registry: &ComplianceRegistry, investor: address): u8 {
        assert!(table::contains(&registry.investors, investor), errors::investor_not_whitelisted());
        table::borrow(&registry.investors, investor).accreditation_level
    }

    public fun holding_period_end(registry: &ComplianceRegistry, investor: address): u64 {
        assert!(table::contains(&registry.investors, investor), errors::investor_not_whitelisted());
        table::borrow(&registry.investors, investor).holding_period_end
    }

    public fun transfer_restrictions_on(registry: &ComplianceRegistry): bool {
        registry.transfer_restrictions_on
    }

    public fun check_result_allowed(r: &TransferCheckResult): bool { r.allowed }
    public fun check_result_reason(r: &TransferCheckResult): String { r.reason }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
