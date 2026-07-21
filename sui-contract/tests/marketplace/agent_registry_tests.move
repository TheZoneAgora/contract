#[test_only]
module agent_market::agent_registry_tests {
    use agent_market::agent_registry::{Self, Agent};
    use std::string;
    use sui::test_scenario;

    const CREATOR: address = @0xCAFE;
    const RECEIVER: address = @0xFEE;

    #[test]
    fun created_agent_has_expected_public_configuration() {
        let mut scenario = test_scenario::begin(CREATOR);

        agent_registry::create_agent(
            string::utf8(b"Conservative Agent"),
            100,
            RECEIVER,
            scenario.ctx(),
        );

        scenario.next_tx(CREATOR);
        {
            let agent = scenario.take_from_sender<Agent>();
            assert!(agent_registry::follow_fee(&agent) == 100);
            assert!(agent_registry::receiver(&agent) == RECEIVER);
            assert!(agent_registry::is_active(&agent));
            scenario.return_to_sender(agent);
        };

        scenario.end();
    }
}
