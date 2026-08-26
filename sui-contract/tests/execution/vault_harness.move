/// 가드레일 테스트용 하네스.
///
/// 예전에는 `mock_dex`(가짜 Pool)와 `order_executor`(그 Pool을 쓰는 실행 경로)를 두고
/// 거기에 테스트를 걸었다. 그런데 실거래는 DeepBook 경로 하나뿐이라, 가짜 경로를 따로
/// 두면 둘이 갈라진다 — 실제로 거래 수수료를 DeepBook 경로에만 넣고 mock에는 빠뜨린
/// 일이 있었다. 그래서 가짜 DEX를 없애고 이 하네스로 대체했다.
///
/// 핵심은 **가드레일이 executor가 아니라 `investment_vault`의 원시 함수 안에 있다**는
/// 점이다. 권한·상태·위험도·한도·중복 Signal·시간·가격 편차·최소 수령량 검사가 전부
/// `take_*_for_execution` / `settle_*_execution`에 모여 있으므로, DEX 없이 이 둘을
/// 직접 호출하면 같은 검사를 그대로 통과시킬 수 있다.
///
/// 체결량은 예전 `mock_dex`의 고정 가격 계산을 그대로 옮겼다. 기존 테스트의
/// 기대값을 바꾸지 않기 위해서다.
#[test_only]
module agent_market::vault_harness {
    use agent_market::investment_vault::{Self, UserVault};
    use sui::balance;
    use sui::clock::{Self, Clock};

    const PRICE_SCALE: u128 = 1_000_000_000;

    /// executor들이 쓰는 것과 같은 코드다. 하네스도 같은 지점에서 끊어야
    /// 기한 만료 동작이 실거래 경로와 어긋나지 않는다.
    const E_DEADLINE_EXPIRED: u64 = 1;

    /// Vault 정책의 `allowed_pool`로 쓰는 고정 주소.
    /// 실제 Pool 객체가 없으므로 값 자체에 의미는 없고, 설정과 실행이 같기만 하면 된다.
    const POOL: address = @0x900D;

    public fun pool(): address { POOL }

    /// fiat 입력과 고정 가격으로 받을 crypto 수량. 구 `mock_dex::swap_buy`와 같은 식.
    public fun crypto_out(fiat_in: u64, price_e9: u64): u64 {
        (((fiat_in as u128) * PRICE_SCALE / (price_e9 as u128)) as u64)
    }

    /// crypto 입력과 고정 가격으로 받을 fiat 수량. 구 `mock_dex::swap_sell`과 같은 식.
    public fun fiat_out(crypto_in: u64, price_e9: u64): u64 {
        (((crypto_in as u128) * (price_e9 as u128) / PRICE_SCALE) as u64)
    }

    /// BUY 한 건. 꺼낸 fiat은 DEX로 나간 셈 치고 폐기하고, 체결된 crypto를 만들어 정산한다.
    public fun execute_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        quote_price_e9: u64,
        fiat_amount: u64,
        min_crypto_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        risk_score_bps: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        assert!(clock::timestamp_ms(clock) <= deadline_ms, E_DEADLINE_EXPIRED);

        let fiat_input = investment_vault::take_fiat_for_execution(
            vault,
            POOL,
            fiat_amount,
            &signal_id,
            signal_timestamp_ms,
            signal_price_e9,
            quote_price_e9,
            risk_score_bps,
            clock,
            ctx,
        );

        let output = crypto_out(balance::value(&fiat_input), quote_price_e9);
        balance::destroy_for_testing(fiat_input);

        let _ = investment_vault::settle_buy_execution(
            vault,
            balance::create_for_testing<CryptoT>(output),
            fiat_amount,
            min_crypto_output,
            signal_id,
        );
    }

    /// SELL 한 건. 매도분 원가와 실현 손실 계산을 위해 매도 전 포지션을 먼저 읽는다.
    public fun execute_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        quote_price_e9: u64,
        crypto_amount: u64,
        min_fiat_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        risk_score_bps: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        let position_before = investment_vault::crypto_balance(vault);
        let expected_fiat_output = fiat_out(crypto_amount, quote_price_e9);

        let crypto_input = investment_vault::take_crypto_for_execution(
            vault,
            POOL,
            crypto_amount,
            expected_fiat_output,
            &signal_id,
            signal_timestamp_ms,
            signal_price_e9,
            quote_price_e9,
            risk_score_bps,
            clock,
            ctx,
        );

        let output = fiat_out(balance::value(&crypto_input), quote_price_e9);
        balance::destroy_for_testing(crypto_input);

        let _ = investment_vault::settle_sell_execution(
            vault,
            balance::create_for_testing<FiatT>(output),
            crypto_amount,
            position_before,
            min_fiat_output,
            signal_id,
            now_ms,
        );
    }

    /// Owner 전용 긴급 전량 청산. Signal도 위험도도 받지 않고 거래 한도도 적용하지 않는다.
    /// `min_fiat_output`과 `deadline`은 유지한다 — 없으면 긴급 버튼이 샌드위치 경로가 된다.
    public fun emergency_liquidate_all<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        quote_price_e9: u64,
        min_fiat_output: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        let crypto_input =
            investment_vault::take_all_crypto_for_emergency(vault, POOL, ctx);
        let crypto_sold = balance::value(&crypto_input);
        let output = fiat_out(crypto_sold, quote_price_e9);
        balance::destroy_for_testing(crypto_input);

        investment_vault::settle_emergency_liquidation(
            vault,
            balance::create_for_testing<FiatT>(output),
            crypto_sold,
            min_fiat_output,
            POOL,
            now_ms,
        );
    }
}
