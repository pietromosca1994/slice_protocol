/// Unit tests for the math library.
/// Tests exact values, boundary conditions, and overflow guards.
#[test_only]
module securitization::math_tests {
    use securitization::math;

    // ─── simple_interest ──────────────────────────────────────────────────────

    #[test]
    fun test_simple_interest_one_year() {
        // 1_000_000 principal at 10% (1000 bps) for 1 year
        // Expected: 1_000_000 * 1000 / 10_000 = 100_000
        let result = math::simple_interest(1_000_000, 1000, math::seconds_per_year());
        assert!(result == 100_000, 0);
    }

    #[test]
    fun test_simple_interest_half_year() {
        // 1_000_000 at 10% for 6 months
        // Expected: 50_000
        let result = math::simple_interest(1_000_000, 1000, math::seconds_per_year() / 2);
        assert!(result == 50_000, 0);
    }

    #[test]
    fun test_simple_interest_zero_principal() {
        let result = math::simple_interest(0, 500, math::seconds_per_year());
        assert!(result == 0, 0);
    }

    #[test]
    fun test_simple_interest_zero_rate() {
        let result = math::simple_interest(1_000_000, 0, math::seconds_per_year());
        assert!(result == 0, 0);
    }

    #[test]
    fun test_simple_interest_zero_time() {
        let result = math::simple_interest(1_000_000, 500, 0);
        assert!(result == 0, 0);
    }

    // ─── tokens_for_amount ────────────────────────────────────────────────────

    #[test]
    fun test_tokens_for_amount_exact() {
        // 1_000_000 stablecoin at 10 per token = 100_000 tokens
        let result = math::tokens_for_amount(1_000_000, 10);
        assert!(result == 100_000, 0);
    }

    #[test]
    fun test_tokens_for_amount_truncates() {
        // 105 stablecoin at 10 per token = 10 tokens (5 remainder truncated)
        let result = math::tokens_for_amount(105, 10);
        assert!(result == 10, 0);
    }

    #[test]
    fun test_tokens_for_amount_zero_price() {
        let result = math::tokens_for_amount(1_000, 0);
        assert!(result == 0, 0);
    }

    #[test]
    fun test_tokens_for_amount_zero_input() {
        let result = math::tokens_for_amount(0, 100);
        assert!(result == 0, 0);
    }

    // ─── saturating_sub ───────────────────────────────────────────────────────

    #[test]
    fun test_saturating_sub_normal() {
        assert!(math::saturating_sub(100, 40) == 60, 0);
    }

    #[test]
    fun test_saturating_sub_exact_zero() {
        assert!(math::saturating_sub(50, 50) == 0, 0);
    }

    #[test]
    fun test_saturating_sub_underflow_returns_zero() {
        // Would underflow in normal arithmetic — must return 0
        assert!(math::saturating_sub(10, 100) == 0, 0);
    }

    // ─── min_u64 ──────────────────────────────────────────────────────────────

    #[test]
    fun test_min_u64_first_smaller() {
        assert!(math::min_u64(3, 7) == 3, 0);
    }

    #[test]
    fun test_min_u64_second_smaller() {
        assert!(math::min_u64(9, 2) == 2, 0);
    }

    #[test]
    fun test_min_u64_equal() {
        assert!(math::min_u64(5, 5) == 5, 0);
    }

    // ─── apply_bps ────────────────────────────────────────────────────────────

    #[test]
    fun test_apply_bps_five_percent() {
        // 5% of 1_000_000 = 50_000
        assert!(math::apply_bps(1_000_000, 500) == 50_000, 0);
    }

    #[test]
    fun test_apply_bps_one_hundred_percent() {
        // 100% of 500 = 500
        assert!(math::apply_bps(500, 10_000) == 500, 0);
    }

    #[test]
    fun test_apply_bps_zero() {
        assert!(math::apply_bps(1_000_000, 0) == 0, 0);
    }
}
