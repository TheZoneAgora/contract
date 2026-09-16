// -----------------------------------------------------------------------------
// 시그널 pull — 실행기가 Providing Agent의 GET 엔드포인트를 주기적으로 읽는다.
//
// 왜 pull인가 (PROGRESS §0-9):
//   push는 실행기가 포트를 열고 기다린다. 실행기는 운영자 키를 든 프로세스라
//   그 포트가 곧 자금 입구가 되고, 공유 비밀 전달·TLS·방화벽이 전부 우리 몫이 된다.
//   pull은 **나가는 요청만** 있다. 받아들이는 포트가 없으니 입구 자체가 사라진다.
//   BE가 등록받는 endpoint_url도 "시그널을 가져갈 GET 주소"라 방향이 맞는다.
//
// 대신 "진짜 MINT의 응답인가"는 전송 구간이 보장해야 한다. 평문 HTTP로 인터넷을
// 건너면 중간에서 가짜 시그널을 끼워 넣을 수 있다 — 그래서 주소를 기동 단계에서
// 검사한다 (assertSafeSignalUrl).
//
// 네트워크를 직접 부르지 않는다. fetch와 시그널 처리를 주입받아 테스트에서 재현한다.
// -----------------------------------------------------------------------------

import { createHash } from 'node:crypto';

// 시그널 한 건은 수백 바이트다. 이보다 크면 엔드포인트를 잘못 가리킨 것이다.
export const MAX_RESPONSE_BYTES = 64 * 1024;

/* Tailscale은 100.64.0.0/10(CGNAT 대역)을 쓰고 WireGuard로 암호화·인증한다.
   이 대역과 MagicDNS(*.ts.net)는 평문 HTTP여도 전송 구간이 보호된다. */
function isTailnetHost(hostname) {
    if (hostname.endsWith('.ts.net')) return true;

    const octets = hostname.split('.').map(Number);
    if (octets.length !== 4 || octets.some((o) => !Number.isInteger(o) || o < 0 || o > 255)) {
        return false;
    }
    return octets[0] === 100 && octets[1] >= 64 && octets[1] <= 127;
}

function isLoopbackHost(hostname) {
    return hostname === 'localhost'
        || hostname === '[::1]'
        || /^127\.\d{1,3}\.\d{1,3}\.\d{1,3}$/.test(hostname);
}

/* 시그널을 가져올 주소가 전송 구간을 보호하는지 확인한다.
 *
 * 통과: https, 같은 기기(loopback), Tailscale 사설망
 * 거부: 그 외 평문 http — 같은 LAN이어도 기본은 거부한다. 필요하면 allowInsecure로
 *       명시적으로 연다(로그에 남는다).
 *
 * @returns {URL}
 */
export function assertSafeSignalUrl(raw, { allowInsecure = false } = {}) {
    let url;
    try {
        url = new URL(raw);
    } catch {
        throw new Error(`signal URL is not a valid URL: ${raw}`);
    }

    if (url.protocol === 'https:') return url;

    if (url.protocol !== 'http:') {
        throw new Error(`signal URL must be http(s), got ${url.protocol}`);
    }

    if (isLoopbackHost(url.hostname) || isTailnetHost(url.hostname) || allowInsecure) {
        return url;
    }

    throw new Error(
        `signal URL ${url.origin} is plain HTTP over an untrusted network. `
        + 'Anyone on the path could inject signals that move user funds. '
        + 'Use https, a Tailscale address (100.64.0.0/10, *.ts.net), '
        + 'or set AGENT_ALLOW_INSECURE_SIGNAL_URL=true for a trusted LAN.'
    );
}

/* GET 응답을 시그널 본문 목록으로 바꾼다.
 *
 * 약속한 형태 (PROGRESS §13-1):
 *   204 또는 빈 본문 / null / {} / []    지금 낼 시그널 없음
 *   { side, symbol, price, timestamp_ms } 최근 시그널 한 건 (push 본문과 같은 형식)
 *   [ {...}, {...} ]                     여러 건 — 오래된 것부터
 *
 * 형식 검사는 여기서 하지 않는다. 한 건이 잘못돼도 나머지는 처리돼야 하므로
 * 건별로 normalizeSignal이 판정한다.
 */
export function parseSignalResponse({ status, text }) {
    if (status === 204) return [];
    if (status < 200 || status >= 300) {
        throw new Error(`signal endpoint responded ${status}.`);
    }

    const trimmed = typeof text === 'string' ? text.trim() : '';
    if (trimmed.length === 0) return [];

    let parsed;
    try {
        parsed = JSON.parse(trimmed);
    } catch {
        throw new Error('signal endpoint did not return JSON.');
    }

    if (parsed === null) return [];
    if (Array.isArray(parsed)) return parsed;
    if (typeof parsed === 'object') {
        return Object.keys(parsed).length === 0 ? [] : [parsed];
    }

    throw new Error('signal endpoint must return a JSON object or array.');
}

/* 같은 응답 항목을 알아보는 키.
   폴링은 같은 "최근 시그널"을 매번 다시 읽는다. 키가 같으면 이미 처리한 것이다. */
export function fingerprintOf(item) {
    return createHash('sha256').update(JSON.stringify(item)).digest('hex');
}

/* 처리가 끝난 항목 기록. 오래된 것부터 버린다.
   ⚠️ 프로세스 메모리다. 재시작하면 같은 시그널을 한 번 더 읽지만, 그때는
   온체인 중복 차단(E_DUPLICATE_SIGNAL)과 TTL이 막는다. */
export function createSeenSet(limit = 1_000) {
    const keys = new Set();

    return {
        has: (key) => keys.has(key),
        add(key) {
            keys.add(key);
            if (keys.size > limit) keys.delete(keys.values().next().value);
        },
        get size() {
            return keys.size;
        },
    };
}

/* 한 번 읽고, 처음 보는 항목만 처리한다.
 *
 * processItem은 { terminal } 을 돌려준다.
 *   terminal=true   체결 · 온체인 거부 · 형식 거부 — 다시 시도해도 결과가 같다
 *   terminal=false  체인 시각 조회 실패처럼 일시적인 것 — 다음 폴링에서 다시 시도한다
 * 일시 실패를 "처리함"으로 기록하면 정상 시그널이 조용히 사라진다.
 */
export async function pollOnce({ url, fetchImpl = fetch, timeoutMs, seen, processItem }) {
    const response = await fetchImpl(url, {
        method: 'GET',
        headers: { accept: 'application/json' },
        // https → http로 넘기는 리다이렉트를 따라가면 주소 검사가 무의미해진다.
        redirect: 'error',
        signal: AbortSignal.timeout(timeoutMs),
    });

    const text = await response.text();
    if (Buffer.byteLength(text, 'utf8') > MAX_RESPONSE_BYTES) {
        throw new Error(`signal endpoint response exceeds ${MAX_RESPONSE_BYTES} bytes.`);
    }

    const items = parseSignalResponse({ status: response.status, text });
    let processed = 0;

    for (const item of items) {
        const key = fingerprintOf(item);
        if (seen.has(key)) continue;

        const { terminal } = await processItem(item);
        processed += 1;
        if (terminal) seen.add(key);
    }

    return { fetched: items.length, processed };
}
