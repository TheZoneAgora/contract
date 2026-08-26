// DeepBook v3 실행 경로.
//
// 유일한 실행 경로다. 권한·상태·위험도·한도·중복 Signal·시간·가격 편차·최소 수령량
// 검사는 모두 investment_vault의 take_*_for_execution / settle_*_execution 안에 있고,
// 이 모듈은 그 원시 함수들 사이에 DeepBook 스왑을 끼워 넣기만 한다.
// 테스트도 같은 원시 함수를 직접 호출한다(tests/execution/vault_harness.move).
//
// 타입 대응:
//   FiatT  (USDC) = DeepBook QuoteAsset
//   CryptoT (SUI) = DeepBook BaseAsset
//   BUY  = swap_exact_quote_for_base
//   SELL = swap_exact_base_for_quote
module agent_market::deepbook_executor {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::trading_fee;
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
    /// 수수료가 있는 Pool인데 AgoraAgent가 DEEP 없이 주문을 넣었다.
    /// 상세 근거는 assert_deep_fee_funded 주석을 참고한다.
    const E_DEEP_FEE_REQUIRED: u64 = 5;
    /// 수수료가 0인 whitelisted Pool에 DEEP을 넣었다.
    /// 상세 근거는 assert_deep_fee_not_wasted 주석을 참고한다.
    const E_DEEP_FEE_NOT_ACCEPTED: u64 = 6;

    /// whitelisted Pool에 DEEP을 넣지 못하게 막는다.
    ///
    /// 이 Pool들은 taker_fee가 0이라 DEEP이 필요 없다. 그런데 넣으면 DeepBook이
    /// **돌려주지 않고 전액 가져간다.** testnet DEEP_SUI에서 0.2 / 1.0 / 5.0 DEEP을
    /// 각각 넣어보면 크기와 무관하게 전부 소모된다(실거래로도 확인).
    ///
    /// AgoraAgent가 지갑의 DEEP 코인을 통째로 넘기는 구현이면 첫 거래에 운영 잔고가
    /// 통째로 날아간다. 비-whitelisted Pool에서는 실제 수수료분(~0.02 DEEP)만
    /// 소모되기 때문에 평소에는 드러나지 않는 종류의 사고다.
    /// 조용한 손실로 두느니 명시적으로 끊는다.
    fun assert_deep_fee_not_wasted<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        deep_fee: &Coin<DEEP>,
    ) {
        assert!(
            !pool::whitelisted(pool) || coin::value(deep_fee) == 0,
            E_DEEP_FEE_NOT_ACCEPTED,
        );
    }

    /// DEEP 수수료는 Agora 운영 예산이 부담한다는 RFC 자금 원칙을 실행 경로에서 강제한다.
    ///
    /// DeepBook은 `deep_in.value() > 0`으로 수수료 모드를 정한다. 0이면 input-token
    /// 수수료 모드로 넘어가는데, 이 모드의 수수료는 **Vault가 넣은 입력 코인에서** 차감된다.
    /// 즉 사용자 자금이 거래 수수료를 내게 된다. 게다가 요율은 taker_fee에
    /// fee_penalty_multiplier(1.25배)를 곱한 값이라 DEEP으로 낼 때보다 비싸다.
    /// 둘 중 어느 쪽도 AgoraAgent가 인자 하나로 선택할 수 있어서는 안 된다.
    ///
    /// 부수 효과로 진단도 쉬워진다. Pool마다 input-fee 모드 허용 여부가 달라
    /// (`SUI_DBUSDC`는 막혀 있고 `DEEP_SUI`는 열려 있다) 지금은 DeepBook 내부에서
    /// 모듈을 알 수 없는 code 8이 나온다. 여기서 먼저 끊으면 우리 코드가 뜬다.
    ///
    /// taker_fee가 0이라 DEEP이 아예 필요 없는 whitelisted Pool은 예외다.
    ///
    /// emergency_liquidate_all에는 이 함수를 걸지 않는다. 그쪽은 Owner의 탈출 경로이고,
    /// 사용자 지갑에 운영 자산인 DEEP이 있을 이유가 없다. DEEP 유무로 탈출을 막는 대신
    /// 자기 자금에서 수수료가 나가는 것을 허용한다.
    /// 다만 assert_deep_fee_not_wasted는 거기서도 건다 — 잔액 0인 Coin<DEEP>은 언제든
    /// 만들 수 있어 탈출을 막지 않으면서, 실수로 인한 DEEP 전액 손실만 걸러내기 때문이다.
    fun assert_deep_fee_funded<BaseAsset, QuoteAsset>(
        pool: &Pool<BaseAsset, QuoteAsset>,
        deep_fee: &Coin<DEEP>,
    ) {
        // 수수료 없는 Pool에 DEEP을 넣는 것도 막는다. 두 검사를 합치면
        // "필요한 만큼만, 필요한 곳에만"이 된다.
        assert_deep_fee_not_wasted(pool, deep_fee);
        assert!(
            pool::whitelisted(pool) || coin::value(deep_fee) > 0,
            E_DEEP_FEE_REQUIRED,
        );
    }

    public struct DeepBookOrderExecuted<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        user: address,
        signal_id: vector<u8>,
        side: u8,
        requested_input: u64,
        /// 유동성 부족으로 실제 체결에 쓰인 입력량. requested_input보다 작을 수 있다.
        consumed_input: u64,
        actual_output: u64,
        /// 이 거래가 실제로 태운 DEEP 수량. Agora 운영 예산이 부담한 실비다.
        /// 남은 DEEP은 실행자에게 돌아가므로 투입량이 아니라 차액을 기록해야 한다.
        /// 이게 없으면 거래당 수수료 원가를 온체인에서 집계할 수 없고,
        /// "이 거래의 수수료를 Agora가 냈다"는 증빙도 남지 않는다.
        deep_consumed: u64,
        /// DEEP 수수료 모드로 체결했는지. false면 input-token 모드이며
        /// 이때 수수료는 Vault 입력에서 나간다 (whitelisted Pool에서만 가능하다).
        paid_with_deep: bool,
        /// 이 거래에서 Agora가 유저에게 청구한 수수료 (FiatT 단위).
        /// BUY는 투입액에서, SELL은 매도 대금에서 뗀다.
        fee_charged: u64,
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
    /// DEEP 수량 규칙: whitelisted Pool은 반드시 0, 그 외 Pool은 반드시 0보다 커야 한다
    /// (assert_deep_fee_funded). 필요한 만큼만 split해서 넘긴다 — 통째로 넘기면 안 된다.
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
        assert_deep_fee_funded(pool, &deep_fee);

        // 중간가 대신 이번 수량의 실제 체결 예상량으로 유효 가격을 구한다.
        // Order Book에서는 수량이 커질수록 체결가가 나빠지므로 이 쪽이 정확하다.
        //
        // 조회 함수는 실제 체결이 쓸 수수료 모드와 반드시 일치해야 한다. DeepBook은
        // `deep_in.value() > 0`으로 모드를 정하므로 여기서도 같은 기준으로 나눈다.
        // 어긋나면 추정 체결량이 낙관적으로 나와 가격 편차 가드가 헐거워진다.
        // deep_fee는 아래 스왑으로 소유권이 넘어가므로 투입량을 미리 붙잡아 둔다.
        let deep_input = coin::value(&deep_fee);
        let pay_with_deep = deep_input > 0;
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
        let mut fiat_input = investment_vault::take_fiat_for_execution(
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

        // Agora 거래 수수료를 스왑 전에 떼어 둔다. 요청액 전부에 대해 잡아 두고,
        // 부분 체결이면 아래에서 실제 체결분만 청구하고 나머지는 Vault로 돌려준다.
        // 한도 검사는 이미 fiat_amount(총 지출) 기준으로 끝났으므로 추가 검사는 없다.
        let mut fee_reserve =
            balance::split(&mut fiat_input, trading_fee::fee_of(fiat_amount));
        let swap_budget = balance::value(&fiat_input);

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
        let swap_consumed = swap_budget - coin::value(&fiat_remainder);
        // 사전 검사를 통과했더라도 유동성이 빠지는 등으로 no-op이 날 수 있다. 이때
        // 그냥 정산하면 체결 없이 signal_id가 replay 테이블에 박혀 영구 소진된다.
        // 전체를 abort시켜 signal을 살려 둔다.
        assert!(swap_consumed > 0, E_SWAP_NOT_EXECUTED);

        // 실제 체결분에만 요율을 적용한다. swap_consumed < fiat_amount이므로
        // 여기서 구한 수수료는 예약분보다 항상 작거나 같다.
        let fee_charged = trading_fee::fee_of(swap_consumed);
        let fee_balance = balance::split(&mut fee_reserve, fee_charged);
        // 수수료는 DEEP 잔여분과 같은 곳 — 실행자인 AgoraAgent 운영 지갑 — 으로 보낸다.
        // Treasury 주소를 상수로 박거나 인자로 받지 않는 이유: 사용자가 보호받아야 하는
        // 것은 "얼마를 떼는가"(요율)이고 그건 trading_fee 상수가 고정한다. "어디로 가는가"는
        // Agora 내부 문제이고 호출자가 Agora 자신이므로, 잘못 지정해도 손해는 Agora가 본다.
        transfer::public_transfer(
            coin::from_balance(fee_balance, ctx), tx_context::sender(ctx),
        );

        // 쓰지 않은 예약분과 체결되지 않은 입력은 모두 Vault로 되돌린다.
        investment_vault::return_fiat_remainder(vault, fee_reserve);
        investment_vault::return_fiat_remainder(
            vault, coin::into_balance(fiat_remainder),
        );

        // 취득 원가에는 수수료도 포함된다. 유저가 이 포지션을 위해 실제로 낸 총액이다.
        let consumed_input = swap_consumed + fee_charged;
        // 남은 DEEP은 Vault 자산이 아니라 Agora 운영 자금이다.
        let deep_consumed = deep_input - coin::value(&deep_remainder);
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
            deep_consumed,
            paid_with_deep: pay_with_deep,
            fee_charged,
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
        // 낭비만 막고 "DEEP 필수"는 걸지 않는다. 0인 Coin<DEEP>은 언제든 만들 수 있으므로
        // 이 검사는 탈출을 막지 않지만, DEEP 필수를 걸면 DEEP 없는 Owner가 갇힌다.
        assert_deep_fee_not_wasted(pool, &deep_fee);

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
        assert_deep_fee_funded(pool, &deep_fee);

        // BUY와 같은 이유로 실제 체결의 수수료 모드에 맞춰 조회하고,
        // 투입 DEEP 수량도 스왑 전에 붙잡아 둔다.
        let deep_input = coin::value(&deep_fee);
        let pay_with_deep = deep_input > 0;
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

        // min_fiat_output은 "유저가 손에 쥐는 최소 금액"이다. 수수료는 DeepBook이 뱉은
        // 총액에서 떼므로, 그대로 넘기면 총액은 통과하고 순액이 미달인 체결이 생겨
        // 정산에서 E_MIN_OUTPUT_NOT_MET으로 전체가 되돌아간다. 수수료만큼 올려 잡는다.
        let (crypto_remainder, mut fiat_coin, deep_remainder) =
            pool::swap_exact_base_for_quote(
                pool,
                coin::from_balance(crypto_input, ctx),
                deep_fee,
                trading_fee::gross_min_output(min_fiat_output),
                clock,
                ctx,
            );

        let consumed_input = crypto_amount - coin::value(&crypto_remainder);
        // BUY와 같은 이유. 체결 0건이면 signal을 소진시키지 않고 전체를 되돌린다.
        assert!(consumed_input > 0, E_SWAP_NOT_EXECUTED);
        investment_vault::return_crypto_remainder(
            vault, coin::into_balance(crypto_remainder),
        );
        let deep_consumed = deep_input - coin::value(&deep_remainder);
        transfer::public_transfer(deep_remainder, tx_context::sender(ctx));

        // 수수료는 매도 대금에서 뗀다. Vault에 들어가는 것은 순액이므로
        // 실현 손익도 유저가 실제로 받은 금액 기준으로 계산된다.
        let fee_charged = trading_fee::fee_of(coin::value(&fiat_coin));
        let fee_coin = coin::split(&mut fiat_coin, fee_charged, ctx);
        transfer::public_transfer(fee_coin, tx_context::sender(ctx));

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
            deep_consumed,
            paid_with_deep: pay_with_deep,
            fee_charged,
            signal_price_e9,
            dex_quote_price_e9: quote_price_e9,
            pool: pool_address,
            transaction_digest: *tx_context::digest(ctx),
            risk_score_bps,
            executed_at_ms: now_ms,
        });
    }
}
