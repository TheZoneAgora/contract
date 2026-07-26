module agent_market::payment_splitter {
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::event;
    use sui::transfer;
    use sui::tx_context::{Self, TxContext};

    /// Basis points denominator. 10_000 bps = 100%.
    const BPS_DENOMINATOR: u64 = 10_000;

    const E_EMPTY_PAYMENT: u64 = 1;
    const E_INVALID_PLATFORM_FEE: u64 = 2;
    const E_INVALID_ADDRESS: u64 = 3;

    /// AgoraAgent가 외부 Signal Provider에 지불한 x402 신호 사용 영수증.
    ///
    /// The generic type T is part of the event type, so the server can verify
    /// that the payment used the token advertised in the HTTP 402 response.
    public struct SignalPaymentReceiptEvent<phantom T> has copy, drop { // 🔄 Agent 사용료 → 신호 구매 영수증
        payer: address, // 🔄 사용자가 아닌 AgoraAgent 운영 주소
        payee: address,
        treasury: address,
        signal_provider_id: address, // 🔄 사용자 선택 Agent ID → 내부 Signal Provider ID
        amount: u64,
        platform_fee_amount: u64,
        digest: vector<u8>,
        timestamp: u64,
    }

    /// AgoraAgent가 지불한 Signal Provider 사용료를 Provider와 Treasury에 분배한다.
    ///
    /// Example: platform_fee_bps = 2_000
    /// - creator receives 80%
    /// - Treasury receives 20%
    public fun pay_signal_provider_usage_fee<T>( // 🔄 사용자 Agent 결제 → AgoraAgent 신호 구매 결제
        mut payment: Coin<T>,
        signal_provider_id: address, // 🔄 선택 Agent ID → 내부 Signal Provider ID
        signal_provider_payment_receiver: address, // 🔄 Agent creator → Signal Provider 수령자
        treasury_address: address,
        platform_fee_bps: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&payment);

        assert!(amount > 0, E_EMPTY_PAYMENT);
        assert!(platform_fee_bps <= BPS_DENOMINATOR, E_INVALID_PLATFORM_FEE);
        assert!(signal_provider_id != @0x0, E_INVALID_ADDRESS);
        assert!(signal_provider_payment_receiver != @0x0, E_INVALID_ADDRESS);
        assert!(treasury_address != @0x0, E_INVALID_ADDRESS);

        // Calculate without `amount * platform_fee_bps`, which could overflow u64.
        let whole_units = amount / BPS_DENOMINATOR;
        let remainder = amount % BPS_DENOMINATOR;
        let platform_fee_amount =
            whole_units * platform_fee_bps
                + remainder * platform_fee_bps / BPS_DENOMINATOR;

        // `payment` keeps the creator's remainder after the Treasury share is split.
        let treasury_payment = coin::split(&mut payment, platform_fee_amount, ctx);

        transfer::public_transfer(payment, signal_provider_payment_receiver); // 🔄 x402 Provider 수령
        transfer::public_transfer(treasury_payment, treasury_address);

        event::emit(SignalPaymentReceiptEvent<T> { // 🔄 신호 구매 전용 이벤트
            payer: tx_context::sender(ctx), // 🔄 AgoraAgent가 payer
            payee: signal_provider_payment_receiver,
            treasury: treasury_address,
            signal_provider_id, // 🔄 내부 Provider 식별자 기록
            amount,
            platform_fee_amount,
            digest: *tx_context::digest(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }
}
