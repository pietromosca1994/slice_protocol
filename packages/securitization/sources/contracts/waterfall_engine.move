/// # WaterfallEngine
///
/// Central cash-flow management contract. Implements the payment priority waterfall:
/// Senior (interest → principal) → Mezzanine (interest → principal) → Junior.
///
/// ## Waterfall modes
/// | Mode        | Behaviour                                                       |
/// |-------------|------------------------------------------------------------------|
/// | Normal      | Standard priority order; excess to reserve                      |
/// | Turbo       | All excess cash redirected to accelerate Senior principal paydown|
/// | DefaultMode | Only Senior receives distributions; others suspended            |
///
/// ## IOTA Move design notes
/// - `WaterfallState` is a shared object.
/// - Payment frequency (Monthly / Quarterly) drives interest accrual cadence.
/// - The `WaterfallAdminCap` is held by the admin; the `PoolCap` is minted and
///   sent to the PoolContract address to allow it to trigger DefaultMode.
#[allow(duplicate_alias)]
module securitization::waterfall_engine {
    use iota::object::{Self, UID};
    use iota::transfer;
    use iota::tx_context::{Self, TxContext};
    use iota::clock::{Self, Clock};
    use securitization::errors;
    use securitization::events;
    use securitization::math;
    // use securitization::pool_contract::PoolState;

    // ─── Mode constants ───────────────────────────────────────────────────────
    const MODE_NORMAL:  u8 = 0;
    const MODE_TURBO:   u8 = 1;
    const MODE_DEFAULT: u8 = 2;

    // ─── Frequency constants ──────────────────────────────────────────────────
    const FREQ_MONTHLY:   u8 = 0;
    const FREQ_QUARTERLY: u8 = 1;

    // ─── Capabilities ─────────────────────────────────────────────────────────

    public struct WaterfallAdminCap has key, store { id: UID }

    /// Held by the PoolContract address; allows triggering default mode.
    public struct PoolCap has key, store { id: UID }

    // ─── Distribution result (returned by execute_waterfall) ──────────────────

    public struct DistributionResult has copy, drop {
        to_senior:  u64,
        to_mezz:    u64,
        to_junior:  u64,
        to_reserve: u64,
    }

    // ─── Shared state ─────────────────────────────────────────────────────────

    public struct WaterfallState has key {
        id:                    UID,
        // Outstanding principal per tranche
        senior_outstanding:    u64,
        mezz_outstanding:      u64,
        junior_outstanding:    u64,
        // Accrued but unpaid interest per tranche
        senior_accrued_interest: u64,
        mezz_accrued_interest:   u64,
        junior_accrued_interest: u64,
        // Interest rates per tranche in basis points
        senior_rate_bps:       u32,
        mezz_rate_bps:         u32,
        junior_rate_bps:       u32,
        // Reserve buffer
        reserve_account:       u64,
        // Available funds waiting for waterfall execution
        pending_funds:         u64,
        // Timestamps
        last_distribution_ms:  u64,
        // Configuration
        payment_frequency:     u8,
        waterfall_status:      u8,
    }

    // ─── Init ─────────────────────────────────────────────────────────────────

    fun init(ctx: &mut TxContext) {
        let state = WaterfallState {
            id:                    object::new(ctx),
            senior_outstanding:    0,
            mezz_outstanding:      0,
            junior_outstanding:    0,
            senior_accrued_interest: 0,
            mezz_accrued_interest:   0,
            junior_accrued_interest: 0,
            senior_rate_bps:       0,
            mezz_rate_bps:         0,
            junior_rate_bps:       0,
            reserve_account:       0,
            pending_funds:         0,
            last_distribution_ms:  0,
            payment_frequency:     FREQ_MONTHLY,
            waterfall_status:      MODE_NORMAL,
        };
        transfer::share_object(state);

        let cap = WaterfallAdminCap { id: object::new(ctx) };
        transfer::transfer(cap, tx_context::sender(ctx));
    }

    // ─── Admin setup ──────────────────────────────────────────────────────────

    /// Initialise the waterfall with outstanding amounts and interest rates.
    /// Called once after issuance closes successfully.
    public entry fun initialise_waterfall(
        _cap:               &WaterfallAdminCap,
        state:              &mut WaterfallState,
        senior_outstanding: u64,
        mezz_outstanding:   u64,
        junior_outstanding: u64,
        senior_rate_bps:    u32,
        mezz_rate_bps:      u32,
        junior_rate_bps:    u32,
        payment_frequency:  u8,
        pool_contract_addr: address,
        clock:              &Clock,
        ctx:                &mut TxContext,
    ) {
        assert!(payment_frequency <= FREQ_QUARTERLY, errors::already_in_mode());

        state.senior_outstanding  = senior_outstanding;
        state.mezz_outstanding    = mezz_outstanding;
        state.junior_outstanding  = junior_outstanding;
        state.senior_rate_bps     = senior_rate_bps;
        state.mezz_rate_bps       = mezz_rate_bps;
        state.junior_rate_bps     = junior_rate_bps;
        state.payment_frequency   = payment_frequency;
        state.last_distribution_ms = clock::timestamp_ms(clock);

        // Mint PoolCap and send to pool contract address
        let pool_cap = PoolCap { id: object::new(ctx) };
        transfer::transfer(pool_cap, pool_contract_addr);
    }

    // ─── Core waterfall functions ─────────────────────────────────────────────

    /// Accrue interest on each tranche based on elapsed time since last accrual.
    /// Uses simple interest: principal × rate × time / (10_000 × seconds_per_year).
    public entry fun accrue_interest(
        state: &mut WaterfallState,
        clock: &Clock,
    ) {
        let now     = clock::timestamp_ms(clock);
        let elapsed_ms = now - state.last_distribution_ms;
        // Convert ms to seconds
        let elapsed_s  = elapsed_ms / 1000;
        assert!(elapsed_s > 0, errors::no_time_elapsed());

        let senior_interest = math::simple_interest(
            state.senior_outstanding, state.senior_rate_bps, elapsed_s
        );
        let mezz_interest = math::simple_interest(
            state.mezz_outstanding, state.mezz_rate_bps, elapsed_s
        );
        let junior_interest = math::simple_interest(
            state.junior_outstanding, state.junior_rate_bps, elapsed_s
        );

        state.senior_accrued_interest = state.senior_accrued_interest + senior_interest;
        state.mezz_accrued_interest   = state.mezz_accrued_interest   + mezz_interest;
        state.junior_accrued_interest = state.junior_accrued_interest + junior_interest;

        events::emit_interest_accrued(senior_interest, mezz_interest, junior_interest, now);
    }

    /// Receive a pool repayment and add to pending distributable balance.
    /// In a full integration the caller would pass Coin<C> and this function
    /// would join it into an internal Balance; here we track the amount numerically.
    public entry fun deposit_payment(
        state:  &mut WaterfallState,
        amount: u64,
        clock:  &Clock,
    ) {
        assert!(amount > 0, errors::no_funds_available());
        // Accrue interest before accepting new funds
        let now = clock::timestamp_ms(clock);
        let elapsed_s = (now - state.last_distribution_ms) / 1000;
        if (elapsed_s > 0) {
            let si = math::simple_interest(state.senior_outstanding, state.senior_rate_bps, elapsed_s);
            let mi = math::simple_interest(state.mezz_outstanding,   state.mezz_rate_bps,   elapsed_s);
            let ji = math::simple_interest(state.junior_outstanding,  state.junior_rate_bps,  elapsed_s);
            state.senior_accrued_interest = state.senior_accrued_interest + si;
            state.mezz_accrued_interest   = state.mezz_accrued_interest   + mi;
            state.junior_accrued_interest = state.junior_accrued_interest + ji;
        };

        state.pending_funds = state.pending_funds + amount;
        events::emit_payment_deposited(amount, state.pending_funds, now);
    }

    /// Execute the full waterfall over current pending funds.
    /// Routes funds per active mode: Normal | Turbo | DefaultMode.
    /// Returns a DistributionResult summarising allocations.
    public fun execute_waterfall(
        state: &mut WaterfallState,
        clock: &Clock,
    ): DistributionResult {
        let now = clock::timestamp_ms(clock);
        assert!(state.pending_funds > 0, errors::no_funds_available());

        let available = state.pending_funds;
        state.pending_funds = 0;

        let (to_senior, to_mezz, to_junior, to_reserve) =
            if (state.waterfall_status == MODE_DEFAULT) {
                // Default mode: all to Senior recovery
                let s = distribute_to_senior_internal(state, available);
                (available - s, 0, 0, s)
            } else if (state.waterfall_status == MODE_TURBO) {
                // Turbo: Senior interest, then aggressive principal paydown, then normal cascade
                let (s_paid, rem_after_senior) = pay_tranche_senior(state, available);
                // Redirect all remaining to Senior principal
                let extra_principal = math::min_u64(rem_after_senior, state.senior_outstanding);
                state.senior_outstanding = math::saturating_sub(state.senior_outstanding, extra_principal);
                let rem2 = rem_after_senior - extra_principal;
                let (m_paid, rem3) = pay_tranche_mezz(state, rem2);
                let (j_paid, rem4) = pay_tranche_junior(state, rem3);
                state.reserve_account = state.reserve_account + rem4;
                (s_paid + extra_principal, m_paid, j_paid, rem4)
            } else {
                // Normal: strict priority cascade
                let (s_paid, rem1) = pay_tranche_senior(state, available);
                let (m_paid, rem2) = pay_tranche_mezz(state, rem1);
                let (j_paid, rem3) = pay_tranche_junior(state, rem2);
                state.reserve_account = state.reserve_account + rem3;
                (s_paid, m_paid, j_paid, rem3)
            };

        state.last_distribution_ms = now;

        events::emit_waterfall_executed(to_senior, to_mezz, to_junior, to_reserve, now);

        DistributionResult { to_senior, to_mezz, to_junior, to_reserve }
    }

    /// Public entry wrapper for execute_waterfall (discards result).
    public entry fun run_waterfall(state: &mut WaterfallState, clock: &Clock) {
        execute_waterfall(state, clock);
    }

    // ─── Mode triggers ────────────────────────────────────────────────────────

    /// Activate Turbo Mode. Redirects excess cash to Senior principal paydown.
    public entry fun trigger_turbo_mode(
        _cap:  &WaterfallAdminCap,
        state: &mut WaterfallState,
        clock: &Clock,
    ) {
        assert!(state.waterfall_status == MODE_NORMAL, errors::turbo_requires_normal());
        state.waterfall_status = MODE_TURBO;
        events::emit_turbo_mode_triggered(clock::timestamp_ms(clock));
    }

    /// Activate Default Mode. Callable by WaterfallAdminCap or PoolCap.
    public entry fun trigger_default_mode_admin(
        _cap:  &WaterfallAdminCap,
        state: &mut WaterfallState,
        clock: &Clock,
    ) {
        state.waterfall_status = MODE_DEFAULT;
        events::emit_default_mode_triggered(clock::timestamp_ms(clock));
    }

    public entry fun trigger_default_mode_pool(
        _cap:  &PoolCap,
        state: &mut WaterfallState,
        clock: &Clock,
    ) {
        state.waterfall_status = MODE_DEFAULT;
        events::emit_default_mode_triggered(clock::timestamp_ms(clock));
    }

    // ─── Internal distribution helpers ────────────────────────────────────────

    /// Distribute available funds to Senior: interest first, then principal.
    /// Returns (amount_paid_to_senior, remaining_funds).
    fun pay_tranche_senior(state: &mut WaterfallState, available: u64): (u64, u64) {
        let interest_paid = math::min_u64(available, state.senior_accrued_interest);
        state.senior_accrued_interest = state.senior_accrued_interest - interest_paid;
        let after_interest = available - interest_paid;

        let principal_paid = math::min_u64(after_interest, state.senior_outstanding);
        state.senior_outstanding = state.senior_outstanding - principal_paid;
        let remaining = after_interest - principal_paid;

        (interest_paid + principal_paid, remaining)
    }

    fun pay_tranche_mezz(state: &mut WaterfallState, available: u64): (u64, u64) {
        let interest_paid = math::min_u64(available, state.mezz_accrued_interest);
        state.mezz_accrued_interest = state.mezz_accrued_interest - interest_paid;
        let after_interest = available - interest_paid;

        let principal_paid = math::min_u64(after_interest, state.mezz_outstanding);
        state.mezz_outstanding = state.mezz_outstanding - principal_paid;
        let remaining = after_interest - principal_paid;

        (interest_paid + principal_paid, remaining)
    }

    fun pay_tranche_junior(state: &mut WaterfallState, available: u64): (u64, u64) {
        let interest_paid = math::min_u64(available, state.junior_accrued_interest);
        state.junior_accrued_interest = state.junior_accrued_interest - interest_paid;
        let after_interest = available - interest_paid;

        let principal_paid = math::min_u64(after_interest, state.junior_outstanding);
        state.junior_outstanding = state.junior_outstanding - principal_paid;
        let remaining = after_interest - principal_paid;

        (interest_paid + principal_paid, remaining)
    }

    /// In default mode: absorb all available funds into Senior; return surplus to reserve.
    fun distribute_to_senior_internal(state: &mut WaterfallState, available: u64): u64 {
        let interest_paid = math::min_u64(available, state.senior_accrued_interest);
        state.senior_accrued_interest = state.senior_accrued_interest - interest_paid;
        let after_interest = available - interest_paid;
        let principal_paid = math::min_u64(after_interest, state.senior_outstanding);
        state.senior_outstanding = state.senior_outstanding - principal_paid;
        // Return how much is left over (surplus → reserve)
        after_interest - principal_paid
    }

    // ─── Read-only accessors ──────────────────────────────────────────────────

    public fun senior_outstanding(s: &WaterfallState): u64    { s.senior_outstanding }
    public fun mezz_outstanding(s: &WaterfallState): u64      { s.mezz_outstanding }
    public fun junior_outstanding(s: &WaterfallState): u64    { s.junior_outstanding }
    public fun senior_accrued(s: &WaterfallState): u64        { s.senior_accrued_interest }
    public fun mezz_accrued(s: &WaterfallState): u64          { s.mezz_accrued_interest }
    public fun junior_accrued(s: &WaterfallState): u64        { s.junior_accrued_interest }
    public fun reserve_account(s: &WaterfallState): u64       { s.reserve_account }
    public fun pending_funds(s: &WaterfallState): u64         { s.pending_funds }
    public fun waterfall_status(s: &WaterfallState): u8       { s.waterfall_status }
    public fun payment_frequency(s: &WaterfallState): u8      { s.payment_frequency }
    public fun last_distribution_ms(s: &WaterfallState): u64  { s.last_distribution_ms }
    public fun mode_normal(): u8   { MODE_NORMAL }
    public fun mode_turbo(): u8    { MODE_TURBO }
    public fun mode_default(): u8  { MODE_DEFAULT }
    public fun freq_monthly(): u8  { FREQ_MONTHLY }
    public fun freq_quarterly(): u8{ FREQ_QUARTERLY }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }
}
