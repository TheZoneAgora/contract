// -----------------------------------------------------------------------------
// 내부 시그널 — Providing Agent가 무엇을 어떻게 보내든 이 형태로 정규화된다.
//
// 어댑터가 맞춰야 할 유일한 계약이다. 실행기 본체는 시그널이 push로 왔는지
// polling으로 가져온 것인지, MINT가 보낸 건지 외부 유료 API인지 알지 못한다.
//
//   { signalId, agentId, side, symbol, price, timestampMs, confidence }
//
// 여기 없는 것과 그 이유:
//   riskScoreBps  Agora가 매긴다. Providing Agent가 자기 위험도를 신고하면
//                 "이 Agent를 믿을 수 있는가"라는 Agora의 존재 이유가 무너진다.
//                 느린 시계(Backtest·Shadow Trading)가 산출한다 (PROGRESS §7).
//   amount        Providing Agent는 사용자 Vault 크기를 모른다. 방향만 주면
//                 Agora가 Vault 한도 안에서 사이징한다.
// -----------------------------------------------------------------------------

import { createHash } from 'node:crypto';

export const SIDES = new Set(['BUY', 'SELL']);

/* signalId를 결정론적으로 만든다.
 *
 * 자체 id가 없는 Agent(점수만 내는 ML 봇, 폴링으로 읽어오는 외부 API)를 위한 것이다.
 * 온체인 중복 차단이 signalId 하나에 걸려 있어서, 발급을 남에게 맡기면
 * 규칙이 엉성할 때 같은 판단이 두 번 실행되거나 다른 판단이 막힌다.
 *
 * 같은 판단은 같은 id가 나와야 하고(재시도 안전), 다른 판단은 달라야 한다.
 * 시각을 버킷으로 뭉개는 이유: 폴링은 같은 판단을 여러 번 관측하므로
 * 밀리초를 그대로 쓰면 매번 다른 id가 나와 중복 실행된다.
 */
export function deriveSignalId({ agentId, symbol, side, timestampMs }, bucketMs = 60_000) {
    const bucket = Math.floor(timestampMs / bucketMs);
    const material = `${agentId}|${symbol}|${side}|${bucket}`;

    // 온체인에 vector<u8>로 저장되므로 짧게 유지한다.
    return `${agentId}-${createHash('sha256').update(material).digest('hex').slice(0, 24)}`;
}

/* 어댑터가 만든 값이 내부 계약을 지키는지 확인한다.
   여기서 막히면 체인을 건드리기 전이라 가스가 들지 않는다.

   @returns {object} 정규화된 시그널
   @throws {Error} 계약 위반 시
*/
export function normalizeSignal(raw, { chainNowMs, signalTtlMs }) {
    if (typeof raw !== 'object' || raw === null) {
        throw new Error('signal must be an object.');
    }

    const { agentId, side, symbol, price, timestampMs, confidence } = raw;

    if (typeof agentId !== 'string' || agentId.trim().length === 0) {
        throw new Error('agentId is required.');
    }
    if (typeof side !== 'string' || !SIDES.has(side)) {
        throw new Error('side must be "BUY" or "SELL".');
    }
    if (typeof symbol !== 'string' || !symbol.includes('/')) {
        throw new Error('symbol must look like "BASE/QUOTE".');
    }
    // Agent가 본 가격이어야 한다. 우리가 채우면 온체인 편차 가드가
    // "우리 값 vs 우리 값"이 되어 무력화된다.
    if (typeof price !== 'number' || !Number.isFinite(price) || price <= 0) {
        throw new Error('price must be a positive number (agent-observed market price).');
    }
    if (!Number.isInteger(timestampMs)) {
        throw new Error('timestampMs must be an integer (epoch ms).');
    }
    if (confidence !== undefined
        && (typeof confidence !== 'number' || confidence < 0 || confidence > 1)) {
        throw new Error('confidence must be between 0 and 1 when present.');
    }

    // 오래된 시그널은 온체인에서 E_SIGNAL_EXPIRED로 거부된다. 가스를 버리기 전에 끊는다.
    if (chainNowMs - timestampMs > signalTtlMs) {
        throw new Error(
            `signal is older than ${signalTtlMs}ms and would be rejected on-chain.`
        );
    }

    // 체인 시각보다 미래면 E_SIGNAL_FROM_FUTURE(2)로 거부된다. Agent가 자기 벽시계로
    // 찍은 값이 체인(체크포인트 기준, ~1.7초 지연)보다 앞서는 것은 정상이므로
    // 거부하지 않고 당겨 준다. 뒤로 당기는 것은 TTL을 더 엄격하게 만들 뿐이라 안전하다.
    const effectiveTimestampMs = Math.min(timestampMs, chainNowMs);

    const signalId = typeof raw.signalId === 'string' && raw.signalId.trim().length > 0
        ? raw.signalId.trim()
        : deriveSignalId({ agentId, symbol, side, timestampMs: effectiveTimestampMs });

    if (Buffer.byteLength(signalId, 'utf8') > 64) {
        throw new Error('signalId must be at most 64 bytes.');
    }

    return {
        signalId,
        agentId,
        side,
        symbol,
        price,
        timestampMs: effectiveTimestampMs,
        confidence,
    };
}
