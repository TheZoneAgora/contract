module agent_market::agent_registry {
    use std::string::String;

    //Agent = 투자 봇 하나
    //예: "Sui Conservative Agent"

    public struct Agent has key{
        id: UID,

        // 화면에 보여줄 agent이름
        name: String,

        // follow할 때 받을 고정 수수료
        // SUI는 아주 작은 단위인 MIST로 게산됨
        follow_fee_mist: u64,

        // 수수료 받을 주소
        fee_receiver: address,

        // trueㅁ면 유저가 follow 가능
        active: bool,
    }

    // agent 만들기
    // 처음으로 admin 권한 체크 없이 공부용으로 단순하게 시작
    public fun create_agent(
        name: String,
        follow_fee_mist: u64,
        fee_receiver: address,
        ctx: &mut TxContext,
    ) {
        let agent = Agent {
            id: object::new(ctx),
            name,
            follow_fee_mist,
            fee_receiver,
            active: true,
        };

        // 만든 agent 객채를  트랜잭션 보낸 사람에게 보냄
        transfer::transfer(agent, tx_context::sender(ctx));
    }

    public fun follow_fee(agent: &Agent): u64 {
        agent.follow_fee_mist
    }

    public fun receiver(agent: &Agent): address {
        agent.fee_receiver
    }

    public fun is_active(agent: &Agent): bool {
        agent.active
    }
}