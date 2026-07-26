#[test_only]
module agent_market::signal_provider_registry_tests {
    use agent_market::signal_provider_registry::{Self, SignalProvider};
    use std::string;
    use sui::test_scenario;

    const CREATOR: address = @0xCAFE;
    const X402_RECEIVER: address = @0xFEE;

    #[test]
    fun provider_has_x402_configuration_without_follow_fee() {
        let mut scenario = test_scenario::begin(CREATOR);

        signal_provider_registry::create_signal_provider(
            string::utf8(b"Conservative Signal Provider"),
            X402_RECEIVER, // 🔄 follow fee 없이 x402 수령 주소만 등록
            scenario.ctx(),
        );

        scenario.next_tx(CREATOR);
        {
            let provider = scenario.take_from_sender<SignalProvider>(); // 🔄 Agent → SignalProvider
            assert!(
                signal_provider_registry::payment_receiver(&provider)
                    == X402_RECEIVER,
            );
            assert!(signal_provider_registry::is_active(&provider));
            scenario.return_to_sender(provider);
        };

        scenario.end();
    }
}
