/// Fixed-point arithmetic helpers for interest and payment calculations.
/// All rates are expressed in basis points (1 bp = 0.01% = 1/10_000).
/// All amounts are in the stablecoin's smallest unit (6 decimal places assumed).
module securitization::math {

    // ── Constants ─────────────────────────────────────────────────────────────

    /// Basis points denominator (10_000 bp = 100%)
    const BASIS_POINTS_DENOMINATOR: u64 = 10_000;

    /// Seconds in a calendar year (365 days)
    const SECONDS_PER_YEAR: u64 = 31_536_000;

    /// Seconds in a standard 30-day month
    const SECONDS_PER_MONTH: u64 = 2_592_000;

    /// Seconds in a standard 91-day quarter
    const SECONDS_PER_QUARTER: u64 = 7_862_400;

    // ── Public functions ──────────────────────────────────────────────────────

    /// Compute simple interest accrued on `principal` over `elapsed_seconds`
    /// at an annual rate of `rate_bps` basis points.
    ///
    /// Formula:  interest = principal × rate_bps × elapsed_seconds
    ///                      ────────────────────────────────────────
    ///                        BASIS_POINTS_DENOMINATOR × SECONDS_PER_YEAR
    ///
    /// Returns 0 if any input is 0 (avoids division by zero at callers).
    public fun simple_interest(
        principal:       u64,
        rate_bps:        u32,
        elapsed_seconds: u64,
    ): u64 {
        if (principal == 0 || rate_bps == 0 || elapsed_seconds == 0) {
            return 0
        };
        let numerator   = (principal as u128) * (rate_bps as u128) * (elapsed_seconds as u128);
        let denominator = (BASIS_POINTS_DENOMINATOR as u128) * (SECONDS_PER_YEAR as u128);
        ((numerator / denominator) as u64)
    }

    /// Calculate how many tokens an `amount` of stablecoin buys at `price_per_unit`.
    /// Returns 0 if `price_per_unit` is 0 (callers must guard against this).
    public fun tokens_for_amount(amount: u64, price_per_unit: u64): u64 {
        if (price_per_unit == 0) { return 0 };
        amount / price_per_unit
    }

    /// Saturating subtraction — returns 0 instead of aborting on underflow.
    public fun saturating_sub(a: u64, b: u64): u64 {
        if (b >= a) { 0 } else { a - b }
    }

    /// Minimum of two u64 values.
    public fun min_u64(a: u64, b: u64): u64 {
        if (a < b) { a } else { b }
    }

    /// Apply a basis-point percentage to an amount.
    /// E.g., apply_bps(1_000_000, 500) == 50_000  (5% of 1_000_000)
    public fun apply_bps(amount: u64, bps: u64): u64 {
        ((amount as u128) * (bps as u128) / (BASIS_POINTS_DENOMINATOR as u128)) as u64
    }

    /// Seconds per year constant accessor
    public fun seconds_per_year(): u64 { SECONDS_PER_YEAR }

    /// Seconds per month constant accessor
    public fun seconds_per_month(): u64 { SECONDS_PER_MONTH }

    /// Seconds per quarter constant accessor
    public fun seconds_per_quarter(): u64 { SECONDS_PER_QUARTER }

    /// Basis-points denominator accessor
    public fun basis_points_denom(): u64 { BASIS_POINTS_DENOMINATOR }
}
