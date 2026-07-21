#[test_only]
module agent_market::follow_tests {
    use agent_market::agent_registry::{Self, Agent};
    use agent_market::follow::{Self, FollowRecord};
    use std::string;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario;

    const CREATOR: address = @0xCAFE;
    const RECEIVER: address = @0xFEE;
    const FOLLOW_FEE: u64 = 100;
    const E_WRONG_FEE_AMOUNT: u64 = 2;

    fun create_agent(scenario: &mut test_scenario::Scenario) {
        agent_registry::create_agent(
            string::utf8(b"Test Agent"),
            FOLLOW_FEE,
            RECEIVER,
            scenario.ctx(),
        );
    }

    #[test]
    fun agent_owner_can_follow_and_fee_reaches_receiver() {
        let mut scenario = test_scenario::begin(CREATOR);
        create_agent(&mut scenario);

        scenario.next_tx(CREATOR);
        {
            let agent = scenario.take_from_sender<Agent>();
            let payment = coin::mint_for_testing<SUI>(FOLLOW_FEE, scenario.ctx());
            follow::follow_agent(&agent, payment, scenario.ctx());
            scenario.return_to_sender(agent);
        };

        scenario.next_tx(CREATOR);
        assert!(scenario.has_most_recent_for_sender<FollowRecord>());

        scenario.next_tx(RECEIVER);
        {
            let payment = scenario.take_from_sender<Coin<SUI>>();
            assert!(coin::value(&payment) == FOLLOW_FEE);
            coin::burn_for_testing(payment);
        };

        scenario.end();
    }

    #[test, expected_failure(abort_code = E_WRONG_FEE_AMOUNT, location = follow)]
    fun wrong_follow_fee_is_rejected() {
        let mut scenario = test_scenario::begin(CREATOR);
        create_agent(&mut scenario);

        scenario.next_tx(CREATOR);
        let agent = scenario.take_from_sender<Agent>();
        let payment = coin::mint_for_testing<SUI>(FOLLOW_FEE - 1, scenario.ctx());
        follow::follow_agent(&agent, payment, scenario.ctx());
        scenario.return_to_sender(agent);
        scenario.end();
    }
}
