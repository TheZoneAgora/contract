#[test_only]
module agent_market::payment_splitter_tests {
    use agent_market::payment_splitter;
    use sui::clock::Clock;
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::test_scenario;

    const AGORA_AGENT: address = @0xA; // 🔄 사용자 payer → AgoraAgent payer
    const SIGNAL_PROVIDER_ID: address = @0xB; // 🔄 Agent ID → Signal Provider ID
    const PROVIDER_RECEIVER: address = @0xC; // 🔄 Agent creator → Provider 수령자
    const TREASURY: address = @0xD;

    #[test]
    fun signal_usage_fee_paid_by_agora_agent_is_split_80_20() { // 🔄 AgoraAgent x402 결제 검증
        let mut scenario = test_scenario::begin(AGORA_AGENT);
        test_scenario::create_system_objects(&mut scenario);

        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let clock = scenario.take_shared<Clock>();

        payment_splitter::pay_signal_provider_usage_fee( // 🔄 신호 구매 결제 함수
            payment,
            SIGNAL_PROVIDER_ID,
            PROVIDER_RECEIVER,
            TREASURY,
            2_000,
            &clock,
            scenario.ctx(),
        );

        test_scenario::return_shared(clock);

        scenario.next_tx(PROVIDER_RECEIVER);
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
        let mut scenario = test_scenario::begin(AGORA_AGENT);
        test_scenario::create_system_objects(&mut scenario);

        let payment = coin::mint_for_testing<SUI>(10_000, scenario.ctx());
        let clock = scenario.take_shared<Clock>();

        payment_splitter::pay_signal_provider_usage_fee( // 🔄 신호 구매 결제 함수
            payment,
            SIGNAL_PROVIDER_ID,
            PROVIDER_RECEIVER,
            TREASURY,
            10_001,
            &clock,
            scenario.ctx(),
        );

        test_scenario::return_shared(clock);
        scenario.end();
    }
}
