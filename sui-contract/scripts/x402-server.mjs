// -----------------------------------------------------------------------------
// Signal Provider x402 서버 (node:http 어댑터).
//
//   cd sui-contract && node scripts/x402-server.mjs
//
// 필요한 환경변수는 sources/x402/provider_config.js 참고. 하나라도 없으면
// 요청을 받기 전에 기동이 실패한다 — 반쯤 설정된 채로 결제를 받는 것보다 낫다.
//
// 의도적으로 의존성이 없다. express를 넣지 않은 이유는 핸들러가
// createSignalHandler에 전부 들어 있고, 여기는 HTTP를 평범한 객체로 바꾸는
// 얇은 층이기 때문이다. BE가 express를 쓴다면 이 파일 대신 어댑터만 다시 쓰면 된다.
//
// ⚠️ 시그널 생성(produceSignal)은 아직 자리표시자다. Backtest/Shadow/Trust Score를
//    돌리는 Providing Agent 본체는 별도 작업이다(PROGRESS §8-6).
// -----------------------------------------------------------------------------

import { createServer } from 'node:http';

import { loadProviderConfig } from '../sources/x402/provider_config.js';
import {
    createChallengeStore,
    createPaymentDigestStore,
} from '../sources/x402/payment_challenge.js';
import {
    createReceiptReader,
    fetchPaymentReceipt,
} from '../sources/x402/payment_receipt_reader.js';
import { createSignalHandler } from '../sources/x402/signal_handler.js';

const PORT = Number(process.env.X402_PORT ?? 8402);
const SIGNAL_PATH = process.env.X402_SIGNAL_PATH ?? '/signal';
// 결제 tx 하나에 이 서버가 걸어 둘 수 있는 최대 본문 크기.
// 없으면 아무나 큰 본문을 밀어 넣어 메모리를 채울 수 있다.
const MAX_BODY_BYTES = 64 * 1024;

const config = loadProviderConfig();
const reader = createReceiptReader(config.graphqlUrl);

const handleSignalRequest = createSignalHandler({
    config,
    challengeStore: createChallengeStore(),
    digestStore: createPaymentDigestStore(),
    fetchReceipt: (txDigest) => fetchPaymentReceipt(reader, txDigest),
    produceSignal: async ({ requestId }) => {
        // TODO(PROGRESS §8-6): Providing Agent 본체로 교체한다.
        return {
            requestId,
            issuedAtMs: String(Date.now()),
            note: 'placeholder signal — Providing Agent not wired yet',
        };
    },
});

/* 요청 본문을 읽는다. JSON이 아니면 undefined로 두고 핸들러가 판단하게 한다.
   본문은 결제 검증에 쓰이지 않으므로 파싱 실패가 402 흐름을 막아서는 안 된다. */
function readBody(request) {
    return new Promise((resolve, reject) => {
        const chunks = [];
        let size = 0;

        request.on('data', (chunk) => {
            size += chunk.length;

            if (size > MAX_BODY_BYTES) {
                reject(new Error('Request body is too large.'));
                request.destroy();
                return;
            }

            chunks.push(chunk);
        });

        request.on('error', reject);

        request.on('end', () => {
            const raw = Buffer.concat(chunks).toString('utf8');

            if (raw.trim().length === 0) {
                resolve(undefined);
                return;
            }

            try {
                resolve(JSON.parse(raw));
            } catch {
                resolve(undefined);
            }
        });
    });
}

function send(response, { status, headers, body }) {
    const payload = JSON.stringify(body);

    response.writeHead(status, {
        ...headers,
        'content-length': Buffer.byteLength(payload),
    });
    response.end(payload);
}

const server = createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host ?? 'localhost'}`);

    if (url.pathname !== SIGNAL_PATH) {
        send(response, {
            status: 404,
            headers: { 'content-type': 'application/json' },
            body: { error: 'Not Found' },
        });
        return;
    }

    if (request.method !== 'POST') {
        send(response, {
            status: 405,
            headers: { 'content-type': 'application/json', allow: 'POST' },
            body: { error: 'Method Not Allowed' },
        });
        return;
    }

    try {
        const body = await readBody(request);
        send(response, await handleSignalRequest({ headers: request.headers, body }));
    } catch (error) {
        // 여기까지 온 예외는 핸들러가 처리하지 못한 것이다. 내부 사정을
        // 그대로 노출하지 않도록 메시지만 담아 돌려준다.
        send(response, {
            status: 500,
            headers: { 'content-type': 'application/json' },
            body: { error: 'Internal Server Error', reason: error.message },
        });
    }
});

server.listen(PORT, () => {
    console.log(`x402 signal provider listening on :${PORT}${SIGNAL_PATH}`);
    console.log(`  package  ${config.packageId}`);
    console.log(`  provider ${config.providerId}`);
    console.log(`  price    ${config.paymentAmount} ${config.paymentToken}`);
    console.log(`  fee      ${config.platformFeeBps} bps -> ${config.treasuryAddress}`);
});
