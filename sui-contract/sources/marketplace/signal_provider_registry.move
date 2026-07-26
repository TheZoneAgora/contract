module agent_market::signal_provider_registry {
    use std::string::String;

    /// AgoraAgent가 x402로 투자 신호를 구매할 수 있는 외부 제공자 등록 정보다.
    /// 사용자는 Signal Provider를 선택하거나 follow하지 않으며, 이 객체에도 Vault 권한이 없다.
    public struct SignalProvider has key {
        id: UID,

        name: String,

        x402_payment_receiver: address, // 🔄 follow fee 수령자 → AgoraAgent의 x402 결제 수령자

        active: bool,
    }

    /// Signal Provider를 등록한다. 사용자 follow 또는 고정 follow fee는 생성하지 않는다.
    public fun create_signal_provider(
        name: String,
        x402_payment_receiver: address, // 🔄 사용자가 아닌 AgoraAgent가 지불할 수령 주소
        ctx: &mut TxContext,
    ) {
        let provider = SignalProvider {
            id: object::new(ctx),
            name,
            x402_payment_receiver, // 🔄 follow_fee_mist 제거, x402 수령 주소만 저장
            active: true,
        };

        transfer::transfer(provider, tx_context::sender(ctx));
    }

    public fun payment_receiver(provider: &SignalProvider): address {
        provider.x402_payment_receiver
    }

    public fun is_active(provider: &SignalProvider): bool {
        provider.active
    }
}
