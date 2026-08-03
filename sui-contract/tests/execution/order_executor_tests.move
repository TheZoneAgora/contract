#[test_only]
module agent_market::order_executor_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::mock_dex::{Self, MockPool};
    use agent_market::order_executor;
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

    fun setup(): test_scenario::Scenario {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit, AGENT, 500, 1_000, 500, 1_000, scenario.ctx(),
        );

        let fiat_liquidity = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let crypto_liquidity = coin::mint_for_testing<TestCrypto>(10_000, scenario.ctx());
        mock_dex::create_pool(
            fiat_liquidity, crypto_liquidity, PRICE_E9, scenario.ctx(),
        );

        let mut clock = clock::create_for_testing(scenario.ctx());
        clock::set_for_testing(&mut clock, NOW_MS);
        clock::share_for_testing(clock);

        scenario.next_tx(OWNER);
        let pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let pool_address = object::id_address(&pool);
        test_scenario::return_shared(pool);

        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::configure_execution_policy(
            &mut vault,
            pool_address,
            1_000,
            1_000,
            500,
            0,
            0,
            60_000,
            500,
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
    ) {
        scenario.next_tx(OWNER);
        let pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let pool_address = object::id_address(&pool);
        test_scenario::return_shared(pool);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::configure_execution_policy(
            &mut vault, pool_address, max_daily, max_position, max_loss,
            start_minute, end_minute, max_delay_ms, max_deviation_bps,
            scenario.ctx(),
        );
        test_scenario::return_shared(vault);
    }

    #[test]
    fun buy_settles_atomically_and_records_signal() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);

        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        let signal_id = b"signal-buy-1";

        order_executor::execute_buy(
            &mut vault,
            &mut pool,
            100,
            100,
            signal_id,
            NOW_MS - 1_000,
            PRICE_E9,
            NOW_MS + 10_000,
            &clock,
            scenario.ctx(),
        );

        assert!(investment_vault::fiat_balance(&vault) == 900);
        assert!(investment_vault::crypto_balance(&vault) == 100);
        assert!(investment_vault::daily_fiat_volume(&vault) == 100);
        assert!(investment_vault::signal_executed(&vault, signal_id));

        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
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
            let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            order_executor::execute_buy(
                &mut vault, &mut pool, 100, 100, signal_id,
                NOW_MS, PRICE_E9, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 100, 100, signal_id,
            NOW_MS, PRICE_E9, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 5, location = vault_policy)]
    fun excessive_signal_to_quote_deviation_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 100, 1, b"bad-price",
            NOW_MS, 2_000_000_000, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 21, location = investment_vault)]
    fun minimum_output_protects_against_bad_execution() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 100, 101, b"slippage-protected",
            NOW_MS, PRICE_E9, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test]
    fun sell_returns_fiat_to_the_same_vault() {
        let mut scenario = setup();

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            order_executor::execute_buy(
                &mut vault, &mut pool, 100, 100, b"buy-before-sell",
                NOW_MS, PRICE_E9, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            order_executor::execute_sell(
                &mut vault, &mut pool, 100, 100, b"sell-1",
                NOW_MS, PRICE_E9, NOW_MS + 10_000, &clock, scenario.ctx(),
            );
            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            assert!(investment_vault::crypto_balance(&vault) == 0);
            assert!(investment_vault::realized_loss_amount(&vault) == 0);
            assert!(investment_vault::signal_executed(&vault, b"sell-1"));
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = 3, location = vault_policy)]
    fun expired_signal_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 10, 10, b"expired",
            NOW_MS - 60_001, PRICE_E9, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 1, location = order_executor)]
    fun expired_transaction_deadline_is_rejected() {
        let mut scenario = setup();
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 10, 10, b"late-transaction",
            NOW_MS, PRICE_E9, NOW_MS - 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 19, location = investment_vault)]
    fun maximum_position_size_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 1_000, 50, 500, 0, 0, 60_000, 500);
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 100, 100, b"position-limit",
            NOW_MS, PRICE_E9, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 18, location = investment_vault)]
    fun daily_fiat_volume_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 600, 1_000, 500, 0, 0, 60_000, 500);
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            order_executor::execute_buy(
                &mut vault, &mut pool, 500, 500, b"daily-1",
                NOW_MS, PRICE_E9, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(vault);
        };
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, 101, 101, b"daily-2",
            NOW_MS, PRICE_E9, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = 20, location = investment_vault)]
    fun cumulative_realized_loss_limit_is_enforced() {
        let mut scenario = setup();
        reconfigure(&mut scenario, 2_000, 1_000, 40, 0, 0, 60_000, 10_000);
        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
            let clock = scenario.take_shared<Clock>();
            order_executor::execute_buy(
                &mut vault, &mut pool, 100, 100, b"loss-buy",
                NOW_MS, PRICE_E9, NOW_MS + 1, &clock, scenario.ctx(),
            );
            test_scenario::return_shared(clock);
            test_scenario::return_shared(pool);
            test_scenario::return_shared(vault);
        };
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        mock_dex::set_price_for_testing(&mut pool, 500_000_000);
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_sell(
            &mut vault, &mut pool, 100, 50, b"loss-sell",
            NOW_MS, 500_000_000, NOW_MS + 1, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
        scenario.end();
    }
}
