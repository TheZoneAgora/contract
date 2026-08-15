// DeepBook v3 실행 경로.
//
// order_executor(Mock DEX)와 동일한 Vault 원시 함수를 호출한다. 권한·상태·위험도·
// 한도·중복 Signal·시간·가격 편차·최소 수령량 검사는 모두 investment_vault 안에
// 있으므로 거래 장소가 바뀌어도 안전장치는 그대로 적용된다.
//
// 타입 대응:
//   FiatT  (USDC) = DeepBook QuoteAsset
//   CryptoT (SUI) = DeepBook BaseAsset
//   BUY  = swap_exact_quote_for_base
//   SELL = swap_exact_base_for_quote
module agent_market::deepbook_executor {
    use agent_market::investment_vault::{Self, UserVault};
    use deepbook::pool::{Self, Pool};
    use token::deep::DEEP;
    use sui::balance;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;

    const PRICE_SCALE: u128 = 1_000_000_000;

    const E_DEADLINE_EXPIRED: u64 = 1;
    const E_EMPTY_QUOTE: u64 = 2;
    /// 주문 수량이 Pool의 min_size 미달이다. DeepBook은 이 경우 abort하지 않고
    /// 입력을 그대로 돌려주므로(no-op) 여기서 먼저 끊는다.
    const E_BELOW_MIN_SIZE: u64 = 3;
    /// 체결이 전혀 일어나지 않았다. Signal이 소진되는 것을 막기 위해 전체를 되돌린다.
    const E_SWAP_NOT_EXECUTED: u64 = 4;

    public struct DeepBookOrderExecuted<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        user: address,
        signal_id: vector<u8>,
        side: u8,
        requested_input: u64,
        /// 유동성 부족으로 실제 체결에 쓰인 입력량. requested_input보다 작을 수 있다.
        consumed_input: u64,
        actual_output: u64,
        signal_price_e9: u64,
        dex_quote_price_e9: u64,
        pool: address,
        transaction_digest: vector<u8>,
        risk_score_bps: u64,
        executed_at_ms: u64,
    }

    /// DEEP 수수료는 Agora 운영 예산이 부담한다. Vault 자산을 수수료로 쓰지 않는다는
    /// RFC 자금 원칙에 따라 AgoraAgent가 Coin<DEEP>을 트랜잭션 인자로 넣고,
    /// 쓰고 남은 DEEP은 다시 AgoraAgent에게 돌려준다.
    /// Whitelisted Pool이면 잔액 0인 Coin<DEEP>을 넣으면 된다.
    public fun execute_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut Pool<CryptoT, FiatT>,
        deep_fee: Coin<DEEP>,
        fiat_amount: u64,
        min_crypto_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        risk_score_bps: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        // 중간가 대신 이번 수량의 실제 체결 예상량으로 유효 가격을 구한다.
        // Order Book에서는 수량이 커질수록 체결가가 나빠지므로 이 쪽이 정확하다.
        //
        // 조회 함수는 실제 체결이 쓸 수수료 모드와 반드시 일치해야 한다. DeepBook은
        // `deep_in.value() > 0`으로 모드를 정하므로 여기서도 같은 기준으로 나눈다.
        // 어긋나면 추정 체결량이 낙관적으로 나와 가격 편차 가드가 헐거워진다.
        let pay_with_deep = coin::value(&deep_fee) > 0;
        let (base_out, _quote_out, _deep_required) = if (pay_with_deep) {
            pool::get_base_quantity_out(pool, fiat_amount, clock)
        } else {
            pool::get_base_quantity_out_input_fee(pool, fiat_amount, clock)
        };
        assert!(base_out > 0, E_EMPTY_QUOTE);
        let quote_price_e9 =
            (((fiat_amount as u128) * PRICE_SCALE / (base_out as u128)) as u64);

        // DeepBook은 base 수량을 lot_size로 내림한 뒤 min_size와 비교하고, 미달이면
        // 입력을 그대로 반환한다. Vault 자금을 건드리기 전에 끊는다.
        let (_tick_size, lot_size, min_size) = pool::pool_book_params(pool);
        assert!(base_out - base_out % lot_size >= min_size, E_BELOW_MIN_SIZE);

        let pool_address = object::id_address(pool);
        // Vault가 권한, 상태, 위험도, 중복 Signal, 시간, 가격, 잔액과 한도를 검사한다.
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

        let (crypto_coin, fiat_remainder, deep_remainder) =
            pool::swap_exact_quote_for_base(
                pool,
                coin::from_balance(fiat_input, ctx),
                deep_fee,
                min_crypto_output,
                clock,
                ctx,
            );

        // 체결에 쓰이지 않은 fiat은 실행자가 아니라 반드시 같은 Vault로 돌아간다.
        let consumed_input = fiat_amount - coin::value(&fiat_remainder);
        // 사전 검사를 통과했더라도 유동성이 빠지는 등으로 no-op이 날 수 있다. 이때
        // 그냥 정산하면 체결 없이 signal_id가 replay 테이블에 박혀 영구 소진된다.
        // 전체를 abort시켜 signal을 살려 둔다.
        assert!(consumed_input > 0, E_SWAP_NOT_EXECUTED);
        investment_vault::return_fiat_remainder(
            vault, coin::into_balance(fiat_remainder),
        );
        // 남은 DEEP은 Vault 자산이 아니라 Agora 운영 자금이다.
        transfer::public_transfer(deep_remainder, tx_context::sender(ctx));

        let actual_output = investment_vault::settle_buy_execution(
            vault,
            coin::into_balance(crypto_coin),
            consumed_input,
            min_crypto_output,
            signal_id,
        );

        event::emit(DeepBookOrderExecuted<FiatT, CryptoT> {
            vault_id: object::id(vault),
            user: investment_vault::owner(vault),
            signal_id,
            side: 0,
            requested_input: fiat_amount,
            consumed_input,
            actual_output,
            signal_price_e9,
            dex_quote_price_e9: quote_price_e9,
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            risk_score_bps,
            executed_at_ms: now_ms,
        });
    }

    /// Owner 전용 긴급 전량 청산. 보유 CryptoT를 DeepBook 시장가로 모두 팔아
    /// FiatT로 바꾸고 Vault를 정지시킨다.
    ///
    /// 부분 체결이 나면 팔리지 않은 CryptoT는 같은 Vault로 돌아간다. 이때 회계는
    /// 이미 정리됐으므로 남은 물량을 다시 빼려면 한 번 더 호출하거나
    /// withdraw_crypto_amount로 코인 그대로 받는다.
    public fun emergency_liquidate_all<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut Pool<CryptoT, FiatT>,
        deep_fee: Coin<DEEP>,
        min_fiat_output: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        let pool_address = object::id_address(pool);
        let crypto_input =
            investment_vault::take_all_crypto_for_emergency(vault, pool_address, ctx);
        let position = balance::value(&crypto_input);

        let (crypto_remainder, fiat_coin, deep_remainder) =
            pool::swap_exact_base_for_quote(
                pool,
                coin::from_balance(crypto_input, ctx),
                deep_fee,
                min_fiat_output,
                clock,
                ctx,
            );

        let crypto_sold = position - coin::value(&crypto_remainder);
        // 한 주도 안 팔렸는데 정산하면 cost_basis가 0으로 지워지고 Vault가 정지된다.
        // 포지션이 min_size 미달이라 시장가 매도가 불가능한 경우이므로, 회계를 망가뜨리는
        // 대신 abort시킨다. 이때 Owner는 withdraw_crypto_amount로 코인째 회수한다.
        assert!(crypto_sold > 0, E_SWAP_NOT_EXECUTED);
        investment_vault::return_crypto_remainder(
            vault, coin::into_balance(crypto_remainder),
        );
        transfer::public_transfer(deep_remainder, tx_context::sender(ctx));

        investment_vault::settle_emergency_liquidation(
            vault,
            coin::into_balance(fiat_coin),
            crypto_sold,
            min_fiat_output,
            pool_address,
            now_ms,
        );
    }

    /// SELL에는 위험도 상한을 적용하지 않는다. 근거는 investment_vault의
    /// assert_buy_risk_score_allowed 주석을 참고한다.
    public fun execute_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        pool: &mut Pool<CryptoT, FiatT>,
        deep_fee: Coin<DEEP>,
        crypto_amount: u64,
        min_fiat_output: u64,
        signal_id: vector<u8>,
        signal_timestamp_ms: u64,
        signal_price_e9: u64,
        risk_score_bps: u64,
        deadline_ms: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let now_ms = clock::timestamp_ms(clock);
        assert!(now_ms <= deadline_ms, E_DEADLINE_EXPIRED);

        // BUY와 같은 이유로 실제 체결의 수수료 모드에 맞춰 조회한다.
        let pay_with_deep = coin::value(&deep_fee) > 0;
        let (_base_out, quote_out, _deep_required) = if (pay_with_deep) {
            pool::get_quote_quantity_out(pool, crypto_amount, clock)
        } else {
            pool::get_quote_quantity_out_input_fee(pool, crypto_amount, clock)
        };
        assert!(quote_out > 0, E_EMPTY_QUOTE);
        let quote_price_e9 =
            (((quote_out as u128) * PRICE_SCALE / (crypto_amount as u128)) as u64);

        // 필요 조건만 본다. DEEP을 쓰지 않으면 DeepBook이 수수료만큼 매도 수량을 더
        // 줄인 뒤 min_size를 보므로, 이 검사를 통과해도 no-op이 날 수 있다.
        // 최종 판정은 아래 consumed_input 검사가 한다.
        let (_tick_size, lot_size, min_size) = pool::pool_book_params(pool);
        assert!(crypto_amount - crypto_amount % lot_size >= min_size, E_BELOW_MIN_SIZE);

        let pool_address = object::id_address(pool);
        // 매도 전 포지션을 기준으로 매도분의 원가와 실현 손실을 계산한다.
        let position_before = investment_vault::crypto_balance(vault);
        let crypto_input = investment_vault::take_crypto_for_execution(
            vault,
            pool_address,
            crypto_amount,
            quote_out,
            &signal_id,
            signal_timestamp_ms,
            signal_price_e9,
            quote_price_e9,
            risk_score_bps,
            clock,
            ctx,
        );

        let (crypto_remainder, fiat_coin, deep_remainder) =
            pool::swap_exact_base_for_quote(
                pool,
                coin::from_balance(crypto_input, ctx),
                deep_fee,
                min_fiat_output,
                clock,
                ctx,
            );

        let consumed_input = crypto_amount - coin::value(&crypto_remainder);
        // BUY와 같은 이유. 체결 0건이면 signal을 소진시키지 않고 전체를 되돌린다.
        assert!(consumed_input > 0, E_SWAP_NOT_EXECUTED);
        investment_vault::return_crypto_remainder(
            vault, coin::into_balance(crypto_remainder),
        );
        transfer::public_transfer(deep_remainder, tx_context::sender(ctx));

        let actual_output = investment_vault::settle_sell_execution(
            vault,
            coin::into_balance(fiat_coin),
            consumed_input,
            position_before,
            min_fiat_output,
            signal_id,
            now_ms,
        );

        event::emit(DeepBookOrderExecuted<FiatT, CryptoT> {
            vault_id: object::id(vault),
            user: investment_vault::owner(vault),
            signal_id,
            side: 1,
            requested_input: crypto_amount,
            consumed_input,
            actual_output,
            signal_price_e9,
            dex_quote_price_e9: quote_price_e9,
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            risk_score_bps,
            executed_at_ms: now_ms,
        });
    }
}
