// -----------------------------------------------------------------------------
// AgoraAgent 최소 실행기 (1차 데모용).
//
//   cd sui-contract && node scripts/agent-executor.mjs
//
// RFC §2의 "빠른 시계" 자리다. Providing Agent(MINT, AXIOM …)가 시그널만 뱉으면
// 여기서 온체인 실행에 필요한 것을 전부 처리한다:
//   가격 스케일 변환 · 최소 수령량 계산 · DEEP 분리 · PTB 조립 · 서명 · 거부 해석
//
// Providing Agent는 Sui도 DeepBook도 몰라도 된다. JSON 한 건만 POST하면 된다.
//
//   POST /signal
//   { "signalId":"mint-0001", "agentId":"mint", "side":"BUY",
//     "price":0.0272, "riskScoreBps":1200, "timestampMs":1787714741167 }
//
// ⚠️ 1차 데모 범위다. 아직 없는 것 (PROGRESS §8):
//   - 시그널 검증 / Trust Score   → 지금은 형식 검사만 하고 전부 통과시킨다
//   - x402 사용료 결제            → 자리만 두었다. scripts/x402-server.mjs가 상대편이다
//   - 운영 키 KMS                 → 환경변수에서 읽는다
//   - DEEP 잔고 모니터링          → 떨어지면 거래가 멈춘다
// -----------------------------------------------------------------------------

import { createServer } from 'node:http';

import { SuiGrpcClient, GrpcWebFetchTransport } from '@mysten/sui/grpc';
import { Ed25519Keypair } from '@mysten/sui/keypairs/ed25519';
import { Transaction } from '@mysten/sui/transactions';
import { isValidSuiAddress, normalizeSuiAddress } from '@mysten/sui/utils';

const PORT = Number(process.env.AGENT_PORT ?? 8500);
const CLOCK_OBJECT_ID = '0x6';
const MAX_U64 = (1n << 64n) - 1n;
const MAX_BODY_BYTES = 16 * 1024;

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

        // 코인마다 decimals가 다르다. 이 값을 틀리면 signal_price_e9이 1000배씩
        // 어긋나 온체인 가격 편차 가드에 걸린다. 실제로 겪은 함정이다.
        fiatDecimals: requireIntEnv('AGENT_FIAT_DECIMALS'),
        cryptoDecimals: requireIntEnv('AGENT_CRYPTO_DECIMALS'),

        // whitelisted Pool은 DEEP을 넣으면 전액 소모된다. 그래서 반드시 0을 넣어야 하고,
        // 그 외 Pool은 반드시 0보다 커야 한다. 값을 틀려도 자금 손실은 없다 —
        // 컨트랙트가 E_DEEP_FEE_NOT_ACCEPTED(6) / E_DEEP_FEE_REQUIRED(5)로 끊는다.
        poolWhitelisted: requireEnv('AGENT_POOL_WHITELISTED') === 'true',
        deepPerTrade: BigInt(requireIntEnv('AGENT_DEEP_PER_TRADE', 200_000)),

        // 1회 주문 크기. Vault의 max_trade_amount가 상한이고, Pool의 min_size가 하한이다.
        // min_size보다 작게 잡으면 한도 가드가 아니라 E_BELOW_MIN_SIZE가 먼저 나온다.
        buyFiatAmount: BigInt(requireIntEnv('AGENT_BUY_FIAT_AMOUNT')),
        sellCryptoAmount: BigInt(requireIntEnv('AGENT_SELL_CRYPTO_AMOUNT')),

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

// ------------------------------------------------------- 가격 스케일 변환 -------

/* 사람이 읽는 가격(fiat per crypto)을 온체인 price_e9으로 바꾼다.
 *
 * 컨트랙트는 quote_price_e9 = fiat_amount * 1e9 / base_out 으로 계산한다.
 * 여기서 fiat_amount와 base_out은 각 코인의 **최소단위**다. 따라서
 *   price_e9 = P * 10^fiatDecimals / 10^cryptoDecimals * 1e9
 * 예) SUI(9) per DEEP(6), P=0.0272 -> 0.0272 * 1e9 / 1e6 * 1e9 = 2.72e10
 *
 * 부동소수 오차를 피하려고 마지막에 한 번만 반올림한다.
 */
function toPriceE9(humanPrice, fiatDecimals, cryptoDecimals) {
    if (!Number.isFinite(humanPrice) || humanPrice <= 0) {
        throw new Error('price must be a positive number.');
    }

    const scaled =
        humanPrice * 10 ** (fiatDecimals - cryptoDecimals) * 1e9;

    if (!Number.isFinite(scaled) || scaled < 1) {
        throw new Error('price is too small to express as price_e9.');
    }

    const result = BigInt(Math.round(scaled));
    if (result > MAX_U64) throw new Error('price_e9 does not fit in u64.');

    return result;
}

/** 슬리피지를 반영한 최소 수령량. 0으로 두면 샌드위치 공격 경로가 된다. */
function applySlippage(expected, slippageBps) {
    return (expected * (10_000n - slippageBps)) / 10_000n;
}

// ------------------------------------------------------------ 체인 시각 -------

/* 온체인 Clock을 읽는다.
 *
 * 체인 시각은 체크포인트 기준이라 로컬 벽시계보다 1~2초 뒤처진다(측정값 ~1.7초).
 * Providing Agent가 Date.now()로 찍은 시각을 그대로 넘기면 컨트랙트가
 * E_SIGNAL_FROM_FUTURE(2)로 거부한다. 그래서 여기서 체인 시각을 기준으로 삼는다.
 *
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
    const json = body?.data?.object?.asMoveObject?.contents?.json;
    const timestamp = Number(json?.timestamp_ms);

    if (!Number.isFinite(timestamp) || timestamp <= 0) {
        throw new Error('온체인 Clock을 읽지 못했습니다.');
    }

    return timestamp;
}

// ---------------------------------------------------------- 시그널 검증 --------

const SIDES = new Set(['BUY', 'SELL']);

function parseSignal(body, config, chainNowMs) {
    if (typeof body !== 'object' || body === null) {
        throw new Error('body must be a JSON object.');
    }

    const { signalId, side, price, riskScoreBps, timestampMs } = body;

    if (typeof signalId !== 'string' || signalId.trim().length === 0) {
        throw new Error('signalId is required.');
    }
    // 온체인에서 vector<u8>로 저장되고 Vault별로 영구 차단된다.
    if (Buffer.byteLength(signalId, 'utf8') > 64) {
        throw new Error('signalId must be at most 64 bytes.');
    }
    if (typeof side !== 'string' || !SIDES.has(side)) {
        throw new Error('side must be "BUY" or "SELL".');
    }
    if (typeof riskScoreBps !== 'number' || !Number.isInteger(riskScoreBps)
        || riskScoreBps < 0 || riskScoreBps > 10_000) {
        throw new Error('riskScoreBps must be an integer between 0 and 10000.');
    }
    if (typeof timestampMs !== 'number' || !Number.isInteger(timestampMs)) {
        throw new Error('timestampMs must be an integer (epoch ms).');
    }
    // 오래된 시그널은 어차피 온체인에서 E_SIGNAL_EXPIRED로 거부된다.
    // 가스를 버리기 전에 여기서 끊는다.
    if (chainNowMs - timestampMs > config.signalTtlMs) {
        throw new Error(
            `signal is older than ${config.signalTtlMs}ms and would be rejected on-chain.`
        );
    }

    // 체인 시각보다 미래면 E_SIGNAL_FROM_FUTURE로 거부된다. Providing Agent가
    // 자기 벽시계로 찍은 값이 체인보다 앞서는 것은 정상이므로, 거부하는 대신
    // 체인 시각으로 당겨 준다. 뒤로 당기는 것은 TTL 검사를 더 엄격하게 만들 뿐이라 안전하다.
    const effectiveTimestampMs = Math.min(timestampMs, chainNowMs);

    return {
        signalId,
        side,
        priceE9: toPriceE9(price, config.fiatDecimals, config.cryptoDecimals),
        riskScoreBps: BigInt(riskScoreBps),
        timestampMs: BigInt(effectiveTimestampMs),
    };
}

// ------------------------------------------------------------ 실행 ------------

/* signalId 문자열을 온체인 vector<u8>로 바꾼다.
   Vault마다 별도 Table이라 같은 시그널을 여러 Vault에 한 번씩 쓸 수 있다
   (팬아웃 설계). 같은 Vault에 두 번은 영구 차단된다. */
function signalIdBytes(signalId) {
    return Array.from(Buffer.from(signalId, 'utf8'));
}

function buildExecuteTransaction({ config, signal, nowMs }) {
    const tx = new Transaction();
    const typeArguments = [config.fiatType, config.cryptoType];

    // whitelisted Pool에는 잔액 0인 Coin<DEEP>을 넣어야 한다. 넣으면 전액 소모된다.
    const deepFee = config.poolWhitelisted
        ? tx.moveCall({
            target: '0x2::coin::zero',
            typeArguments: [config.deepType],
        })
        : tx.splitCoins(tx.object(config.deepCoinId), [config.deepPerTrade])[0];

    const isBuy = signal.side === 'BUY';

    // 최소 수령량은 시그널 가격 기준 기대치에서 슬리피지를 뺀 값이다.
    // SELL의 min_fiat_output은 수수료를 뗀 **순액** 기준이다 — 컨트랙트가
    // gross_min_output()으로 알아서 올려 잡으므로 여기서는 순액을 넣으면 된다.
    const [inputAmount, expectedOutput] = isBuy
        ? [
            config.buyFiatAmount,
            (config.buyFiatAmount * 1_000_000_000n) / signal.priceE9,
        ]
        : [
            config.sellCryptoAmount,
            (config.sellCryptoAmount * signal.priceE9) / 1_000_000_000n,
        ];

    tx.moveCall({
        target: `${config.packageId}::deepbook_executor::${isBuy ? 'execute_buy' : 'execute_sell'}`,
        typeArguments,
        arguments: [
            tx.object(config.vaultId),
            tx.object(config.poolId),
            deepFee,
            tx.pure.u64(inputAmount),
            tx.pure.u64(applySlippage(expectedOutput, config.slippageBps)),
            tx.pure.vector('u8', signalIdBytes(signal.signalId)),
            tx.pure.u64(signal.timestampMs),
            tx.pure.u64(signal.priceE9),
            tx.pure.u64(signal.riskScoreBps),
            tx.pure.u64(BigInt(nowMs + 60_000)),
            tx.object(CLOCK_OBJECT_ID),
        ],
    });

    return tx;
}

/* 온체인 abort를 사람이 읽을 수 있는 이유로 바꾼다.
   운영 중에 코드만 보고 원인을 찾는 시간을 줄이려는 것이다. */
const ABORT_REASONS = {
    'deepbook_executor::1': '실행 기한 만료 (deadline_ms 초과)',
    'deepbook_executor::2': 'Pool 호가 없음 — 유동성 부족',
    'deepbook_executor::3': '주문이 Pool 최소 크기 미달',
    'deepbook_executor::4': '체결 0건 — 시그널은 소진되지 않았다',
    'deepbook_executor::5': 'DEEP 수수료 필요 (비-whitelisted Pool)',
    'deepbook_executor::6': 'whitelisted Pool에는 DEEP을 넣으면 안 된다',
    'investment_vault::3': '시그널이 너무 오래됨 (E_SIGNAL_EXPIRED)',
    'investment_vault::17': '이미 사용된 signalId (E_DUPLICATE_SIGNAL)',
    'vault_policy::5': '시그널 가격이 실제 호가와 너무 벌어짐 (편차 한도 초과)',
    'investment_vault::5': '1회 거래 한도 초과 (E_TRADE_LIMIT_EXCEEDED)',
    'investment_vault::6': 'epoch 누적 거래 한도 초과 — 다음 epoch까지 대기',
    'investment_vault::7': 'Vault 잔액 부족 (E_INSUFFICIENT_BALANCE)',
};

function explainFailure(message) {
    // gRPC와 CLI가 서로 다른 모양으로 abort를 알려준다. 둘 다 받는다.
    //   gRPC: abort code: 6, in '0x…::investment_vault::assert_epoch_…' (instruction 12)
    //   CLI:  MoveLocation { … name: Identifier("investment_vault") … }, 6)
    const grpc = /abort code: (\d+), in '[^']*::([^:']+)::([^:']+)'/.exec(message);
    if (grpc) {
        const [, code, module, fn] = grpc;
        // gRPC는 함수 이름까지 알려준다. assert_epoch_fiat_buy_amount_allowed 처럼
        // 이름 자체가 원인을 설명하므로 표에 없으면 그대로 보여준다.
        return ABORT_REASONS[`${module}::${code}`] ?? `${fn} (abort ${code})`;
    }

    const cli = /name: Identifier\("([^"]+)"\).*?\}, (\d+)\)/s.exec(message);
    if (cli) {
        const [, module, code] = cli;
        return ABORT_REASONS[`${module}::${code}`] ?? `${module} abort code ${code}`;
    }

    return null;
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
            try {
                resolve(JSON.parse(Buffer.concat(chunks).toString('utf8')));
            } catch {
                reject(new Error('body must be valid JSON.'));
            }
        });
    });
}

/* FE(:3000)가 실행기(:8500)를 부르는 것은 교차 출처다. 허용 헤더가 없으면
   브라우저가 응답을 버리고 "Failed to fetch"만 남긴다.
   읽기 전용 상태 정보이고 데모 환경이라 출처를 넓게 연다. 운영에서는
   AGENT_ALLOWED_ORIGIN으로 좁혀야 한다. */
const ALLOWED_ORIGIN = process.env.AGENT_ALLOWED_ORIGIN ?? '*';

function send(response, status, body) {
    const payload = JSON.stringify(body);
    response.writeHead(status, {
        'content-type': 'application/json',
        'content-length': Buffer.byteLength(payload),
        'access-control-allow-origin': ALLOWED_ORIGIN,
    });
    response.end(payload);
}

const server = createServer(async (request, response) => {
    const url = new URL(request.url, `http://${request.headers.host ?? 'localhost'}`);

    // 브라우저는 교차 출처 요청 전에 preflight를 보낸다. 막히면 본 요청이 아예 안 온다.
    if (request.method === 'OPTIONS') {
        response.writeHead(204, {
            'access-control-allow-origin': ALLOWED_ORIGIN,
            'access-control-allow-methods': 'GET, POST, OPTIONS',
            'access-control-allow-headers': 'content-type',
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
                fiat: config.fiatType,
                crypto: config.cryptoType,
                fiatDecimals: config.fiatDecimals,
                cryptoDecimals: config.cryptoDecimals,
            },
            // 검증(Trust Score)과 x402 결제는 아직 자리만 있다. 화면이 이를
            // "구현됨"으로 오해하지 않도록 상태를 명시한다.
            verification: 'not-implemented',
            x402: 'not-implemented',
            agents: [...agentActivity.values()],
        });
    }

    if (url.pathname !== '/signal') return send(response, 404, { error: 'Not Found' });
    if (request.method !== 'POST') return send(response, 405, { error: 'Method Not Allowed' });

    let chainNowMs;
    try {
        chainNowMs = await fetchChainNowMs(config.graphqlUrl);
    } catch (error) {
        // 체인 시각을 모르면 안전한 timestamp를 만들 수 없다. 추측하지 않는다.
        console.warn(`[error] ${error.message}`);
        return send(response, 502, { error: 'Bad Gateway', reason: error.message });
    }

    let signal;
    let rawBody;

    try {
        rawBody = await readBody(request);
        signal = parseSignal(rawBody, config, chainNowMs);
    } catch (error) {
        // 시그널 자체가 잘못됐다. 체인을 건드리기 전에 끊는다.
        console.warn(`[reject] ${error.message}`);
        recordActivity(rawBody?.agentId, 'rejected', error.message);
        return send(response, 400, { error: 'Bad Signal', reason: error.message });
    }

    // TODO(PROGRESS §8-5): 여기서 Trust Score로 시그널을 검증한다.
    // TODO(PROGRESS §8-7): 여기서 x402로 시그널 사용료를 결제한다.

    try {
        const result = await client.signAndExecuteTransaction({
            transaction: buildExecuteTransaction({ config, signal, nowMs: chainNowMs }),
            signer: keypair,
        });

        const digest = result.digest ?? result.transaction?.digest;
        console.log(`[exec] ${signal.side} ${signal.signalId} -> ${digest}`);
        recordActivity(rawBody?.agentId, 'executed', digest);
        return send(response, 200, {
            status: 'executed',
            signalId: signal.signalId,
            digest: result.digest ?? result.transaction?.digest,
        });
    } catch (error) {
        // 온체인 거부는 정상 동작이다 — 가드레일이 일한 것이다.
        // 자금은 전액 롤백되고, 체결 0건이면 시그널도 소진되지 않는다.
        const reason = explainFailure(error.message) ?? error.message;
        console.warn(`[blocked] ${signal.side} ${signal.signalId}: ${reason}`);
        recordActivity(rawBody?.agentId, 'blocked', reason);
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
    console.log(`  pair     ${config.fiatType.split('::').pop()}(${config.fiatDecimals}) / ${config.cryptoType.split('::').pop()}(${config.cryptoDecimals})`);
});
