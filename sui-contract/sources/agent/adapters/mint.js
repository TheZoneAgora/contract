// -----------------------------------------------------------------------------
// MINT push 어댑터.
//
// MINT(Go 봇)가 판단할 때마다 POST로 보내는 형식을 내부 시그널로 옮긴다.
// Agent가 늘어나면 이 파일만 옆에 하나씩 추가한다 — 실행기 본체는 안 바뀐다.
//
// MINT는 snake_case를 쓰고 우리 내부 형태는 camelCase다. 그 변환도 여기서 흡수한다.
// Agent에게 "우리 표기법에 맞춰주세요"라고 요구하지 않기 위해서다.
//
// ⚠️ risk_score_bps는 받아도 버린다. 위험도는 Agora가 매기는 값이다 (signal.js 참고).
// -----------------------------------------------------------------------------

export const MINT_ADAPTER_ID = 'mint-push';

/* MINT가 보낸 본문을 내부 시그널 형태로 옮긴다.
 * 값 검증은 하지 않는다 — normalizeSignal이 한 곳에서 담당한다.
 * 여기가 하는 일은 "이름 맞추기"뿐이다.
 */
export function fromMintPush(body) {
    if (typeof body !== 'object' || body === null) {
        throw new Error('body must be a JSON object.');
    }

    return {
        // 둘 다 받는다. MINT가 안 주면 signal.js가 결정론적으로 만든다.
        signalId: body.signal_id ?? body.signalId,
        agentId: body.agent_id ?? body.agentId ?? 'mint',
        side: typeof body.side === 'string' ? body.side.toUpperCase() : body.side,
        symbol: body.symbol,
        price: body.price,
        timestampMs: body.timestamp_ms ?? body.timestampMs,
        confidence: body.confidence,
    };
}
