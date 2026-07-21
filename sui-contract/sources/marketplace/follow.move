// 위치: sui-contract/sources/follow.move

module agent_market::follow {
    use sui::object::{Self, UID};
    use sui::coin::{Self, Coin};
    use sui::sui::SUI;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    use agent_market::agent_registry::{Self, Agent};

    const E_AGENT_NOT_ACTIVE: u64 = 1;
    const E_WRONG_FEE_AMOUNT: u64 = 2;

    /// FollowRecord = "이 유저가 이 agent를 팔로우했다"는 영수증
    public struct FollowRecord has key {
        id: UID,

        // 팔로우한 사람
        follower: address,

        // 어떤 agent를 팔로우했는지
        // 실제로는 agent object id를 저장하는 식으로 발전 가능
        agent_id_hint: address,

        // 낸 수수료
        paid_fee_mist: u64,
    }

    /// agent follow하기
    /// payment로 SUI 코인을 받음
    public fun follow_agent(
        agent: &Agent,
        payment: Coin<SUI>,
        ctx: &mut TxContext,
    ) {
        assert!(agent_registry::is_active(agent), E_AGENT_NOT_ACTIVE);

        let required_fee = agent_registry::follow_fee(agent);
        let paid = coin::value(&payment);

        // 공부용 단순 버전:
        // 유저가 정확히 follow_fee만 내야 함
        assert!(paid == required_fee, E_WRONG_FEE_AMOUNT);

        let follower = tx_context::sender(ctx);
        let receiver = agent_registry::receiver(agent);

        // 받은 SUI를 founder/platform 지갑으로 전송
        transfer::public_transfer(payment, receiver);

        let record = FollowRecord {
            id: object::new(ctx),
            follower,
            agent_id_hint: receiver,
            paid_fee_mist: paid,
        };

        // follow 영수증을 유저에게 줌
        transfer::transfer(record, follower);
    }
}