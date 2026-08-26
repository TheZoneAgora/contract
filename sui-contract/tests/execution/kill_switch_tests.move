// 급락 기반 하드 스위치를 검증한다.
//
// max_loss_amount는 Vault 수명 전체의 누적 손실을 보므로 짧은 시간에 벌어지는
// 급락을 잡지 못한다. Kill Switch는 loss_window_ms 창 안의 손실 합계를 보고
// Vault를 즉시 PAUSED로 내린다.
#[test_only]
module agent_market::kill_switch_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use agent_market::vault_harness;
    use sui::clock::{Self, Clock};
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};

    public struct TestCrypto has drop {}

    const OWNER: address = @0xA11CE;
    const AGENT: address = @0xA6E17;
    const NOW_MS: u64 = 1_000_000;
    const PRICE_E9: u64 = 1_000_000_000;
    /// 절반으로 떨어진 가격. 100 매수 후 여기서 전량 매도하면 실현 손실이 50이다.
    const CRASH_PRICE_E9: u64 = 500_000_000;
    const SAFE_RISK_BPS: u64 = 1_000;

    const E_AGENT_INACTIVE: u64 = 3;

    fun setup(loss_window_ms: u64, max_window_loss: u64): Scenario {
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
            10_000,   // max_daily_fiat_volume
            10_000,   // max_position_size
            10_000,   // max_loss_amount — 누적 한도는 넉넉히 두고 창 한도만 시험한다
            0,
            0,
            600_000,  // max_signal_delay_ms
            10_000,   // max_price_deviation_bps — 폭락 가격도 통과시킨다
            10_000,   // max_risk_score_bps
            loss_window_ms,
            max_window_loss,
            scenario.ctx(),
        );
        test_scenario::return_shared(vault);
        scenario
    }

    fun buy(scenario: &mut Scenario, amount: u64, now_ms: u64, signal_id: vector<u8>) {
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_buy(
            &mut vault, PRICE_E9, amount, amount, signal_id,
            now_ms, PRICE_E9, SAFE_RISK_BPS, now_ms + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
    }

    /// 가격을 절반으로 떨어뜨린 뒤 전량 매도해 실현 손실을 만든다.
    fun crash_and_sell(
        scenario: &mut Scenario,
        amount: u64,
        now_ms: u64,
        signal_id: vector<u8>,
    ) {
        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        let clock = scenario.take_shared<Clock>();
        vault_harness::execute_sell(
            &mut vault, CRASH_PRICE_E9, amount, amount / 2, signal_id,
            now_ms, CRASH_PRICE_E9, SAFE_RISK_BPS, now_ms + 10_000, &clock, scenario.ctx(),
        );
        test_scenario::return_shared(clock);
        test_scenario::return_shared(vault);
    }


    fun advance_clock(scenario: &mut Scenario, to_ms: u64) {
        scenario.next_tx(OWNER);
        let mut clock = scenario.take_shared<Clock>();
        clock::set_for_testing(&mut clock, to_ms);
        test_scenario::return_shared(clock);
    }

    #[test]
    fun rapid_loss_triggers_kill_switch_but_settles_the_current_sell() {
        // 창 한도 40 < 실현 손실 50 이므로 발동해야 한다.
        let mut scenario = setup(3_600_000, 40);
        buy(&mut scenario, 100, NOW_MS, b"entry");
        crash_and_sell(&mut scenario, 100, NOW_MS, b"crash-exit");

        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            // 진행 중이던 매도는 되돌리지 않는다. 손실 국면에서 포지션 축소를
            // 막으면 손실이 오히려 커지기 때문이다.
            assert!(investment_vault::crypto_balance(&vault) == 0);
            assert!(investment_vault::fiat_balance(&vault) == 950);
            assert!(investment_vault::realized_loss_amount(&vault) == 50);
            assert!(investment_vault::window_loss_amount(&vault) == 50);
            // 다음 주문부터 차단된다.
            assert!(investment_vault::is_paused(&vault));
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = E_AGENT_INACTIVE, location = investment_vault)]
    fun kill_switch_blocks_the_next_trade() {
        let mut scenario = setup(3_600_000, 40);
        buy(&mut scenario, 100, NOW_MS, b"entry");
        crash_and_sell(&mut scenario, 100, NOW_MS, b"crash-exit");

        // 정지된 Vault에서는 AgoraAgent가 새 주문을 낼 수 없다.
        buy(&mut scenario, 10, NOW_MS, b"blocked-after-kill");
        scenario.end();
    }

    #[test]
    fun loss_within_the_window_limit_keeps_the_vault_active() {
        // 창 한도 100 > 실현 손실 50 이므로 발동하지 않아야 한다.
        let mut scenario = setup(3_600_000, 100);
        buy(&mut scenario, 100, NOW_MS, b"entry");
        crash_and_sell(&mut scenario, 100, NOW_MS, b"soft-exit");

        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::window_loss_amount(&vault) == 50);
            assert!(!investment_vault::is_paused(&vault));
            assert!(investment_vault::is_agora_agent_active(&vault));
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun loss_window_resets_after_the_window_elapses() {
        // 창 한도 60. 손실 50이 두 번 나지만 서로 다른 창에 속하므로 발동하지 않는다.
        // 창이 리셋되지 않았다면 합계 100 > 60으로 발동했을 것이다.
        let mut scenario = setup(1_000, 60);

        buy(&mut scenario, 100, NOW_MS, b"entry-1");
        crash_and_sell(&mut scenario, 100, NOW_MS, b"exit-1");

        let later_ms = NOW_MS + 2_000;
        advance_clock(&mut scenario, later_ms);

        buy(&mut scenario, 100, later_ms, b"entry-2");
        crash_and_sell(&mut scenario, 100, later_ms, b"exit-2");

        scenario.next_tx(AGENT);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            // 누적 손실은 100이지만 현재 창의 손실은 50으로 초기화되어 있다.
            assert!(investment_vault::realized_loss_amount(&vault) == 100);
            assert!(investment_vault::window_loss_amount(&vault) == 50);
            assert!(!investment_vault::is_paused(&vault));
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun owner_can_reactivate_the_vault_after_a_kill_switch() {
        let mut scenario = setup(3_600_000, 40);
        buy(&mut scenario, 100, NOW_MS, b"entry");
        crash_and_sell(&mut scenario, 100, NOW_MS, b"crash-exit");

        // 복구 권한은 Owner에게만 있다. AgoraAgent는 스스로 풀 수 없다.
        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::is_paused(&vault));
            investment_vault::reactivate_agent(&mut vault, scenario.ctx());
            assert!(investment_vault::is_agora_agent_active(&vault));
            test_scenario::return_shared(vault);
        };

        buy(&mut scenario, 10, NOW_MS, b"after-reactivate");
        scenario.end();
    }
}
