#[test_only]
module agent_market::fee_vault_tests {
    use agent_market::fee_vault::{Self, FeeVault};
    use sui::test_scenario;

    const CREATOR: address = @0xCAFE;
    const RECEIVER: address = @0xFEE;

    #[test]
    fun performance_fee_is_calculated_in_basis_points() {
        // 1,000 MIST의 20%(2,000 bps)는 200 MIST다.
        assert!(fee_vault::calculate_performance_fee(1_000, 2_000) == 200);

        // 수익이 0이면 수수료도 0이다.
        assert!(fee_vault::calculate_performance_fee(0, 2_000) == 0);
    }

    #[test]
    fun fee_vault_is_sent_to_configured_receiver() {
        let mut scenario = test_scenario::begin(CREATOR);
        fee_vault::create_vault(RECEIVER, 2_000, scenario.ctx());

        scenario.next_tx(RECEIVER);
        assert!(scenario.has_most_recent_for_sender<FeeVault>());

        scenario.end();
    }
}
