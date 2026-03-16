#[allow(duplicate_alias)]
module spv::events {
    use iota::event;
    use iota::object::ID;

    // ═══════════════════════════════════════════════════════════════════════════
    //  ComplianceRegistry events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct InvestorAdded has copy, drop {
        investor:            address,
        accreditation_level: u8,
        jurisdiction:        vector<u8>,
        timestamp:           u64,
    }

    public struct InvestorRemoved has copy, drop {
        investor:  address,
        timestamp: u64,
    }

    public struct TransferRestrictionsUpdated has copy, drop {
        enabled:   bool,
        timestamp: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  PaymentVault events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct FundsDeposited has copy, drop {
        depositor:   address,
        amount:      u64,
        new_balance: u64,
        timestamp:   u64,
    }

    public struct FundsReleased has copy, drop {
        recipient:   address,
        amount:      u64,
        new_balance: u64,
        timestamp:   u64,
    }

    public struct DepositorAuthorised has copy, drop {
        depositor: address,
        timestamp: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  SPVRegistry events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct PoolRegistered has copy, drop {
        pool_obj_id: ID,
        spv:         address,
        timestamp:   u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  Emit helpers
    // ═══════════════════════════════════════════════════════════════════════════

    public fun emit_investor_added(
        investor:            address,
        accreditation_level: u8,
        jurisdiction:        vector<u8>,
        timestamp:           u64,
    ) {
        event::emit(InvestorAdded { investor, accreditation_level, jurisdiction, timestamp });
    }

    public fun emit_investor_removed(investor: address, timestamp: u64) {
        event::emit(InvestorRemoved { investor, timestamp });
    }

    public fun emit_transfer_restrictions_updated(enabled: bool, timestamp: u64) {
        event::emit(TransferRestrictionsUpdated { enabled, timestamp });
    }

    public fun emit_funds_deposited(
        depositor:   address,
        amount:      u64,
        new_balance: u64,
        timestamp:   u64,
    ) {
        event::emit(FundsDeposited { depositor, amount, new_balance, timestamp });
    }

    public fun emit_funds_released(
        recipient:   address,
        amount:      u64,
        new_balance: u64,
        timestamp:   u64,
    ) {
        event::emit(FundsReleased { recipient, amount, new_balance, timestamp });
    }

    public fun emit_depositor_authorised(depositor: address, timestamp: u64) {
        event::emit(DepositorAuthorised { depositor, timestamp });
    }

    public fun emit_pool_registered(pool_obj_id: ID, spv: address, timestamp: u64) {
        event::emit(PoolRegistered { pool_obj_id, spv, timestamp });
    }
}
