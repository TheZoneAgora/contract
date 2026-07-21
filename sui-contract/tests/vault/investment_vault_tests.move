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
    fun authorized_agent_request_does_not_remove_vault_assets() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, TRADE_LIMIT, scenario.ctx());
            assert!(investment_vault::vault_balance(&vault) == INITIAL_BALANCE);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun buy_uses_fiat_and_sell_uses_crypto_with_separate_limits() {
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
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();

            investment_vault::request_buy(&mut vault, 300, scenario.ctx());
            investment_vault::request_sell(&mut vault, 200, scenario.ctx());

            // 요청 단계에서는 자산을 이동하지 않는다.
            // BUY는 fiat 한도, SELL은 crypto 한도를 서로 독립적으로 사용한다.
            assert!(investment_vault::fiat_balance(&vault) == INITIAL_BALANCE);
            assert!(investment_vault::crypto_balance(&vault) == 250);
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_INSUFFICIENT_BALANCE,
        location = investment_vault,
    )]
    fun sell_cannot_use_fiat_when_crypto_balance_is_insufficient() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();

        // fiat_balance가 충분해도 crypto_balance가 0이면 SELL은 실패해야 한다.
        investment_vault::request_sell(&mut vault, 1, scenario.ctx());

        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test]
    fun new_epoch_resets_cumulative_trade_allowance() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, TRADE_LIMIT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_epoch(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, TRADE_LIMIT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun replacement_agent_can_trade_after_owner_replaces_agent() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::replace_agent(&mut vault, NEW_AGENT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(NEW_AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, 100, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.end();
    }

    #[test]
    fun owner_can_revoke_and_reactivate_agent() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::revoke_agent(&mut vault, scenario.ctx());
            investment_vault::reactivate_agent(&mut vault, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, 100, scenario.ctx());
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

    #[test, expected_failure(abort_code = E_NOT_AGENT, location = investment_vault)]
    fun unregistered_address_cannot_request_trade() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(ATTACKER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, 1, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_AGENT_INACTIVE, location = investment_vault)]
    fun revoked_agent_cannot_request_trade() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::revoke_agent(&mut vault, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, 1, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_TRADE_LIMIT_EXCEEDED,
        location = investment_vault,
    )]
    fun agent_cannot_exceed_per_trade_limit() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, TRADE_LIMIT + 1, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_EPOCH_TRADE_LIMIT_EXCEEDED,
        location = investment_vault,
    )]
    fun repeated_requests_cannot_exceed_epoch_limit() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, 300, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, 201, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_INSUFFICIENT_BALANCE,
        location = investment_vault,
    )]
    fun agent_cannot_request_more_than_vault_balance() {
        let mut scenario = test_scenario::begin(OWNER);
        let deposit = coin::mint_for_testing<SUI>(100, scenario.ctx());
        investment_vault::create_vault<SUI, TestCrypto>(
            deposit,
            AGENT,
            200,
            500,
            CRYPTO_SELL_LIMIT,
            EPOCH_CRYPTO_SELL_LIMIT,
            scenario.ctx(),
        );

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, 101, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(
        abort_code = E_EPOCH_LIMIT_BELOW_SPENT,
        location = investment_vault,
    )]
    fun owner_cannot_lower_epoch_limit_below_already_spent_amount() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(AGENT);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::request_trade(&mut vault, 300, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(OWNER);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::update_epoch_trade_limit(&mut vault, 299, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }

    #[test, expected_failure(abort_code = E_NOT_AGENT, location = investment_vault)]
    fun replaced_agent_loses_trade_authority() {
        let mut scenario = test_scenario::begin(OWNER);
        create_sui_vault(&mut scenario);

        scenario.next_tx(OWNER);
        {
            let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
            investment_vault::replace_agent(&mut vault, NEW_AGENT, scenario.ctx());
            test_scenario::return_shared(vault);
        };

        scenario.next_tx(AGENT);
        let mut vault = scenario.take_shared<UserVault<SUI, TestCrypto>>();
        investment_vault::request_trade(&mut vault, 1, scenario.ctx());
        test_scenario::return_shared(vault);
        scenario.end();
    }
}
