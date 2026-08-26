#[test_only]
module agent_market::trading_fee_tests {
    use agent_market::trading_fee;

    const BPS: u64 = 10_000;

    #[test]
    fun fee_rate_stays_within_the_hard_cap() {
        // 상수를 잘못 고쳐 사용자에게 과금이 튀는 것을 배포 전에 잡는다.
        assert!(trading_fee::trading_fee_bps() <= trading_fee::max_trading_fee_bps(), 0);
        assert!(trading_fee::max_trading_fee_bps() <= BPS, 1);
    }

    #[test]
    fun fee_is_the_configured_share_of_the_amount() {
        let bps = trading_fee::trading_fee_bps();

        // 1 USDC (6 decimals)
        assert!(trading_fee::fee_of(1_000_000) == 1_000_000 * bps / BPS, 0);
        // Testnet E2E에서 실제로 오간 규모
        assert!(trading_fee::fee_of(960_400) == 960_400 * bps / BPS, 1);
    }

    #[test]
    fun zero_amount_costs_nothing() {
        assert!(trading_fee::fee_of(0) == 0, 0);
    }

    #[test]
    fun dust_rounds_down_instead_of_up() {
        // 올림하면 먼지 거래에서 실효 요율이 폭증한다. 내림이라 0이 나와야 한다.
        assert!(trading_fee::fee_of(1) == 0, 0);
        assert!(trading_fee::fee_of(99) == 0, 1);
    }

    #[test]
    fun fee_never_exceeds_the_amount_it_is_taken_from() {
        // 이 성질이 깨지면 executor의 balance::split이 abort한다.
        let samples = vector[
            1u64, 99, 100, 1_000, 999_999, 1_000_000, 960_400,
            1_000_000_000, 18_446_744_073_709_551_615,
        ];
        let mut i = 0;

        while (i < vector::length(&samples)) {
            let amount = *vector::borrow(&samples, i);
            assert!(trading_fee::fee_of(amount) <= amount, i);
            i = i + 1;
        };
    }

    #[test]
    fun largest_u64_does_not_overflow() {
        // 몫과 나머지를 나눠 곱하는 이유가 이것이다. amount * bps는 u64를 넘긴다.
        let max_u64 = 18_446_744_073_709_551_615u64;
        let bps = trading_fee::trading_fee_bps();

        assert!(trading_fee::fee_of(max_u64) == max_u64 / BPS * bps
            + (max_u64 % BPS) * bps / BPS, 0);
    }

    #[test]
    fun reserved_fee_always_covers_what_is_charged() {
        // execute_buy는 fee_of(요청액)을 예약해 두고 fee_of(체결액)을 청구한다.
        // 체결액 <= 요청액 - 예약분 이므로 예약분이 모자라면 안 된다.
        let requested = 1_000_000u64;
        let reserved = trading_fee::fee_of(requested);
        let swap_budget = requested - reserved;

        // 전량 체결
        assert!(trading_fee::fee_of(swap_budget) <= reserved, 0);
        // 부분 체결 — 적게 쓸수록 청구액도 줄어야 한다
        assert!(trading_fee::fee_of(swap_budget / 2) <= reserved, 1);
        assert!(trading_fee::fee_of(swap_budget / 2) <= trading_fee::fee_of(swap_budget), 2);
        assert!(trading_fee::fee_of(1) <= reserved, 3);
    }

    #[test]
    fun grossed_up_minimum_survives_the_fee_deduction() {
        // 핵심 성질: gross_min_output(min)만큼 체결되면, 수수료를 뗀 뒤에도
        // 유저 수령액이 min 이상이어야 한다. 아니면 SELL이 정산에서 되돌아간다.
        let samples = vector[
            1u64, 100, 12_345, 952_000, 1_000_000, 1_000_000_000,
        ];
        let mut i = 0;

        while (i < vector::length(&samples)) {
            let net_min = *vector::borrow(&samples, i);
            let gross = trading_fee::gross_min_output(net_min);
            let net = gross - trading_fee::fee_of(gross);

            assert!(net >= net_min, i);
            i = i + 1;
        };
    }

    #[test]
    fun grossed_up_minimum_is_not_wastefully_large() {
        // 지나치게 올려 잡으면 정상 체결까지 거부된다. 요율 + 반올림 여유 수준이어야 한다.
        let net_min = 1_000_000u64;
        let gross = trading_fee::gross_min_output(net_min);

        assert!(gross >= net_min, 0);
        // 10bps 요율에서 1 USDC면 1,001,xxx 언저리다. 0.1% 넉넉히 잡아도 이 아래다.
        assert!(gross <= net_min + net_min / 100, 1);
    }

    #[test]
    fun zero_minimum_stays_zero() {
        // 최소 수령량을 안 걸었으면 올려 잡을 것도 없다.
        assert!(trading_fee::gross_min_output(0) == 0, 0);
    }
}
