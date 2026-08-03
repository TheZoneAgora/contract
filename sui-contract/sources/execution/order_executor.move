module agent_market::order_executor {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::mock_dex::{Self, MockPool};
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
        pool: address,
        transaction_digest: vector<u8>,
        executed_at_ms: u64,
    }

    /// Vault에서 FiatT를 꺼내 Swap하고 결과 CryptoT를 같은 Vault에 돌려놓는다.
    /// 모든 과정이 성공한 뒤에만 한도 사용량과 Signal 실행 기록을 갱신한다.
    public fun execute_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut MockPool<FiatT, CryptoT>,
        fiat_amount: u64,
        min_crypto_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
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
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            executed_at_ms: now_ms,
        });
    }

    /// CryptoT를 원자적으로 매도하고 결과 FiatT를 같은 Vault에 정산한다.
    /// 포지션 축소를 위해 REDUCE_ONLY 상태에서도 SELL은 허용한다.
    public fun execute_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut MockPool<FiatT, CryptoT>,
        crypto_amount: u64,
        min_fiat_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
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
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            executed_at_ms: now_ms,
        });
    }
}
