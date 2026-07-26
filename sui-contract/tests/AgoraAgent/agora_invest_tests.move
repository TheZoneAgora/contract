#[test_only]
module agent_market::agora_invest_tests {
    use agent_market::agora_invest;
    use agent_market::investment_vault::{Self, UserVault};
    use sui::coin;
    use sui::sui::SUI;
    use sui::test_scenario;

    public struct TestCrypto has drop {}

    const OWNER: address = @0xA11CE;
    const AGORA_AGENT: address = @0xA6E17;
    const E_INVALID_RISK_SCORE: u64 = 2;

    fun create_vault(scenario: &mut test_scenario::Scenario) {
        let deposit = coin::mint_for_testing<SUI>(1_000, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit,
            AGORA_AGENT,
            300,
            500,
            200,
            400,
            scenario.ctx(),
        );
    }

    #[test]
    fun agora_agent_records_signal_and_reuses_vault_buy_guards() {
        let mut scenario = test_scenario::begin(OWNER);
        create_vault(&mut scenario);

        scenario.next_tx(AGORA_AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();

            agora_invest::request_buy(
                &mut vault,
                100,
                b"signal-bundle-digest",
                2_500,
                scenario.ctx(),
            );

            assert!(investment_vault::fiat_balance(&vault) == 1_000);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_INVALID_RISK_SCORE,
        location = agora_invest,
    )]
    fun risk_score_over_100_percent_is_rejected() {
        let mut scenario = test_scenario::begin(OWNER);
        create_vault(&mut scenario);

        scenario.next_tx(AGORA_AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();

        agora_invest::request_buy(
            &mut vault,
            100,
            b"signal-bundle-digest",
            10_001,
            scenario.ctx(),
        );

        test_scenario::return_shared(vault);
        scenario.end();
    }
}
