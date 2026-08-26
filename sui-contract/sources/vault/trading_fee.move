/// Agora 거래 수수료 계산.
///
/// 왜 별도 모듈인가: DeepBook 경로는 Move 테스트에서 Pool 픽스처를 만들 수 없어
/// (§9 알려진 이슈) 실행 경로 전체를 유닛 테스트로 덮을 수 없다. 그래서 돈이 걸린
/// 산수만 순수 함수로 떼어 내 여기서 전부 검증하고, executor는 이 결과를 쓰기만 한다.
///
/// 수수료는 언제나 FiatT(USDC)로 걷는다. BUY는 투입 fiat에서, SELL은 수령 fiat에서
/// 떼므로 통화가 하나로 통일되고 회계가 단순해진다.
module agent_market::trading_fee {
    const BPS_DENOMINATOR: u64 = 10_000;

    /// 요율 상한. 이 모듈을 업그레이드하지 않는 한 이보다 높게 걷을 수 없다.
    /// 사용자가 서명 시점에 알 수 없는 비용이 나중에 커지는 것을 막는 안전장치다.
    const MAX_TRADING_FEE_BPS: u64 = 100; // 1%

    /// Agora가 거래 1건에 부과하는 요율.
    ///
    /// 원가는 DeepBook v3 taker 수수료다 — SUI/USDC 같은 메이저 페어가 5bps(0.05%)이고
    /// Agora가 DEEP으로 선지불한다. 그 위에 5bps 마진을 얹어 10bps로 잡았다.
    /// 비교: Uniswap v3 메이저 5bps / 일반 알트 30bps, PancakeSwap v3 메이저 5bps,
    /// Raydium Standard AMM 25bps. 유저 실부담 10bps는 이 범위 안쪽이다.
    ///
    /// ⚠️ 요율과 수령 주소를 상수로 둔 것은 의도적이다. 호출 인자로 받으면 AgoraAgent가
    ///    트랜잭션마다 바꿔 넣을 수 있고, Vault 필드로 두면 Owner가 0으로 만들 수 있다.
    ///    변경하려면 패키지 업그레이드가 필요하다 — 그게 감사 흔적이 남는 방식이다.
    ///    (나중에 요율을 자주 바꿔야 하면 AdminCap이 지키는 공유 FeeConfig로 옮긴다.)
    const TRADING_FEE_BPS: u64 = 10; // 0.1%

    const E_INVALID_FEE_RATE: u64 = 1;

    public fun trading_fee_bps(): u64 {
        // 상수를 잘못 고쳤을 때 배포가 아니라 첫 거래에서 터지는 것을 막는다.
        assert!(TRADING_FEE_BPS <= MAX_TRADING_FEE_BPS, E_INVALID_FEE_RATE);
        TRADING_FEE_BPS
    }

    public fun max_trading_fee_bps(): u64 {
        MAX_TRADING_FEE_BPS
    }

    /// 금액에서 수수료를 구한다. u64 overflow를 피하려 몫과 나머지를 나눠 곱한다
    /// (payment_splitter.move와 같은 방식).
    ///
    /// 내림이므로 아주 작은 금액에서는 0이 나온다. 그건 의도한 동작이다 —
    /// 반올림해서 1을 걷으면 먼지 거래에서 요율이 실질적으로 폭증한다.
    public fun fee_of(amount: u64): u64 {
        let bps = trading_fee_bps();
        let whole_units = amount / BPS_DENOMINATOR;
        let remainder = amount % BPS_DENOMINATOR;

        whole_units * bps + remainder * bps / BPS_DENOMINATOR
    }

    /// SELL에서 DeepBook에 넘길 최소 수령량을 구한다.
    ///
    /// 왜 필요한가: `min_fiat_output`은 "유저가 실제로 받을 최소 금액"이다. 그런데
    /// 수수료는 DeepBook이 뱉은 총액에서 뗀다. 총액 기준 그대로 DeepBook에 넘기면
    /// 총액은 통과했는데 순액이 미달인 체결이 생기고, 정산에서 E_MIN_OUTPUT_NOT_MET으로
    /// 전체가 되돌아간다. 그래서 수수료만큼 미리 올려 잡는다.
    ///
    /// net = gross - floor(gross * bps / 10000) >= min 을 만족하는 최소 gross를 구한다.
    /// 나눗셈 내림 때문에 정확한 역산이 안 되므로 올림으로 잡고 1을 더해 안전하게 간다.
    /// 과하게 잡아도 손해는 없다 — 체결이 더 보수적으로 걸릴 뿐 자금은 움직이지 않는다.
    public fun gross_min_output(net_min_output: u64): u64 {
        if (net_min_output == 0) return 0;

        let bps = trading_fee_bps();
        let numerator = (net_min_output as u128) * (BPS_DENOMINATOR as u128);
        let denominator = (BPS_DENOMINATOR - bps) as u128;
        // 올림 나눗셈
        let gross = (numerator + denominator - 1) / denominator;

        (gross as u64)
    }

    #[test_only]
    public fun bps_denominator(): u64 { BPS_DENOMINATOR }
}
