#[test_only]
module agent_market::vault_execution_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::vault_harness;
    use agent_market::vault_policy;
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario;

    public struct TestCrypto has drop {}

    const OWNER: address = @0xA11CE;
    const AGENT: address = @0xA6E17;
    const NOW_MS: u64 = 1_000_000;
    const PRICE_E9: u64 = 1_000_000_000;
    /// setup이 설정하는 BUY 위험도 상한이다.
    const MAX_RISK_BPS: u64 = 6_000;
    /// 정상 주문이 사용하는 위험도다.
    const SAFE_RISK_BPS: u64 = 1_000;
    /// 급락 감시 창. 기존 테스트는 Kill Switch에 걸리지 않도록 넉넉히 둔다.
    const LOSS_WINDOW_MS: u64 = 3_600_000;
    const MAX_WINDOW_LOSS: u64 = 1_000_000;

    fun setup(): test_scenario::Scenario {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit, AGENT, 500, 1_000, 500, 1_000, scenario.ctx(),
        );

        let mut clock = clock::create_for_testing(scenario.ctx());
        clock::set_for_testing(&mut clock, NOW_MS);
        clock::share_for_testing(clock);

        scenario.next_tx(OWNER);

        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::configure_execution_policy(
            &mut vault,
            vault_harness::pool(),
            1_000,
            1_000,
            500,
            0,
            0,
            60_000,
            500,
            MAX_RISK_BPS,
            LOSS_WINDOW_MS,
            MAX_WINDOW_LOSS,
            scenario.ctx(),
        );
        test_scenario::return_shared(vault);
        scenario
    }

    fun reconfigure(
        scenario: &mut test_scenario::Scenario,
        max_daily: u64,
        max_position: u64,
        max_loss: u64,
        start_minute: u64,
        end_minute: u64,
        max_delay_ms: u64,
        max_deviation_bps: u64,
        max_risk_score_bps: u64,
    ) {
        scenario.next_tx(OWNER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::configure_execution_policy(
            &mut vault, vault_harness::pool(), max_daily, max_position, max_loss,
            start_minute, end_minute, max_delay_ms, max_deviation_bps,
            max_risk_score_bps, LOSS_WINDOW_MS, MAX_WINDOW_LOSS, scenario.ctx(),
        );
        test_scenario::return_shared(vault);
    }

    #[test]
    fun buy_settles_atomically_and_records_signal() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);

        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        let signal_id = b"signal-buy-1";

        vault_harness::execute_buy(
            &mut vault,
            PRICE_E9,
            100,
            100,
            signal_id,
            NOW_MS - 1_000,
            PRICE_E9,
            SAFE_RISK_BPS,
            NOW_MS + 10_000,
            &clock,
            scenario.ctx(),
        );

        assert!(investment_vault::fiat_balance(&vault) == 900);
        assert!(investment_vault::crypto_balance(&vault) == 100);
        assert!(investment_vault::daily_fiat_volume(&vault) == 100);
        assert!(investment_vault::signal_executed(&vault, signal_id));
        assert!(investment_vault::max_risk_score_bps(&vault) == MAX_RISK_BPS);

        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 17, location = investment_vault)]
    fun duplicate_signal_cannot_execute_twice() {
        let mut scenario = setup();
        let signal_id = b"duplicate-signal";

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, signal_id,
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, signal_id,
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 5, location = vault_policy)]
    fun excessive_signal_to_quote_deviation_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 1, b"bad-price",
            NOW_MS, 2_000_000_000, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 21, location = investment_vault)]
    fun minimum_output_protects_against_bad_execution() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 101, b"slippage-protected",
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test]
    fun sell_returns_fiat_to_the_same_vault() {
        let mut scenario = setup();

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"buy-before-sell",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_sell(
                &mut vault, PRICE_E9, 100, 100, b"sell-1",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            assert!(investment_vault::crypto_balance(&vault) == 0);
            assert!(investment_vault::realized_loss_amount(&vault) == 0);
            assert!(investment_vault::signal_executed(&vault, b"sell-1"));
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = 3, location = vault_policy)]
    fun expired_signal_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 10, 10, b"expired",
            NOW_MS - 60_001, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 1, location = vault_harness)]
    fun expired_transaction_deadline_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 10, 10, b"late-transaction",
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS - 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 19, location = investment_vault)]
    fun maximum_position_size_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 1_000, 50, 500, 0, 0, 60_000, 500, MAX_RISK_BPS);
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, b"position-limit",
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 18, location = investment_vault)]
    fun daily_fiat_volume_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 600, 1_000, 500, 0, 0, 60_000, 500, MAX_RISK_BPS);
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 500, 500, b"daily-1",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 101, 101, b"daily-2",
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 20, location = investment_vault)]
    fun cumulative_realized_loss_limit_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 2_000, 1_000, 40, 0, 0, 60_000, 10_000, MAX_RISK_BPS);
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"loss-buy",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_sell(
            &mut vault, 500_000_000, 100, 50, b"loss-sell",
            NOW_MS, 500_000_000, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    // 위험도 강제 --------------------------------------------------------

    #[test]
    fun buy_at_the_risk_limit_is_allowed() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        // 상한과 같은 값은 통과해야 한다. 경계에서 거래가 막히면 안 된다.
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, b"risk-at-limit",
            NOW_MS, PRICE_E9, MAX_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
        );
        assert!(investment_vault::crypto_balance(&vault) == 100);
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 22, location = investment_vault)]
    fun buy_above_the_risk_limit_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, b"risk-too-high",
            NOW_MS, PRICE_E9, MAX_RISK_BPS + 1, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test]
    fun rejected_high_risk_buy_leaves_no_trace() {
        let mut scenario = setup();

        // 상한을 넘는 BUY가 abort된 뒤에도 잔액과 Signal 기록이 그대로여야 한다.
        // 같은 Signal ID를 낮은 위험도로 다시 실행할 수 있어야 정상이다.
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            assert!(!investment_vault::signal_executed(&vault, b"retry-signal"));
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"retry-signal",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
            );
            assert!(investment_vault::signal_executed(&vault, b"retry-signal"));
            assert!(investment_vault::fiat_balance(&vault) == 900);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun high_risk_sell_is_still_allowed() {
        let mut scenario = setup();

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"safe-entry",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        // 위험도가 최대여도 탈출 경로인 SELL은 막지 않는다.
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_sell(
                &mut vault, PRICE_E9, 100, 100, b"panic-exit",
                NOW_MS, PRICE_E9, 10_000, NOW_MS + 1, &clock, scenario.ctx(),
            );
            assert!(investment_vault::crypto_balance(&vault) == 0);
            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = 23, location = investment_vault)]
    fun risk_score_outside_bps_range_is_rejected_on_buy() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, b"malformed-risk",
            NOW_MS, PRICE_E9, 10_001, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 23, location = investment_vault)]
    fun risk_score_outside_bps_range_is_rejected_on_sell() {
        let mut scenario = setup();

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"entry-before-bad-sell",
                NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_sell(
            &mut vault, PRICE_E9, 100, 100, b"malformed-risk-sell",
            NOW_MS, PRICE_E9, 10_001, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 22, location = investment_vault)]
    fun owner_can_tighten_the_risk_limit() {
        let mut scenario = setup();

        // 처음에는 통과하던 위험도가 Owner가 상한을 낮추면 차단되어야 한다.
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            vault_harness::execute_buy(
                &mut vault, PRICE_E9, 100, 100, b"before-tighten",
                NOW_MS, PRICE_E9, 3_000, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(vault);
        };

        reconfigure(&mut scenario, 1_000, 1_000, 500, 0, 0, 60_000, 500, 2_000);

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, 100, 100, b"after-tighten",
            NOW_MS, PRICE_E9, 3_000, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 23, location = investment_vault)]
    fun policy_rejects_risk_limit_outside_bps_range() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 1_000, 1_000, 500, 0, 0, 60_000, 500, 10_001);
        scenario.end();
    }
}
