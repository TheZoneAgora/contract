// -----------------------------------------------------------------------------
// AgoraAgent 실행기 (1차 데모용).
//
//   cd sui-contract && ./scripts/run-agent.sh
//
// RFC §2의 "빠른 시계" 자리다. 이 파일은 설정 로드와 HTTP 라우팅만 한다.
//
//   sources/agent/adapters/*   Agent별 형식 → 내부 시그널   (Agent마다 하나씩 늘어남)
//   sources/agent/signal.js    내부 시그널 계약 · signalId 생성
//   sources/agent/executor.js  내부 시그널 → 온체인 실행
//
// 실행기 본체는 시그널이 push로 왔는지 polling으로 가져온 것인지 알지 못한다.
// 외부 Agent를 붙일 때 어댑터만 추가하면 되고 아래 코드는 바뀌지 않는다.
//
// ⚠️ 1차 데모 범위다. 아직 없는 것 (PROGRESS §8):
//   - 시그널 검증 / Trust Score   → 형식 검사만 하고 전부 통과시킨다
//   - 위험도 산출                 → 느린 시계가 없어 고정값을 쓴다
//   - x402 사용료 결제            → 자리만 두었다. scripts/x402-server.mjs가 상대편이다
//   - 운영 키 KMS                 → 환경변수에서 읽는다
//   - DEEP 잔고 모니터링          → 떨어지면 거래가 멈춘다
// -----------------------------------------------------------------------------

import { createServer } from 'node:http';

import { SuiGrpcClient, GrpcWebFetchTransport } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { isValidSuiAddress, normalizeSuiAddress } from '@mysten/sui/utils';

import { fromMintPush } from '../sources/agent/adapters/mint.js';
import { normalizeSignal } from '../sources/agent/signal.js';
import {
    assertPairMatches,
    buildExecuteTransaction,
    explainFailure,
    pairSymbolOf,
} from '../sources/agent/executor.js';
import {
    SIGNATURE_HEADER,
    assertUsableSecret,
    verifyRequestSignature,
} from '../sources/agent/auth.js';

const PORT = Number(process.env.AGENT_PORT ?? 8500);
const MAX_BODY_BYTES = 16 * 1024;

// FE(:3000)가 실행기(:8500)를 부르는 것은 교차 출처다. 허용 헤더가 없으면
// 브라우저가 응답을 버리고 "Failed to fetch"만 남긴다.
// 읽기 전용 상태 정보이고 데모 환경이라 넓게 연다. 운영에서는 좁혀야 한다.
const ALLOWED_ORIGIN = process.env.AGENT_ALLOWED_ORIGIN ?? '*';

// 서명 헤더는 표준 헤더가 아니라 preflight에서 명시적으로 허용해야 한다.
const ALLOWED_HEADERS = `content-type, ${SIGNATURE_HEADER}`;

// ---------------------------------------------------------------- 설정 --------

function requireEnv(name) {
    const value = process.env[name];
    if (typeof value !== 'string' || value.trim().length === 0) {
        throw new Error(`Missing required environment variable: ${name}`);
    }
    return value.trim();
}

function requireAddressEnv(name) {
    const normalized = normalizeSuiAddress(requireEnv(name));
    if (!isValidSuiAddress(normalized)) {
        throw new Error(`${name} must contain a valid Sui address.`);
    }
    return normalized;
}

function requireCoinTypeEnv(name) {
    const value = requireEnv(name);
    if (!value.includes('::')) {
        throw new Error(`${name} must contain a fully qualified Move coin type.`);
    }
    return value;
}

function requireIntEnv(name, fallback) {
    const raw = process.env[name];
    if ((raw === undefined || raw === '') && fallback !== undefined) return fallback;

    const parsed = Number(requireEnv(name));
    if (!Number.isInteger(parsed) || parsed < 0) {
        throw new Error(`${name} must be a non-negative integer.`);
    }
    return parsed;
}

function loadConfig() {
    const config = {
        packageId: requireAddressEnv('AGENT_PACKAGE_ID'),
        vaultId: requireAddressEnv('AGENT_VAULT_ID'),
        poolId: requireAddressEnv('AGENT_POOL_ID'),

        fiatType: requireCoinTypeEnv('AGENT_FIAT_TYPE'),
        cryptoType: requireCoinTypeEnv('AGENT_CRYPTO_TYPE'),
        deepType: requireCoinTypeEnv('AGENT_DEEP_TYPE'),

        // 코인마다 decimals가 다르다. 틀리면 price_e9이 어긋나 편차 가드에 걸린다.
        fiatDecimals: requireIntEnv('AGENT_FIAT_DECIMALS'),
        cryptoDecimals: requireIntEnv('AGENT_CRYPTO_DECIMALS'),

        // whitelisted Pool은 DEEP을 넣으면 전액 소모된다. 반드시 0을 넣어야 하고,
        // 그 외 Pool은 반드시 0보다 커야 한다. 틀려도 자금 손실은 없다 —
        // 컨트랙트가 E_DEEP_FEE_NOT_ACCEPTED(6) / E_DEEP_FEE_REQUIRED(5)로 끊는다.
        poolWhitelisted: requireEnv('AGENT_POOL_WHITELISTED') === 'true',
        deepPerTrade: BigInt(requireIntEnv('AGENT_DEEP_PER_TRADE', 200_000)),

        // Vault의 max_trade_amount가 상한, Pool의 min_size가 하한이다.
        buyFiatAmount: BigInt(requireIntEnv('AGENT_BUY_FIAT_AMOUNT')),
        sellCryptoAmount: BigInt(requireIntEnv('AGENT_SELL_CRYPTO_AMOUNT')),

        // 위험도는 Agora가 매기는 값인데 느린 시계가 아직 없다. 그때까지 고정값을 쓴다.
        // Providing Agent가 보낸 값은 쓰지 않는다 — 자기 물건 등급을 자기가 매기는 셈이라서다.
        riskScoreBps: BigInt(requireIntEnv('AGENT_RISK_SCORE_BPS', 5_000)),

        // Providing Agent가 보내야 할 페어 기호. 지정하지 않으면 코인 타입에서
        // 유도한다(Pool<CryptoT, FiatT> -> "CRYPTO/FIAT"). 티커가 Move 타입 이름과
        // 다른 코인을 붙일 때만 덮으면 된다.
        symbol: process.env.AGENT_SYMBOL?.trim() || undefined,

        // push 방식에서는 이것이 유일한 신원 확인 수단이다. 없으면 기동하지 않는다.
        sharedSecret: assertUsableSecret(requireEnv('AGENT_SHARED_SECRET')),

        graphqlUrl:
            process.env.AGENT_GRAPHQL_URL ?? 'https://graphql.testnet.sui.io/graphql',
        slippageBps: BigInt(requireIntEnv('AGENT_SLIPPAGE_BPS', 300)),
        signalTtlMs: requireIntEnv('AGENT_SIGNAL_TTL_MS', 300_000),
    };

    if (!config.poolWhitelisted) {
        if (config.deepPerTrade === 0n) {
            throw new Error(
                'AGENT_DEEP_PER_TRADE must be greater than zero on a non-whitelisted pool.'
            );
        }
        // 수수료로 쪼갤 원본 DEEP 코인. 통째로 넘기지 않고 매번 필요한 만큼만 split한다.
        config.deepCoinId = requireAddressEnv('AGENT_DEEP_COIN_ID');
    }

    return config;
}

// ------------------------------------------------------------ 체인 시각 -------

/* 온체인 Clock을 읽는다.
 *
 * 체인 시각은 체크포인트 기준이라 로컬 벽시계보다 1~2초 뒤처진다(측정값 ~1.7초).
 * Agent가 Date.now()로 찍은 시각을 그대로 넘기면 E_SIGNAL_FROM_FUTURE(2)로 거부된다.
 * 공용 fullnode의 JSON-RPC가 폐기돼 GraphQL로 읽는다 (PROGRESS §9).
 */
async function fetchChainNowMs(graphqlUrl) {
    const response = await fetch(graphqlUrl, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({
            query: 'query { object(address: "0x6") { asMoveObject { contents { json } } } }',
        }),
    });

    const body = await response.json();
    const timestamp = Number(
        body?.data?.object?.asMoveObject?.contents?.json?.timestamp_ms
    );

    if (!Number.isFinite(timestamp) || timestamp <= 0) {
        throw new Error('온체인 Clock을 읽지 못했습니다.');
    }

    return timestamp;
}

// ---------------------------------------------------------- 상태 기록 --------

/* Providing Agent별 최근 활동. FE의 "Agora Agent" 화면이 읽어간다.
   ⚠️ 프로세스 메모리다 — 재시작하면 사라진다. 운영에서는 §8-7 실행 레코드 DB로 옮긴다. */
const agentActivity = new Map();

function recordActivity(agentId, outcome, detail) {
    const id = agentId || 'unknown';
    const prev = agentActivity.get(id) ?? {
        agentId: id, executed: 0, blocked: 0, rejected: 0,
    };

    prev[outcome] += 1;
    prev.lastSeenMs = Date.now();
    prev.lastOutcome = outcome;
    prev.lastDetail = detail;
    agentActivity.set(id, prev);
}

// ------------------------------------------------------------ 서버 ------------

const config = loadConfig();
const keypair = Ed25519Keypair.fromSecretKey(requireEnv('AGENT_OPERATOR_SECRET_KEY'));
const operator = keypair.getPublicKey().toSuiAddress();

const client = new SuiGrpcClient({
    network: 'testnet',
    transport: new GrpcWebFetchTransport({
        baseUrl: process.env.AGENT_RPC_URL ?? 'https://fullnode.testnet.sui.io:443',
    }),
});

/* 본문을 **바이트 그대로** 읽는다.
   HMAC은 원본 바이트에 걸리므로 파싱했다 다시 직렬화하면 서명이 어긋난다. */
function readRawBody(request) {
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
        request.on('end', () => resolve(Buffer.concat(chunks)));
    });
}

function parseJsonBody(rawBody) {
    try {
        return JSON.parse(rawBody.toString('utf8'));
    } catch {
        throw new Error('body must be valid JSON.');
    }
}

function send(response, status, body) {
    const payload = JSON.stringify(body);
    response.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
        'access-control-allow-origin': ALLOWED_ORIGIN,
    });
    response.end(payload);
}

/* SDK 응답에서 digest를 꺼낸다.
 *
 * gRPC 응답은 태그 유니온이라 digest가 한 겹 안에 있다:
 *   { $kind: 'Transaction',       Transaction:       { digest, status, … } }
 *   { $kind: 'FailedTransaction', FailedTransaction: { digest, status, … } }
 * 최상위 result.digest는 항상 undefined다 — 여기서 한 번 틀렸다.
 */
function digestOf(result) {
    return result?.Transaction?.digest ?? result?.FailedTransaction?.digest ?? result?.digest;
}

/* 정규화된 시그널 하나를 온체인에 태운다.
   어댑터가 무엇이든 여기서부터는 동일하다. */
async function executeSignal(signal, chainNowMs) {
    const result = await client.signAndExecuteTransaction({
        transaction: buildExecuteTransaction({ config, signal, chainNowMs }),
        signer: keypair,
    });

    // 온체인 abort는 지금 SDK에서 예외로 올라오지만, 응답 자체에도 실패 표시가 있다.
    // 실패를 "체결됨"으로 보고하는 것이 가장 나쁜 고장이라 여기서도 한 번 막는다.
    if (result?.$kind === 'FailedTransaction' || result?.Transaction?.status?.success === false) {
        const detail = result?.FailedTransaction?.status?.error?.message
            ?? result?.Transaction?.status?.error?.message
            ?? 'transaction failed on chain.';
        throw new Error(detail);
    }

    const digest = digestOf(result);
    if (!digest) throw new Error('체결됐지만 digest를 읽지 못했습니다 — SDK 응답 형태 확인 필요.');

    return digest;
}

const server = createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host ?? 'localhost'}`);

    // 브라우저는 교차 출처 요청 전에 preflight를 보낸다. 막히면 본 요청이 아예 안 온다.
    if (request.method === 'OPTIONS') {
        response.writeHead(204, {
            'access-control-allow-origin': ALLOWED_ORIGIN,
            'access-control-allow-methods': 'GET, POST, OPTIONS',
            'access-control-allow-headers': ALLOWED_HEADERS,
            'access-control-max-age': '86400',
        });
        return response.end();
    }

    // FE가 "지금 어떤 Agent에게서 시그널을 받고 있는지" 확인하는 창구.
    if (url.pathname === '/status' && request.method === 'GET') {
        return send(response, 200, {
            operator,
            vaultId: config.vaultId,
            poolId: config.poolId,
            pair: {
                // Providing Agent는 이 기호로 보내야 한다. 다르면 400으로 끊는다.
                symbol: pairSymbolOf(config),
                fiat: config.fiatType,
                crypto: config.cryptoType,
                fiatDecimals: config.fiatDecimals,
                cryptoDecimals: config.cryptoDecimals,
            },
            // 아직 없는 단계를 화면이 "구현됨"으로 오해하지 않도록 명시한다.
            verification: 'not-implemented',
            riskScore: 'fixed-placeholder',
            x402: 'not-implemented',
            auth: 'hmac-sha256',
            agents: [...agentActivity.values()],
        });
    }

    if (url.pathname !== '/signal') return send(response, 404, { error: 'Not Found' });
    if (request.method !== 'POST') return send(response, 405, { error: 'Method Not Allowed' });

    // 서명 확인이 먼저다. 통과하지 못한 요청에 체인 조회 비용을 쓰지 않는다.
    let rawBody;
    try {
        rawBody = await readRawBody(request);
    } catch (error) {
        return send(response, 413, { error: 'Payload Too Large', reason: error.message });
    }

    if (!verifyRequestSignature({
        secret: config.sharedSecret,
        rawBody,
        header: request.headers[SIGNATURE_HEADER],
    })) {
        // 무엇이 틀렸는지는 알려주지 않는다. 맞히는 데 도움이 될 뿐이다.
        console.warn('[unauthorized] 서명이 없거나 일치하지 않습니다.');
        return send(response, 401, { error: 'Unauthorized' });
    }

    let chainNowMs;
    try {
        chainNowMs = await fetchChainNowMs(config.graphqlUrl);
    } catch (error) {
        // 체인 시각을 모르면 안전한 timestamp를 만들 수 없다. 추측하지 않는다.
        console.warn(`[error] ${error.message}`);
        return send(response, 502, { error: 'Bad Gateway', reason: error.message });
    }

    let signal;
    let body;

    try {
        body = parseJsonBody(rawBody);
        // 어댑터 경계. Agent가 늘어나면 여기서 갈라진다.
        signal = normalizeSignal(fromMintPush(body), {
            chainNowMs,
            signalTtlMs: config.signalTtlMs,
        });
        // 이 실행기는 Pool 하나에 고정돼 있다. 다른 페어의 price를 그대로 태우면
        // 온체인 편차 가드에 걸리는데, 그때는 이미 가스를 쓴 뒤다.
        assertPairMatches(signal, config);
    } catch (error) {
        console.warn(`[reject] ${error.message}`);
        recordActivity(body?.agent_id ?? body?.agentId, 'rejected', error.message);
        return send(response, 400, { error: 'Bad Signal', reason: error.message });
    }

    // TODO(PROGRESS §8-5): 여기서 Trust Score로 시그널을 검증한다.
    // TODO(PROGRESS §8-7): 여기서 x402로 시그널 사용료를 결제한다.

    try {
        const digest = await executeSignal(signal, chainNowMs);
        console.log(`[exec] ${signal.side} ${signal.signalId} -> ${digest}`);
        recordActivity(signal.agentId, 'executed', digest);

        return send(response, 200, {
            status: 'executed',
            signalId: signal.signalId,
            digest,
        });
    } catch (error) {
        // 온체인 거부는 정상 동작이다 — 가드레일이 일한 것이다.
        // 자금은 전액 롤백되고, 체결 0건이면 시그널도 소진되지 않아 재시도할 수 있다.
        const reason = explainFailure(error.message) ?? error.message;
        console.warn(`[blocked] ${signal.side} ${signal.signalId}: ${reason}`);
        recordActivity(signal.agentId, 'blocked', reason);

        return send(response, 422, {
            status: 'blocked',
            signalId: signal.signalId,
            reason,
        });
    }
});

server.listen(PORT, () => {
    console.log(`AgoraAgent executor listening on :${PORT}/signal`);
    console.log(`  operator ${operator}`);
    console.log(`  vault    ${config.vaultId}`);
    console.log(`  pool     ${config.poolId}${config.poolWhitelisted ? ' (whitelisted — DEEP 미사용)' : ''}`);
    console.log(`  pair     ${pairSymbolOf(config)} — price는 ${config.fiatType.split('::').pop()} per ${config.cryptoType.split('::').pop()}`);
    console.log(`  decimals ${config.fiatDecimals}(fiat) / ${config.cryptoDecimals}(crypto)`);
    console.log(`  인증     HMAC-SHA256 (${SIGNATURE_HEADER})`);
    console.log(`  위험도    고정 ${config.riskScoreBps}bps (느린 시계 미구현)`);
});
