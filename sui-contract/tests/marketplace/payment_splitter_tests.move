#[test_only]
module agent_market::payment_splitter_tests {
    use agent_market::payment_splitter;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario;

    const PAYER: address = @0xA;
    const AGENT_ID: address = @0xB;
    const CREATOR: address = @0xC;
    const TREASURY: address = @0xD;

    #[test]
    fun usage_fee_is_split_80_20() {
        let mut scenario = test_scenario::begin(PAYER);
        test_scenario::create_system_objects(&mut scenario);

        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let clock = scenario.take_shared<Clock>();

        payment_splitter::pay_agent_usage_fee(
            payment,
            AGENT_ID,
            CREATOR,
            TREASURY,
            2_000,
            &clock,
            scenario.ctx(),
        );

        test_scenario::return_shared(clock);

        scenario.next_tx(CREATOR);
        let creator_payment = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin::value(&creator_payment) == 8_000);
        coin::burn_for_testing(creator_payment);

        scenario.next_tx(TREASURY);
        let treasury_payment = scenario.take_from_sender<Coin<SUI>>();
        assert!(coin::value(&treasury_payment) == 2_000);
        coin::burn_for_testing(treasury_payment);

        scenario.end();
    }

    #[test]
    #[expected_failure(abort_code = 2, location = agent_market::payment_splitter)]
    fun platform_fee_over_100_percent_is_rejected() {
        let mut scenario = test_scenario::begin(PAYER);
        test_scenario::create_system_objects(&mut scenario);

        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let clock = scenario.take_shared<Clock>();

        payment_splitter::pay_agent_usage_fee(
            payment,
            AGENT_ID,
            CREATOR,
            TREASURY,
            10_001,
            &clock,
            scenario.ctx(),
        );

        test_scenario::return_shared(clock);
        scenario.end();
    }
}
