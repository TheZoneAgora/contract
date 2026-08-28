// -----------------------------------------------------------------------------
// 요청 인증 (HMAC-SHA256).
//
// push 방식에서는 우리가 포트를 열고 기다린다. 인증이 없으면 :8500에 닿는
// 누구나 사용자 자금으로 실거래를 일으킬 수 있다 — 온체인 가드는 "한도 안의
// 거래인가"만 보지 "누가 보냈는가"는 보지 않는다.
//
// Providing Agent와 공유 비밀을 나눠 갖고, 본문 바이트에 대한 HMAC을 헤더로 받는다.
//
//   x-agora-signature: sha256=<hex>
//
// 본문 **원본 바이트**에 서명해야 한다. JSON을 파싱했다 다시 직렬화하면
// 공백·키 순서가 달라져 서명이 어긋난다.
//
// ⚠️ 이것이 막는 것과 못 막는 것:
//   막는다   — 비밀을 모르는 제3자의 요청, 본문 변조
//   못 막는다 — 재전송(replay). 다만 시그널은 TTL이 있고 signalId가 온체인에서
//              중복 차단되므로 같은 시그널이 두 번 체결되지는 않는다.
//   못 막는다 — 비밀 유출. 평문 HTTP로 주고받으면 중간에서 읽힌다. 외부에
//              노출할 때는 TLS가 필요하다.
//
// pull(x402)로 전환하면 이 파일은 필요 없어진다 — 열어둘 포트가 없고,
// 결제 증빙 자체가 자격 증명이 되기 때문이다.
// -----------------------------------------------------------------------------

import { createHmac, timingSafeEqual } from 'node:crypto';

export const SIGNATURE_HEADER = 'x-agora-signature';

// 짧은 비밀은 없느니만 못하다. 32바이트 hex(= openssl rand -hex 32)를 기준으로 잡는다.
export const MIN_SECRET_LENGTH = 32;

export function assertUsableSecret(secret) {
    if (typeof secret !== 'string' || secret.length < MIN_SECRET_LENGTH) {
        throw new Error(
            `shared secret must be at least ${MIN_SECRET_LENGTH} characters `
            + '(generate one with: openssl rand -hex 32).'
        );
    }
    return secret;
}

/** 본문 바이트에 대한 서명. Providing Agent 쪽에서도 같은 계산을 한다. */
export function signBody(secret, rawBody) {
    return createHmac('sha256', secret).update(rawBody).digest('hex');
}

/* 헤더의 서명이 본문과 맞는지 확인한다.
 *
 * 비교는 timingSafeEqual로 한다. 문자열 ===는 첫 불일치에서 즉시 빠져나와
 * 걸린 시간으로 앞자리를 한 글자씩 알아낼 수 있다.
 */
export function verifyRequestSignature({ secret, rawBody, header }) {
    if (typeof header !== 'string' || header.length === 0) return false;

    // "sha256=" 접두사는 선택이다. GitHub webhook 관례를 따르되 없어도 받는다.
    const provided = header.startsWith('sha256=') ? header.slice(7) : header.trim();
    const expected = signBody(secret, rawBody);

    // 길이가 다르면 timingSafeEqual이 던진다. 서명 길이 자체는 비밀이 아니다.
    if (provided.length !== expected.length) return false;

    return timingSafeEqual(Buffer.from(provided, 'utf8'), Buffer.from(expected, 'utf8'));
}
