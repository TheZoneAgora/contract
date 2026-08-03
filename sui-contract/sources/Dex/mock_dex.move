module agent_market::mock_dex {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};

    const PRICE_SCALE: u128 = 1_000_000_000;
    const E_INVALID_PRICE: u64 = 1;
    const E_ZERO_OUTPUT: u64 = 2;
    const E_INSUFFICIENT_LIQUIDITY: u64 = 3;

    /// Vault 원자적 정산을 검증하기 위한 고정 가격 Mock Pool이다.
    /// 실제 자산을 다루는 운영 환경에는 배포하지 않는다.
    public struct MockPool<phantom FiatT, phantom CryptoT> has key {
        id: UID,
        fiat_reserve: Balance<FiatT>,
        crypto_reserve: Balance<CryptoT>,
        fiat_per_crypto_e9: u64,
    }

    public fun create_pool<FiatT, CryptoT>(
        fiat_liquidity: Coin<FiatT>,
        crypto_liquidity: Coin<CryptoT>,
        fiat_per_crypto_e9: u64,
        ctx: &mut TxContext,
    ) {
        assert!(fiat_per_crypto_e9 > 0, E_INVALID_PRICE);
        transfer::share_object(MockPool<FiatT, CryptoT> {
            id: object::new(ctx),
            fiat_reserve: coin::into_balance(fiat_liquidity),
            crypto_reserve: coin::into_balance(crypto_liquidity),
            fiat_per_crypto_e9,
        });
    }

    public(package) fun price_e9<FiatT, CryptoT>(
        pool: &MockPool<FiatT, CryptoT>,
    ): u64 {
        pool.fiat_per_crypto_e9
    }

    public(package) fun pool_address<FiatT, CryptoT>(
        pool: &MockPool<FiatT, CryptoT>,
    ): address {
        object::id_address(pool)
    }

    #[test_only]
    public fun set_price_for_testing<FiatT, CryptoT>(
        pool: &mut MockPool<FiatT, CryptoT>,
        fiat_per_crypto_e9: u64,
    ) {
        assert!(fiat_per_crypto_e9 > 0, E_INVALID_PRICE);
        pool.fiat_per_crypto_e9 = fiat_per_crypto_e9;
    }

    public(package) fun swap_buy<FiatT, CryptoT>(
        pool: &mut MockPool<FiatT, CryptoT>,
        fiat_in: Balance<FiatT>,
    ): Balance<CryptoT> {
        // 기준 자산 입력량과 고정 가격으로 받을 투자 자산 수량을 계산한다.
        let amount_in = balance::value(&fiat_in);
        let amount_out =
            ((amount_in as u128) * PRICE_SCALE / (pool.fiat_per_crypto_e9 as u128)) as u64;
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out <= balance::value(&pool.crypto_reserve), E_INSUFFICIENT_LIQUIDITY);
        // 입력 자산은 Pool에 합치고 출력 자산은 Pool 준비금에서 분리한다.
        balance::join(&mut pool.fiat_reserve, fiat_in);
        balance::split(&mut pool.crypto_reserve, amount_out)
    }

    public(package) fun swap_sell<FiatT, CryptoT>(
        pool: &mut MockPool<FiatT, CryptoT>,
        crypto_in: Balance<CryptoT>,
    ): Balance<FiatT> {
        // 투자 자산 입력량과 고정 가격으로 받을 기준 자산 수량을 계산한다.
        let amount_in = balance::value(&crypto_in);
        let amount_out =
            ((amount_in as u128) * (pool.fiat_per_crypto_e9 as u128) / PRICE_SCALE) as u64;
        assert!(amount_out > 0, E_ZERO_OUTPUT);
        assert!(amount_out <= balance::value(&pool.fiat_reserve), E_INSUFFICIENT_LIQUIDITY);
        balance::join(&mut pool.crypto_reserve, crypto_in);
        balance::split(&mut pool.fiat_reserve, amount_out)
    }
}
