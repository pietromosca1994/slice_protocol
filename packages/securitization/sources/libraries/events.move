/// Centralised event definitions for the IOTA Securitization Protocol.
/// All six contracts emit events defined here so off-chain indexers
/// need only subscribe to a single module's event stream.
module securitization::events {
    use iota::event;

    // ═══════════════════════════════════════════════════════════════════════════
    //  PoolContract events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct PoolInitialised has copy, drop {
        pool_id:          vector<u8>,
        originator:       address,
        spv:              address,
        total_pool_value: u64,
        timestamp:        u64,
    }

    public struct PoolActivated has copy, drop {
        pool_id:   vector<u8>,
        timestamp: u64,
    }

    public struct PerformanceDataUpdated has copy, drop {
        new_outstanding_principal: u64,
        oracle_timestamp:          u64,
        block_timestamp:           u64,
    }

    public struct PoolDefaulted has copy, drop {
        pool_id:   vector<u8>,
        timestamp: u64,
    }

    public struct PoolClosed has copy, drop {
        pool_id:   vector<u8>,
        timestamp: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  TrancheFactory events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct TranchesCreated has copy, drop {
        senior_supply_cap: u64,
        mezz_supply_cap:   u64,
        junior_supply_cap: u64,
        timestamp:         u64,
    }

    public struct TokensMinted has copy, drop {
        tranche_type: u8,   // 0=Senior, 1=Mezz, 2=Junior
        amount:       u64,
        recipient:    address,
        timestamp:    u64,
    }

    public struct TokensMelted has copy, drop {
        tranche_type: u8,
        amount:       u64,
        timestamp:    u64,
    }

    public struct MintingDisabled has copy, drop {
        timestamp: u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  IssuanceContract events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct IssuanceStarted has copy, drop {
        sale_start:          u64,
        sale_end:            u64,
        price_senior:        u64,
        price_mezz:          u64,
        price_junior:        u64,
        timestamp:           u64,
    }

    public struct IssuanceEnded has copy, drop {
        total_raised: u64,
        timestamp:    u64,
    }

    public struct InvestmentMade has copy, drop {
        investor:      address,
        tranche_type:  u8,
        amount_paid:   u64,
        tokens_issued: u64,
        timestamp:     u64,
    }

    public struct RefundIssued has copy, drop {
        investor:       address,
        refunded_amount: u64,
        timestamp:      u64,
    }

    // ═══════════════════════════════════════════════════════════════════════════
    //  WaterfallEngine events
    // ═══════════════════════════════════════════════════════════════════════════

    public struct InterestAccrued has copy, drop {
        senior_interest: u64,
        mezz_interest:   u64,
        junior_interest: u64,
        timestamp:       u64,
    }

    public struct PaymentDeposited has copy, drop {
        amount:      u64,
        new_balance: u64,
        timestamp:   u64,
    }

    public struct WaterfallExecuted has copy, drop {
        to_senior:  u64,
        to_mezz:    u64,
        to_junior:  u64,
        to_reserve: u64,
        timestamp:  u64,
    }

    public struct TurboModeTriggered has copy, drop {
        timestamp: u64,
    }

    public struct DefaultModeTriggered has copy, drop {
        timestamp: u64,
    }

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
    //  Emit helpers — one per event type
    // ═══════════════════════════════════════════════════════════════════════════

    public fun emit_pool_initialised(pool_id: vector<u8>, originator: address, spv: address, total_pool_value: u64, timestamp: u64) {
        event::emit(PoolInitialised { pool_id, originator, spv, total_pool_value, timestamp });
    }
    public fun emit_pool_activated(pool_id: vector<u8>, timestamp: u64) {
        event::emit(PoolActivated { pool_id, timestamp });
    }
    public fun emit_performance_data_updated(new_outstanding_principal: u64, oracle_timestamp: u64, block_timestamp: u64) {
        event::emit(PerformanceDataUpdated { new_outstanding_principal, oracle_timestamp, block_timestamp });
    }
    public fun emit_pool_defaulted(pool_id: vector<u8>, timestamp: u64) {
        event::emit(PoolDefaulted { pool_id, timestamp });
    }
    public fun emit_pool_closed(pool_id: vector<u8>, timestamp: u64) {
        event::emit(PoolClosed { pool_id, timestamp });
    }

    public fun emit_tranches_created(senior_supply_cap: u64, mezz_supply_cap: u64, junior_supply_cap: u64, timestamp: u64) {
        event::emit(TranchesCreated { senior_supply_cap, mezz_supply_cap, junior_supply_cap, timestamp });
    }
    public fun emit_tokens_minted(tranche_type: u8, amount: u64, recipient: address, timestamp: u64) {
        event::emit(TokensMinted { tranche_type, amount, recipient, timestamp });
    }
    public fun emit_tokens_melted(tranche_type: u8, amount: u64, timestamp: u64) {
        event::emit(TokensMelted { tranche_type, amount, timestamp });
    }
    public fun emit_minting_disabled(timestamp: u64) {
        event::emit(MintingDisabled { timestamp });
    }

    public fun emit_issuance_started(sale_start: u64, sale_end: u64, price_senior: u64, price_mezz: u64, price_junior: u64, timestamp: u64) {
        event::emit(IssuanceStarted { sale_start, sale_end, price_senior, price_mezz, price_junior, timestamp });
    }
    public fun emit_issuance_ended(total_raised: u64, timestamp: u64) {
        event::emit(IssuanceEnded { total_raised, timestamp });
    }
    public fun emit_investment_made(investor: address, tranche_type: u8, amount_paid: u64, tokens_issued: u64, timestamp: u64) {
        event::emit(InvestmentMade { investor, tranche_type, amount_paid, tokens_issued, timestamp });
    }
    public fun emit_refund_issued(investor: address, refunded_amount: u64, timestamp: u64) {
        event::emit(RefundIssued { investor, refunded_amount, timestamp });
    }

    public fun emit_interest_accrued(senior_interest: u64, mezz_interest: u64, junior_interest: u64, timestamp: u64) {
        event::emit(InterestAccrued { senior_interest, mezz_interest, junior_interest, timestamp });
    }
    public fun emit_payment_deposited(amount: u64, new_balance: u64, timestamp: u64) {
        event::emit(PaymentDeposited { amount, new_balance, timestamp });
    }
    public fun emit_waterfall_executed(to_senior: u64, to_mezz: u64, to_junior: u64, to_reserve: u64, timestamp: u64) {
        event::emit(WaterfallExecuted { to_senior, to_mezz, to_junior, to_reserve, timestamp });
    }
    public fun emit_turbo_mode_triggered(timestamp: u64) {
        event::emit(TurboModeTriggered { timestamp });
    }
    public fun emit_default_mode_triggered(timestamp: u64) {
        event::emit(DefaultModeTriggered { timestamp });
    }

    public fun emit_investor_added(investor: address, accreditation_level: u8, jurisdiction: vector<u8>, timestamp: u64) {
        event::emit(InvestorAdded { investor, accreditation_level, jurisdiction, timestamp });
    }
    public fun emit_investor_removed(investor: address, timestamp: u64) {
        event::emit(InvestorRemoved { investor, timestamp });
    }
    public fun emit_transfer_restrictions_updated(enabled: bool, timestamp: u64) {
        event::emit(TransferRestrictionsUpdated { enabled, timestamp });
    }

    public fun emit_funds_deposited(depositor: address, amount: u64, new_balance: u64, timestamp: u64) {
        event::emit(FundsDeposited { depositor, amount, new_balance, timestamp });
    }
    public fun emit_funds_released(recipient: address, amount: u64, new_balance: u64, timestamp: u64) {
        event::emit(FundsReleased { recipient, amount, new_balance, timestamp });
    }
    public fun emit_depositor_authorised(depositor: address, timestamp: u64) {
        event::emit(DepositorAuthorised { depositor, timestamp });
    }
}
