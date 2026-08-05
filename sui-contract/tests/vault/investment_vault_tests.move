#[test_only]
module agent_market::investment_vault_tests {
    use agent_market::investment_vault::{Self, UserVault};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario::{Self, Scenario};

    /// 테스트에서 SUI와 다른 crypto 타입을 구분하기 위한 가상 코인 타입이다.
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

    const E_NOT_OWNER: u64 = 1;
    const E_NOT_AGENT: u64 = 2;
    const E_AGENT_INACTIVE: u64 = 3;
    const E_TRADE_LIMIT_EXCEEDED: u64 = 4;
    const E_INSUFFICIENT_BALANCE: u64 = 5;
    const E_EPOCH_TRADE_LIMIT_EXCEEDED: u64 = 6;
    const E_EPOCH_LIMIT_BELOW_SPENT: u64 = 7;
    const E_INVALID_EPOCH_LIMIT: u64 = 8;
    const E_BUY_DISABLED_IN_REDUCE_ONLY: u64 = 14; // 🆕 REDUCE_ONLY BUY 실패 검증

    fun create_sui_vault(scenario: &mut Scenario) {
        let deposit = coin::mint_for_testing<SUI>(INITIAL_BALANCE, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit,
            AGENT,
            TRADE_LIMIT,
            EPOCH_LIMIT,
            CRYPTO_SELL_LIMIT,
            EPOCH_CRYPTO_SELL_LIMIT,
            scenario.ctx(),
        );
    }

    #[test]
    fun owner_can_create_deposit_and_withdraw_partial_amount() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::vault_balance(&vault) == INITIAL_BALANCE);

            let extra = coin::mint_for_testing<SUI>(200, scenario.ctx());
            investment_vault::deposit_more(&mut vault, extra, scenario.ctx());
            assert!(investment_vault::vault_balance(&vault) == 1_200);

            investment_vault::withdraw_amount(&mut vault, 250, scenario.ctx());
            assert!(investment_vault::vault_balance(&vault) == 950);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        {
            let withdrawn = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&withdrawn) == 250);
            coin::burn_for_testing(withdrawn);
        };

        scenario.end();
    }

    #[test]
    fun owner_can_withdraw_all_assets() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::withdraw_all_assets(&mut vault, scenario.ctx());
            assert!(investment_vault::vault_balance(&vault) == 0);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        {
            let withdrawn_fiat = scenario.take_from_sender<Coin<SUI>>();
            let withdrawn_crypto = scenario.take_from_sender<Coin<TestCrypto>>();
            assert!(coin::value(&withdrawn_fiat) == INITIAL_BALANCE);
            assert!(coin::value(&withdrawn_crypto) == 0);
            coin::burn_for_testing(withdrawn_fiat);
            coin::burn_for_testing(withdrawn_crypto);
        };

        scenario.end();
    }

    #[test]
    fun owner_can_manage_fiat_and_crypto_balances_separately() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            let crypto = coin::mint_for_testing<TestCrypto>(250, scenario.ctx());

            investment_vault::deposit_crypto_for_testing(
                &mut vault,
                crypto,
                scenario.ctx(),
            );

            assert!(investment_vault::fiat_balance(&vault) == INITIAL_BALANCE);
            assert!(investment_vault::crypto_balance(&vault) == 250);

            investment_vault::withdraw_crypto_amount(
                &mut vault,
                100,
                scenario.ctx(),
            );

            assert!(investment_vault::fiat_balance(&vault) == INITIAL_BALANCE);
            assert!(investment_vault::crypto_balance(&vault) == 150);
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        {
            let withdrawn = scenario.take_from_sender<Coin<TestCrypto>>();
            assert!(coin::value(&withdrawn) == 100);
            coin::burn_for_testing(withdrawn);
        };

        scenario.end();
    }

    #[test]
    fun vault_exposes_only_configured_agora_agent_operator() { // 🆕 단일 AgoraAgent 검증
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            assert!(investment_vault::agora_agent_operator(&vault) == AGENT); // 🆕 주소 조회 검증
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_INVALID_EPOCH_LIMIT,
        location = investment_vault,
    )]
    fun zero_per_trade_limit_is_rejected() {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(INITIAL_BALANCE, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit,
            AGENT,
            0,
            EPOCH_LIMIT,
            CRYPTO_SELL_LIMIT,
            EPOCH_CRYPTO_SELL_LIMIT,
            scenario.ctx(),
        );
        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_INVALID_EPOCH_LIMIT,
        location = investment_vault,
    )]
    fun epoch_limit_below_per_trade_limit_is_rejected() {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(INITIAL_BALANCE, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit,
            AGENT,
            300,
            299,
            CRYPTO_SELL_LIMIT,
            EPOCH_CRYPTO_SELL_LIMIT,
            scenario.ctx(),
        );
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_OWNER, location = investment_vault)]
    fun agent_cannot_withdraw_assets() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::withdraw_amount(&mut vault, 1, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_OWNER, location = investment_vault)]
    fun attacker_cannot_replace_agent() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(ATTACKER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::replace_agent(&mut vault, ATTACKER, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

}
