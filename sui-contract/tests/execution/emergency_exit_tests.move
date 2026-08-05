// Owner 전용 긴급 탈출 경로를 검증한다.
//
// 핵심 불변식: 거래 한도는 AgoraAgent를 묶는 장치이지 Owner를 묶는 장치가 아니다.
// Vault가 PAUSED여도, 한도를 다 썼어도, 거래 시간대가 아니어도 Owner는 자기 자산을
// 회수할 수 있어야 한다.
#[test_only]
module agent_market::emergency_exit_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::mock_dex::{Self, MockPool};
    use agent_market::order_executor;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};

    public struct TestCrypto has drop {}

    const OWNER: address = @0xA11CE;
    const AGENT: address = @0xA6E17;
    const ATTACKER: address = @0xBAD;

    const NOW_MS: u64 = 1_000_000;
    const PRICE_E9: u64 = 1_000_000_000;
    const CRASH_PRICE_E9: u64 = 500_000_000;
    const SAFE_RISK_BPS: u64 = 1_000;

    const E_NOT_OWNER: u64 = 1;
    const E_MIN_OUTPUT_NOT_MET: u64 = 21;
    const E_NOTHING_TO_LIQUIDATE: u64 = 25;
    const E_NOTHING_TO_WITHDRAW: u64 = 26;

    /// 한도를 의도적으로 좁게 잡는다. 긴급 경로가 이 한도를 무시하는지 보기 위함이다.
    fun setup(): Scenario {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit, AGENT, 200, 400, 100, 200, scenario.ctx(),
        );

        let fiat_liquidity = coin::mint_for_testing<SUI>(100_000, scenario.ctx());
        let crypto_liquidity = coin::mint_for_testing<TestCrypto>(100_000, scenario.ctx());
        mock_dex::create_pool(fiat_liquidity, crypto_liquidity, PRICE_E9, scenario.ctx());

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
            400,       // max_daily_fiat_volume — 좁게
            10_000,    // max_position_size
            50,        // max_loss_amount — 긴급 청산 손실보다 작게
            0,
            0,
            600_000,
            10_000,
            10_000,
            3_600_000,
            50,        // max_window_loss_amount
            scenario.ctx(),
        );
        test_scenario::return_shared(vault);
        scenario
    }

    fun agent_buy(scenario: &mut Scenario, amount: u64, signal_id: vector<u8>) {
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::execute_buy(
            &mut vault, &mut pool, amount, amount, signal_id,
            NOW_MS, PRICE_E9, SAFE_RISK_BPS, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
    }

    fun crash_price(scenario: &mut Scenario) {
        scenario.next_tx(OWNER);
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        mock_dex::set_price_for_testing(&mut pool, CRASH_PRICE_E9);
        test_scenario::return_shared(pool);
    }

    fun liquidate_as(scenario: &mut Scenario, sender: address, min_fiat_output: u64) {
        scenario.next_tx(sender);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let mut pool = scenario.take_shared<MockPool<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        order_executor::emergency_liquidate_all(
            &mut vault, &mut pool, min_fiat_output, NOW_MS + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(pool);
        test_scenario::return_shared(vault);
    }

    // 1. 전체 매도 -------------------------------------------------------

    #[test]
    fun emergency_liquidation_converts_all_crypto_to_fiat_and_pauses() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");

        // 폭락 후 전량 청산한다. 손실 100은 max_loss_amount(50)를 넘지만
        // 긴급 청산은 손실 한도로 막히지 않아야 한다.
        crash_price(&mut scenario);
        liquidate_as(&mut scenario, OWNER, 100);

        scenario.next_tx(OWNER);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::crypto_balance(&vault) == 0);
            // 1000 - 200(매수) + 100(청산 대금) = 900
            assert!(investment_vault::fiat_balance(&vault) == 900);
            assert!(investment_vault::realized_loss_amount(&vault) == 100);
            // 탈출 직후 AgoraAgent가 재매수하지 못하도록 정지된다.
            assert!(investment_vault::is_paused(&vault));
            test_scenario::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun emergency_liquidation_works_while_the_vault_is_paused() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");

        // Kill Switch나 Owner가 이미 정지시킨 상태를 재현한다.
        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::revoke_agent(&mut vault, scenario.ctx());
            assert!(investment_vault::is_paused(&vault));
            test_scenario::return_shared(vault);
        };

        // 정지 상태에서도 Owner의 탈출 경로는 열려 있어야 한다.
        liquidate_as(&mut scenario, OWNER, 200);

        scenario.next_tx(OWNER);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::crypto_balance(&vault) == 0);
            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            test_scenario::return_shared(vault);
        };
        scenario.end();
    }

    #[test]
    fun emergency_liquidation_ignores_agent_trade_limits() {
        let mut scenario = setup();
        // 1회 매도 한도는 100인데 200을 한 번에 청산한다.
        agent_buy(&mut scenario, 200, b"entry");
        liquidate_as(&mut scenario, OWNER, 200);

        scenario.next_tx(OWNER);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::crypto_balance(&vault) == 0);
            test_scenario::return_shared(vault);
        };
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_OWNER, location = investment_vault)]
    fun agent_cannot_trigger_emergency_liquidation() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");
        // 긴급 청산은 자산의 주인만 쓸 수 있다. Agent는 쓸 수 없다.
        liquidate_as(&mut scenario, AGENT, 1);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_MIN_OUTPUT_NOT_MET, location = investment_vault)]
    fun emergency_liquidation_still_enforces_minimum_output() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");
        crash_price(&mut scenario);
        // 폭락으로 100만 받는데 200을 요구하면 중단된다.
        // 이 검사가 없으면 긴급 버튼이 곧 샌드위치 공격 경로가 된다.
        liquidate_as(&mut scenario, OWNER, 200);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOTHING_TO_LIQUIDATE, location = investment_vault)]
    fun emergency_liquidation_requires_a_position() {
        let mut scenario = setup();
        liquidate_as(&mut scenario, OWNER, 0);
        scenario.end();
    }

    // 2. 정지 + USDC 회수 ------------------------------------------------

    #[test]
    fun emergency_pause_and_withdraw_moves_fiat_to_the_owner() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::emergency_pause_and_withdraw_fiat(&mut vault, scenario.ctx());

            // FiatT는 전액 빠져나가고 정지된다.
            assert!(investment_vault::fiat_balance(&vault) == 0);
            assert!(investment_vault::is_paused(&vault));
            // CryptoT 포지션은 그대로 남는다. 시장가 매도는 별도 결정이다.
            assert!(investment_vault::crypto_balance(&vault) == 200);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        {
            let withdrawn = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&withdrawn) == 800);
            coin::burn_for_testing(withdrawn);
        };
        scenario.end();
    }

    #[test]
    fun liquidation_then_withdrawal_empties_the_vault() {
        let mut scenario = setup();
        agent_buy(&mut scenario, 200, b"entry");

        // 실제 사용 순서: 전량 청산 → USDC 회수
        liquidate_as(&mut scenario, OWNER, 200);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::emergency_pause_and_withdraw_fiat(&mut vault, scenario.ctx());
            assert!(investment_vault::fiat_balance(&vault) == 0);
            assert!(investment_vault::crypto_balance(&vault) == 0);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        {
            let withdrawn = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&withdrawn) == 1_000);
            coin::burn_for_testing(withdrawn);
        };
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_OWNER, location = investment_vault)]
    fun attacker_cannot_pause_and_withdraw() {
        let mut scenario = setup();
        scenario.next_tx(ATTACKER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::emergency_pause_and_withdraw_fiat(&mut vault, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOTHING_TO_WITHDRAW, location = investment_vault)]
    fun emergency_withdrawal_requires_a_fiat_balance() {
        let mut scenario = setup();

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::emergency_pause_and_withdraw_fiat(&mut vault, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::emergency_pause_and_withdraw_fiat(&mut vault, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }
}
