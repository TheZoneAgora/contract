// -----------------------------------------------------------------------------
// Signal Provider의 x402 HTTP 핸들러.
//
// payment_challenge.js(발급·검증)와 payment_receipt_reader.js(체인 조회)는 이미
// 있었지만 둘을 요청/응답에 연결하는 층이 없었다. 이 파일이 그 층이다.
//
// 프레임워크에 묶지 않으려고 평범한 객체만 주고받는다. express든 node:http든
// 어댑터에서 { headers, body } 로 바꿔 넘기면 된다. 덕분에 네트워크 없이 테스트된다.
//
// 흐름:
//   1) 결제 증빙 없는 요청        -> 402 + challenge (requestId 발급·보관)
//   2) PAYMENT-SIGNATURE 붙은 요청 -> 영수증 조회 -> 검증 -> 200 + signal
// -----------------------------------------------------------------------------

import { verifySignalPayment } from './payment_challenge.js';

/// 클라이언트가 결제 tx digest를 실어 보내는 헤더.
const PAYMENT_HEADER = 'payment-signature';
/// 402로 내려준 requestId를 되돌려 받는 헤더.
/// 영수증에는 requestId가 없어서, 어느 challenge에 대한 결제인지 이걸로만 알 수 있다.
const REQUEST_ID_HEADER = 'payment-request-id';

/* 헤더 이름은 대소문자를 가리지 않는다. Node는 소문자로 주지만 다른 런타임은 아니다.

    @param {Record<string, unknown>} headers
    @param {string} name 소문자 헤더 이름
    @returns {string | undefined}
*/
function readHeader(headers, name) {
    if (!headers || typeof headers !== 'object') return undefined;

    for (const key of Object.keys(headers)) {
        if (key.toLowerCase() !== name) continue;

        const value = headers[key];
        // node:http는 중복 헤더를 배열로 준다. 첫 값만 쓴다.
        const single = Array.isArray(value) ? value[0] : value;

        if (typeof single !== 'string') return undefined;

        const trimmed = single.trim();
        return trimmed.length > 0 ? trimmed : undefined;
    }

    return undefined;
}

function jsonResponse(status, body) {
    return {
        status,
        headers: { 'content-type': 'application/json' },
        body,
    };
}

/* x402 시그널 핸들러를 만든다. 서버 기동 시 한 번만 부르고 재사용한다.

    @param {{
        config: ReturnType<typeof import('./provider_config.js').loadProviderConfig>,
        challengeStore: ReturnType<typeof import('./payment_challenge.js').createChallengeStore>,
        digestStore: ReturnType<typeof import('./payment_challenge.js').createPaymentDigestStore>,
        fetchReceipt: (txDigest: string) => Promise<object>,
        produceSignal: (context: { requestId: string, body: unknown }) => Promise<unknown> | unknown,
        now?: () => number,
    }} deps
    @returns {(request: { headers?: object, body?: unknown }) => Promise<{
        status: number, headers: object, body: unknown
    }>}
*/
export function createSignalHandler({
    config,
    challengeStore,
    digestStore,
    fetchReceipt,
    produceSignal,
    now = Date.now,
}) {
    if (typeof fetchReceipt !== 'function') {
        throw new Error('fetchReceipt must be a function.');
    }

    if (typeof produceSignal !== 'function') {
        throw new Error('produceSignal must be a function.');
    }

    /* 결제 검증까지 끝낸 요청의 응답을 requestId로 기억한다.

       digestStore.consume()이 digest를 태운 뒤에 시그널을 만들기 때문에, 응답이
       네트워크에서 유실되면 클라이언트는 돈을 내고도 아무것도 못 받는 상태가 된다.
       같은 requestId로 다시 물어보면 검증을 건너뛰고 이 사본을 돌려준다.
       requestId는 서버가 발급해 그 클라이언트에게만 준 값이라 이걸로 공유되지 않는다.

       ⚠️ digestStore와 마찬가지로 프로세스 메모리다. 다중화하면 함께 Redis로 옮겨야 한다. */
    const deliveredSignals = new Map();

    return async function handleSignalRequest(request = {}) {
        const headers = request.headers ?? {};
        const txDigest = readHeader(headers, PAYMENT_HEADER);

        // --- 1) 결제 전: challenge를 발급한다 -------------------------------
        // issue()가 발급과 보관을 함께 한다. 서버가 스스로 기억해야
        // 클라이언트가 보낸 issuedAtMs/expiresAtMs를 믿지 않을 수 있다.
        if (!txDigest) {
            return jsonResponse(402, challengeStore.issue(config, now()));
        }

        // --- 2) 결제 후: 어느 challenge에 대한 결제인지 알아야 한다 ----------
        const requestId = readHeader(headers, REQUEST_ID_HEADER);

        if (!requestId) {
            return jsonResponse(400, {
                error: 'Bad Request',
                reason: `${REQUEST_ID_HEADER} header is required alongside a payment.`,
            });
        }

        // 이미 값을 만들어 준 요청이면 재검증하지 않는다 (digest는 이미 태워졌다).
        if (deliveredSignals.has(requestId)) {
            return jsonResponse(200, deliveredSignals.get(requestId));
        }

        // --- 3) 체인을 보기 전에 우리가 발급한 requestId인지부터 확인한다 -----
        // 순서가 중요하다. 조회를 먼저 하면 아무나 지어낸 requestId로 이 서버의
        // GraphQL 왕복을 유발할 수 있다. 공짜로 할 수 있는 검사를 앞에 둔다.
        try {
            challengeStore.get(requestId, now());
        } catch (error) {
            return jsonResponse(402, {
                error: 'Payment Required',
                reason: error.message,
            });
        }

        // --- 4) 영수증 조회 ------------------------------------------------
        // 체인 조회 실패는 클라이언트 잘못이 아니다. 결제는 유효할 수 있으므로
        // 4xx로 태우지 않고 502로 돌려 재시도할 여지를 남긴다.
        let receipt;

        try {
            receipt = await fetchReceipt(txDigest);
        } catch (error) {
            return jsonResponse(502, {
                error: 'Bad Gateway',
                reason: error.message,
            });
        }

        // --- 5) 검증 --------------------------------------------------------
        // 통과하면 digest가 태워진다. 실패하면 태우지 않으므로 같은 결제로 재시도할 수 있다.
        try {
            verifySignalPayment(
                { receipt, requestId, txDigest, config, challengeStore, digestStore },
                now(),
            );
        } catch (error) {
            return jsonResponse(402, {
                error: 'Payment Required',
                reason: error.message,
            });
        }

        // --- 6) 시그널 전달 --------------------------------------------------
        let signal;

        try {
            signal = await produceSignal({ requestId, body: request.body });
        } catch (error) {
            // digest는 이미 태워졌는데 시그널을 못 만들었다. 클라이언트는 같은 결제로
            // 재시도할 수 없으므로 운영자가 봐야 하는 상황이다. 숨기지 않고 500으로 알린다.
            return jsonResponse(500, {
                error: 'Internal Server Error',
                reason: `Payment was accepted but the signal could not be produced: ${error.message}`,
                txDigest,
                requestId,
            });
        }

        deliveredSignals.set(requestId, signal);

        return jsonResponse(200, signal);
    };
}
