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

    /// x402 usage payment receipt.
    ///
    /// The generic type T is part of the event type, so the server can verify
    /// that the payment used the token advertised in the HTTP 402 response.
    public struct PaymentReceiptEvent<phantom T> has copy, drop {
        payer: address,
        payee: address,
        treasury: address,
        agent_id: address,
        amount: u64,
        platform_fee_amount: u64,
        digest: vector<u8>,
        timestamp: u64,
    }

    /// Splits an Agent usage fee between its creator and the platform Treasury.
    ///
    /// Example: platform_fee_bps = 2_000
    /// - creator receives 80%
    /// - Treasury receives 20%
    public fun pay_agent_usage_fee<T>(
        mut payment: Coin<T>,
        agent_id: address,
        agent_creator_address: address,
        treasury_address: address,
        platform_fee_bps: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        let amount = coin::value(&payment);

        assert!(amount > 0, E_EMPTY_PAYMENT);
        assert!(platform_fee_bps <= BPS_DENOMINATOR, E_INVALID_PLATFORM_FEE);
        assert!(agent_id != @0x0, E_INVALID_ADDRESS);
        assert!(agent_creator_address != @0x0, E_INVALID_ADDRESS);
        assert!(treasury_address != @0x0, E_INVALID_ADDRESS);

        // Calculate without `amount * platform_fee_bps`, which could overflow u64.
        let whole_units = amount / BPS_DENOMINATOR;
        let remainder = amount % BPS_DENOMINATOR;
        let platform_fee_amount =
            whole_units * platform_fee_bps
                + remainder * platform_fee_bps / BPS_DENOMINATOR;

        // `payment` keeps the creator's remainder after the Treasury share is split.
        let treasury_payment = coin::split(&mut payment, platform_fee_amount, ctx);

        transfer::public_transfer(payment, agent_creator_address);
        transfer::public_transfer(treasury_payment, treasury_address);

        event::emit(PaymentReceiptEvent<T> {
            payer: tx_context::sender(ctx),
            payee: agent_creator_address,
            treasury: treasury_address,
            agent_id,
            amount,
            platform_fee_amount,
            digest: *tx_context::digest(ctx),
            timestamp: clock::timestamp_ms(clock),
        });
    }
}
