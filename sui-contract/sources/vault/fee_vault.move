// 위치: sui-contract/sources/fee_vault.move

module agent_market::fee_vault {
    use sui::object::{Self, UID};
    use sui::tx_context::TxContext;
    use sui::transfer;

    /// 나중에 예치금/수익률 수수료를 관리할 금고
    /// 지금은 공부용 뼈대만
    public struct FeeVault has key {
        id: UID,

        // 수수료 받을 주소
        fee_receiver: address,

        // performance fee 비율
        // 예: 2000 = 20%
        performance_fee_bps: u64,
    }

    public fun create_vault(
        fee_receiver: address,
        performance_fee_bps: u64,
        ctx: &mut TxContext,
    ) {
        let vault = FeeVault {
            id: object::new(ctx),
            fee_receiver,
            performance_fee_bps,
        };

        transfer::transfer(vault, fee_receiver);
    }

    /// bps = basis points
    /// 10000 bps = 100%
    /// 2000 bps = 20%
    public fun calculate_performance_fee(
        profit_mist: u64,
        performance_fee_bps: u64,
    ): u64 {
        profit_mist * performance_fee_bps / 10000
    }
}