module agent_market::order_executor {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::mock_dex::{Self, MockPool};
    use sui::balance;
    use sui::clock::{Self, Clock};
    use sui::event;

    const PRICE_SCALE: u128 = 1_000_000_000;
    const E_DEADLINE_EXPIRED: u64 = 1;

    public struct OrderExecuted<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        user: address,
        signal_id: vector<u8>,
        side: u8,
        requested_input: u64,
        actual_output: u64,
        signal_price_e9: u64,
        dex_quote_price_e9: u64,
        /// 느린 시계가 산출해 이 주문에 적용한 위험도다. Indexer가 사후 감사에 사용한다.
        risk_score_bps: u64,
        pool: address,
        transaction_digest: vector<u8>,
        executed_at_ms: u64,
    }

    /// Vault에서 FiatT를 꺼내 Swap하고 결과 CryptoT를 같은 Vault에 돌려놓는다.
    /// 모든 과정이 성공한 뒤에만 한도 사용량과 Signal 실행 기록을 갱신한다.
    ///
    /// `risk_score_bps`는 느린 시계(Backtest·Shadow Trading)가 산출한 값을
    /// AgoraAgent가 그대로 전달하는 값이다. 빠른 시계인 이 함수는 값을 재계산하지 않고
    /// Vault가 소유자 정책으로 강제하는 상한과 비교만 한다.
    public fun execute_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut MockPool<FiatT, CryptoT>,
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
        // 제출 지연으로 오래된 주문이 체결되지 않도록 최종 실행 기한을 확인한다.
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);
        let pool_address = mock_dex::pool_address(pool);
        let quote_price_e9 = mock_dex::price_e9(pool);
        // Vault가 권한, 상태, 중복 Signal, 시간, 가격, 잔액과 한도를 검사한다.
        let fiat_input = investment_vault::take_fiat_for_execution(
            vault,
            pool_address,
            fiat_amount,
            &signal_id,
            signal_timestamp_ms,
            signal_price_e9,
            quote_price_e9,
            risk_score_bps,
            clock,
            ctx,
        );
        // Swap 결과는 Agent 지갑이 아니라 즉시 같은 Vault로 정산한다.
        let crypto_output = mock_dex::swap_buy(pool, fiat_input);
        let actual_output = investment_vault::settle_buy_execution(
            vault, crypto_output, fiat_amount, min_crypto_output, signal_id,
        );

        event::emit(OrderExecuted<FiatT, CryptoT> {
            vault_id: object::id(vault),
            user: investment_vault::owner(vault),
            signal_id,
            side: 0,
            requested_input: fiat_amount,
            actual_output,
            signal_price_e9,
            dex_quote_price_e9: quote_price_e9,
            risk_score_bps,
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            executed_at_ms: now_ms,
        });
    }

    /// Owner 전용 긴급 전량 청산. 보유 CryptoT를 시장가로 모두 팔아 FiatT로 바꾼다.
    ///
    /// Signal도 위험도도 받지 않는다. AgoraAgent의 판단이 아니라 Owner의 탈출이므로
    /// 거래 한도와 시간대, 가격 편차 검사를 적용하지 않는다. 자세한 근거는
    /// investment_vault의 take_all_crypto_for_emergency 주석에 있다.
    ///
    /// min_fiat_output과 deadline은 유지한다. 이 둘이 없으면 긴급 버튼 자체가
    /// 샌드위치 공격 경로가 된다.
    public fun emergency_liquidate_all<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut MockPool<FiatT, CryptoT>,
        min_fiat_output: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        let pool_address = mock_dex::pool_address(pool);
        let crypto_input =
            investment_vault::take_all_crypto_for_emergency(vault, pool_address, ctx);
        let crypto_sold = balance::value(&crypto_input);

        let fiat_output = mock_dex::swap_sell(pool, crypto_input);
        investment_vault::settle_emergency_liquidation(
            vault, fiat_output, crypto_sold, min_fiat_output, pool_address, now_ms,
        );
    }

    /// CryptoT를 원자적으로 매도하고 결과 FiatT를 같은 Vault에 정산한다.
    /// 포지션 축소를 위해 REDUCE_ONLY 상태에서도 SELL은 허용한다.
    ///
    /// SELL에는 위험도 상한을 적용하지 않는다. 위험이 커진 순간 탈출 경로가 막히면
    /// 안전장치가 오히려 손실을 키우기 때문이다. 값은 기록용으로만 전달한다.
    public fun execute_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut MockPool<FiatT, CryptoT>,
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
        let pool_address = mock_dex::pool_address(pool);
        let quote_price_e9 = mock_dex::price_e9(pool);
        // 매도 전 포지션을 기준으로 매도분의 원가와 실현 손실을 계산한다.
        let position_before = investment_vault::crypto_balance(vault);
        let expected_fiat_output =
            ((crypto_amount as u128) * (quote_price_e9 as u128) / PRICE_SCALE) as u64;
        let crypto_input = investment_vault::take_crypto_for_execution(
            vault,
            pool_address,
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
        let fiat_output = mock_dex::swap_sell(pool, crypto_input);
        let actual_output = investment_vault::settle_sell_execution(
            vault,
            fiat_output,
            crypto_amount,
            position_before,
            min_fiat_output,
            signal_id,
            now_ms,
        );

        event::emit(OrderExecuted<FiatT, CryptoT> {
            vault_id: object::id(vault),
            user: investment_vault::owner(vault),
            signal_id,
            side: 1,
            requested_input: crypto_amount,
            actual_output,
            signal_price_e9,
            dex_quote_price_e9: quote_price_e9,
            risk_score_bps,
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            executed_at_ms: now_ms,
        });
    }
}
