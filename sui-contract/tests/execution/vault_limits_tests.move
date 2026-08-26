// Vault 권한과 한도를 실행 경로의 원시 함수(take_*/settle_*)로 직접 검증한다.
//
// 구 request_buy/request_sell 경로는 거래 없이 한도만 소진시키는 설계였고
// agora_invest 폐기와 함께 제거했다. 여기 테스트는 같은 불변식을
// 자산이 실제로 움직이는 경로에서 다시 확인한다.
#[test_only]
module agent_market::vault_limits_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::vault_harness;
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};

    public struct TestCrypto has drop {}

    const OWNER: address = @0xA11CE;
    const AGENT: address = @0xA6E17;
    const NEW_AGENT: address = @0xB0B;
    const ATTACKER: address = @0xBAD;

    const INITIAL_BALANCE: u64 = 1_000;
    const TRADE_LIMIT: u64 = 300;
    const EPOCH_LIMIT: u64 = 500;
    const CRYPTO_SELL_LIMIT: u64 = 200;
    const EPOCH_CRYPTO_SELL_LIMIT: u64 = 400;

    const NOW_MS: u64 = 1_000_000;
    /// 1 CryptoT = 1 FiatT. 금액과 수량을 같은 수로 다룰 수 있어 한도 검증이 단순해진다.
    const PRICE_E9: u64 = 1_000_000_000;
    const SAFE_RISK_BPS: u64 = 1_000;

    const E_NOT_AGENT: u64 = 2;
    const E_AGENT_INACTIVE: u64 = 3;
    const E_TRADE_LIMIT_EXCEEDED: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_EPOCH_TRADE_LIMIT_EXCEEDED: u64 = 6;
    const E_EPOCH_LIMIT_BELOW_SPENT: u64 = 7;
    const E_BUY_DISABLED_IN_REDUCE_ONLY: u64 = 14;

    /// 검증하려는 한도만 걸리도록 실행 정책은 넉넉하게 열어 둔다.
    fun setup_with(
        deposit_amount: u64,
        max_trade: u64,
        max_epoch_trade: u64,
    ): Scenario {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(deposit_amount, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit, AGENT, max_trade, max_epoch_trade,
            CRYPTO_SELL_LIMIT, EPOCH_CRYPTO_SELL_LIMIT, scenario.ctx(),
        );

        let mut clock = clock::create_for_testing(scenario.ctx());
        clock::set_for_testing(&mut clock, NOW_MS);
        clock::share_for_testing(clock);

        scenario.next_tx(OWNER);

        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::configure_execution_policy(
            &mut vault,
            vault_harness::pool(),
            1_000_000, // max_daily_fiat_volume
            1_000_000, // max_position_size
            1_000_000, // max_loss_amount
            0,         // trading_start_minute_utc
            0,         // trading_end_minute_utc
            600_000,   // max_signal_delay_ms
            500,       // max_price_deviation_bps
            10_000,    // max_risk_score_bps
            3_600_000, // loss_window_ms
            1_000_000, // max_window_loss_amount
            scenario.ctx(),
        );
        test_scenario::return_shared(vault);
        scenario
    }

    fun setup(): Scenario {
        setup_with(INITIAL_BALANCE, TRADE_LIMIT, EPOCH_LIMIT)
    }

    fun deposit_crypto(scenario: &mut Scenario, amount: u64) {
        scenario.next_tx(OWNER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let crypto = coin::mint_for_testing<TestCrypto>(amount, scenario.ctx());
        investment_vault::deposit_crypto_for_testing(&mut vault, crypto, scenario.ctx());
        test_scenario::return_shared(vault);
    }

    /// 가격이 1:1이므로 min_output을 입력량과 같게 두어 슬리피지 검사는 항상 통과시킨다.
    fun buy_as(scenario: &mut Scenario, sender: address, amount: u64, signal_id: vector<u8>) {
        scenario.next_tx(sender);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, amount, amount, signal_id,
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
    }

    fun sell_as(scenario: &mut Scenario, sender: address, amount: u64, signal_id: vector<u8>) {
        scenario.next_tx(sender);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_sell(
            &mut vault, PRICE_E9, amount, amount, signal_id,
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
    }

    // 자산 이동과 한도 분리 ------------------------------------------------

    #[test]
    fun buy_uses_fiat_and_sell_uses_crypto_with_separate_limits() {
        let mut scenario = setup();
        deposit_crypto(&mut scenario, 250);

        buy_as(&mut scenario, AGENT, 300, b"buy-300");
        // BUY는 fiat만 소모하고 결과 crypto는 같은 Vault로 들어온다.
        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::fiat_balance(&vault) == 700);
            assert!(investment_vault::crypto_balance(&vault) == 550);
            test_scenario::return_shared(vault);
        };

        sell_as(&mut scenario, AGENT, 200, b"sell-200");
        // SELL은 crypto 한도를 쓰고 fiat을 되돌려준다. 두 한도는 서로 독립이다.
        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::fiat_balance(&vault) == 900);
            assert!(investment_vault::crypto_balance(&vault) == 350);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = E_INSUFFICIENT_BALANCE, location = investment_vault)]
    fun sell_cannot_use_fiat_when_crypto_balance_is_insufficient() {
        let mut scenario = setup();
        // fiat이 1000 있어도 crypto가 0이면 SELL은 실패해야 한다.
        sell_as(&mut scenario, AGENT, 1, b"sell-without-position");
        scenario.end();
    }

    #[test]
    fun new_epoch_resets_cumulative_trade_allowance() {
        let mut scenario = setup();
        buy_as(&mut scenario, AGENT, TRADE_LIMIT, b"epoch-1");

        // epoch가 바뀌면 누적 사용량이 초기화되어 같은 금액을 다시 쓸 수 있다.
        scenario.next_epoch(AGENT);
        buy_as(&mut scenario, AGENT, TRADE_LIMIT, b"epoch-2");

        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::crypto_balance(&vault) == 600);
            test_scenario::return_shared(vault);
        };
        scenario.end();
    }

    // 권한 -----------------------------------------------------------------

    #[test]
    fun replacement_agent_can_trade_after_owner_replaces_agent() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::replace_agent(&mut vault, NEW_AGENT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        buy_as(&mut scenario, NEW_AGENT, 100, b"new-agent-buy");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_AGENT, location = investment_vault)]
    fun replaced_agent_loses_trade_authority() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::replace_agent(&mut vault, NEW_AGENT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        buy_as(&mut scenario, AGENT, 1, b"old-agent-buy");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_AGENT, location = investment_vault)]
    fun unregistered_address_cannot_execute_trade() {
        let mut scenario = setup();
        buy_as(&mut scenario, ATTACKER, 1, b"attacker-buy");
        scenario.end();
    }

    // 상태 -----------------------------------------------------------------

    #[test]
    fun owner_can_revoke_and_reactivate_agent() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::revoke_agent(&mut vault, scenario.ctx());
            assert!(investment_vault::is_paused(&vault));
            investment_vault::reactivate_agent(&mut vault, scenario.ctx());
            assert!(investment_vault::is_agora_agent_active(&vault));
            test_scenario::return_shared(vault);
        };

        buy_as(&mut scenario, AGENT, 100, b"after-reactivate");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_AGENT_INACTIVE, location = investment_vault)]
    fun revoked_agent_cannot_execute_trade() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::revoke_agent(&mut vault, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        buy_as(&mut scenario, AGENT, 1, b"revoked-buy");
        scenario.end();
    }

    #[test]
    fun reduce_only_blocks_new_buy_but_allows_position_reduction() {
        let mut scenario = setup();
        deposit_crypto(&mut scenario, 100);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::set_reduce_only(&mut vault, scenario.ctx());
            assert!(investment_vault::is_reduce_only(&vault));
            assert!(!investment_vault::is_agora_agent_active(&vault));
            test_scenario::return_shared(vault);
        };

        // 포지션 축소는 REDUCE_ONLY에서도 가능해야 한다.
        sell_as(&mut scenario, AGENT, 100, b"reduce-only-sell");

        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::crypto_balance(&vault) == 0);
            test_scenario::return_shared(vault);
        };
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_BUY_DISABLED_IN_REDUCE_ONLY, location = investment_vault)]
    fun reduce_only_rejects_new_buy() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::set_reduce_only(&mut vault, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        buy_as(&mut scenario, AGENT, 1, b"reduce-only-buy");
        scenario.end();
    }

    // 한도 -----------------------------------------------------------------

    #[test, expected_failure(abort_code = E_TRADE_LIMIT_EXCEEDED, location = investment_vault)]
    fun agent_cannot_exceed_per_trade_limit() {
        let mut scenario = setup();
        buy_as(&mut scenario, AGENT, TRADE_LIMIT + 1, b"over-per-trade");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_EPOCH_TRADE_LIMIT_EXCEEDED, location = investment_vault)]
    fun repeated_trades_cannot_exceed_epoch_limit() {
        let mut scenario = setup();
        buy_as(&mut scenario, AGENT, 300, b"epoch-part-1");
        // 300 + 201 = 501 > EPOCH_LIMIT(500)
        buy_as(&mut scenario, AGENT, 201, b"epoch-part-2");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_INSUFFICIENT_BALANCE, location = investment_vault)]
    fun agent_cannot_trade_more_than_vault_balance() {
        // 한도(200)보다 잔액(100)이 작을 때 잔액 검사가 걸려야 한다.
        let mut scenario = setup_with(100, 200, 500);
        buy_as(&mut scenario, AGENT, 101, b"over-balance");
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_EPOCH_LIMIT_BELOW_SPENT, location = investment_vault)]
    fun owner_cannot_lower_epoch_limit_below_already_spent_amount() {
        let mut scenario = setup();
        buy_as(&mut scenario, AGENT, 300, b"spent-300");

        scenario.next_tx(OWNER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::update_epoch_trade_limit(&mut vault, 299, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }
}
