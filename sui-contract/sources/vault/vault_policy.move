module agent_market::vault_policy {
    const BPS_DENOMINATOR: u128 = 10_000;
    const MINUTES_PER_DAY: u64 = 1_440;
    const MS_PER_MINUTE: u64 = 60_000;

    const E_INVALID_POLICY: u64 = 1;
    const E_SIGNAL_FROM_FUTURE: u64 = 2;
    const E_SIGNAL_EXPIRED: u64 = 3;
    const E_OUTSIDE_TRADING_HOURS: u64 = 4;
    const E_PRICE_DEVIATION_EXCEEDED: u64 = 5;

    public(package) fun validate_configuration(
        max_daily_fiat_volume: u64,
        max_position_size: u64,
        trading_start_minute_utc: u64,
        trading_end_minute_utc: u64,
        max_signal_delay_ms: u64,
        max_price_deviation_bps: u64,
    ) {
        assert!(max_daily_fiat_volume > 0, E_INVALID_POLICY);
        assert!(max_position_size > 0, E_INVALID_POLICY);
        assert!(trading_start_minute_utc < MINUTES_PER_DAY, E_INVALID_POLICY);
        assert!(trading_end_minute_utc <= MINUTES_PER_DAY, E_INVALID_POLICY);
        assert!(max_signal_delay_ms > 0, E_INVALID_POLICY);
        assert!(max_price_deviation_bps <= BPS_DENOMINATOR as u64, E_INVALID_POLICY);
    }

    public(package) fun assert_time_policy(
        now_ms: u64,
        signal_timestamp_ms: u64,
        max_signal_delay_ms: u64,
        trading_start_minute_utc: u64,
        trading_end_minute_utc: u64,
    ) {
        assert!(signal_timestamp_ms <= now_ms, E_SIGNAL_FROM_FUTURE);
        assert!(now_ms - signal_timestamp_ms <= max_signal_delay_ms, E_SIGNAL_EXPIRED);

        // 시작과 종료가 같으면 하루 24시간 거래를 허용한다.
        if (trading_start_minute_utc != trading_end_minute_utc) {
            let minute = (now_ms / MS_PER_MINUTE) % MINUTES_PER_DAY;
            let inside = if (trading_start_minute_utc < trading_end_minute_utc) {
                minute >= trading_start_minute_utc && minute < trading_end_minute_utc
            } else {
                minute >= trading_start_minute_utc || minute < trading_end_minute_utc
            };
            assert!(inside, E_OUTSIDE_TRADING_HOURS);
        };
    }

    public(package) fun assert_price_deviation(
        signal_price_e9: u64,
        quote_price_e9: u64,
        max_price_deviation_bps: u64,
    ) {
        assert!(signal_price_e9 > 0 && quote_price_e9 > 0, E_INVALID_POLICY);
        let high = if (signal_price_e9 >= quote_price_e9) {
            signal_price_e9
        } else {
            quote_price_e9
        };
        let low = if (signal_price_e9 >= quote_price_e9) {
            quote_price_e9
        } else {
            signal_price_e9
        };
        let deviation_bps =
            ((high - low) as u128) * BPS_DENOMINATOR / (signal_price_e9 as u128);
        assert!(deviation_bps <= max_price_deviation_bps as u128, E_PRICE_DEVIATION_EXCEEDED);
    }

    public(package) fun mul_div(a: u64, b: u64, denominator: u64): u64 {
        assert!(denominator > 0, E_INVALID_POLICY);
        (((a as u128) * (b as u128) / (denominator as u128)) as u64)
    }

    public(package) fun utc_day(timestamp_ms: u64): u64 {
        timestamp_ms / 86_400_000
    }
}
