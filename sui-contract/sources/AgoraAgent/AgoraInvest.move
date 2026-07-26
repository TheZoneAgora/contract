module agent_market::agora_invest {
    use agent_market::investment_vault::{Self, UserVault};
    use sui::event;

    const E_EMPTY_SIGNAL_DIGEST: u64 = 1;
    const E_INVALID_RISK_SCORE: u64 = 2;
    const BPS_DENOMINATOR: u64 = 10_000;

    /// AgoraAgent가 BUY 판단에 사용한 외부 신호와 위험 점수를 기록한다.
    public struct AgoraBuyDecisionRecorded<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agora_agent_operator: address,
        signal_digest: vector<u8>,
        risk_score_bps: u64,
        fiat_amount: u64,
        epoch: u64,
    }

    /// AgoraAgent가 SELL 판단에 사용한 외부 신호와 위험 점수를 기록한다.
    public struct AgoraSellDecisionRecorded<phantom FiatT, phantom CryptoT> has copy, drop {
        vault_id: ID,
        agora_agent_operator: address,
        signal_digest: vector<u8>,
        risk_score_bps: u64,
        crypto_amount: u64,
        epoch: u64,
    }

    /// 외부 Signal Provider 응답을 검증한 AgoraAgent가 BUY를 요청한다.
    public fun request_buy<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        fiat_amount: u64,
        signal_digest: vector<u8>, // 🆕 AgoraAgent가 사용한 신호 묶음의 해시
        risk_score_bps: u64, // 🆕 Agora 내부 위험 점수
        ctx: &TxContext,
    ) {
        assert!(vector::length(&signal_digest) > 0, E_EMPTY_SIGNAL_DIGEST);
        assert!(risk_score_bps <= BPS_DENOMINATOR, E_INVALID_RISK_SCORE);

        investment_vault::request_buy(vault, fiat_amount, ctx); // 🆕 Vault 권한·한도 검증 재사용

        event::emit(AgoraBuyDecisionRecorded<FiatT, CryptoT> {
            vault_id: object::id(vault),
            agora_agent_operator: tx_context::sender(ctx),
            signal_digest,
            risk_score_bps,
            fiat_amount,
            epoch: tx_context::epoch(ctx),
        });
    }

    /// 외부 Signal Provider 응답을 검증한 AgoraAgent가 SELL을 요청한다.
    /// Vault가 REDUCE_ONLY 상태여도 기존 포지션 축소를 위한 SELL은 가능하다.
    public fun request_sell<FiatT, CryptoT>(
        vault: &mut UserVault<FiatT, CryptoT>,
        crypto_amount: u64,
        signal_digest: vector<u8>, // 🆕 AgoraAgent가 사용한 신호 묶음의 해시
        risk_score_bps: u64, // 🆕 Agora 내부 위험 점수
        ctx: &TxContext,
    ) {
        assert!(vector::length(&signal_digest) > 0, E_EMPTY_SIGNAL_DIGEST);
        assert!(risk_score_bps <= BPS_DENOMINATOR, E_INVALID_RISK_SCORE);

        investment_vault::request_sell(vault, crypto_amount, ctx); // 🆕 Vault 권한·한도 검증 재사용

        event::emit(AgoraSellDecisionRecorded<FiatT, CryptoT> {
            vault_id: object::id(vault),
            agora_agent_operator: tx_context::sender(ctx),
            signal_digest,
            risk_score_bps,
            crypto_amount,
            epoch: tx_context::epoch(ctx),
        });
    }
}
