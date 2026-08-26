// -----------------------------------------------------------------------------
// 이 파일은 전체가 Claude가 작성한 부분입니다 (진웅님이 직접 적은 코드가 아님).
//
// 실행: cd sui-contract && npm run test:x402
//
// 네트워크를 타지 않는 순수 로직만 검사한다. fetchPaymentReceipt(GraphQL 조회)는
// 가짜 reader를 주입해서 테스트한다.
// -----------------------------------------------------------------------------

import test from 'node:test';
import assert from 'node:assert/strict';

import {
    createPaymentChallenge,
    assertReceiptMatchesChallenge,
    createPaymentDigestStore,
    createChallengeStore,
    verifySignalPayment,
} from '../sources/x402/payment_challenge.js';

import { fetchPaymentReceipt } from '../sources/x402/payment_receipt_reader.js';
import { createSignalHandler } from '../sources/x402/signal_handler.js';

const NOW = 1786632000000;
const PACKAGE_ID =
    '0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26';

const config = {
    packageId: PACKAGE_ID,
    agoraAgentAddress:
        '0x0000000000000000000000000000000000000000000000000000000000005678',
    providerId:
        '0x000000000000000000000000000000000000000000000000000000000000abcd',
    paymentReceiver:
        '0x0000000000000000000000000000000000000000000000000000000000001111',
    treasuryAddress:
        '0x0000000000000000000000000000000000000000000000000000000000002222',
    platformFeeBps: 2000n,
    paymentToken:
        '0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI',
    paymentAmount: 1000000n,
};

// 1000000의 2000bps = 200000. payment_splitter.move의 계산과 같은 값이어야 한다.
const EXPECTED_FEE = '200000';

const validReceipt = (overrides = {}) => ({
    type: `${PACKAGE_ID}::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>`,
    payer: '0x5678',
    payee: '0x1111',
    treasury: '0x2222',
    signal_provider_id: '0xabcd',
    amount: '1000000',
    platform_fee_amount: EXPECTED_FEE,
    timestamp: String(NOW + 60000),
    ...overrides,
});

// --- createPaymentChallenge --------------------------------------------------

test('challenge는 발급 시각과 5분 뒤 만료 시각을 문자열로 담는다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.equal(challenge.error, 'Payment Required');
    assert.equal(challenge.issuedAtMs, '1786632000000');
    assert.equal(challenge.expiresAtMs, '1786632300000');
    assert.equal(challenge.price, '1000000');
    assert.equal(challenge.signalProviderId, config.providerId);
    assert.match(challenge.requestId, /^[0-9a-f-]{36}$/);
});

test('challenge는 PTB 구성에 필요한 treasury와 platformFeeBps를 함께 준다', () => {
    // 이 둘이 빠지면 클라이언트는 pay_signal_provider_usage_fee를 호출할 수 없다.
    // 그 함수의 필수 인자이기 때문이다.
    const challenge = createPaymentChallenge(config, NOW);

    assert.equal(challenge.treasury, config.treasuryAddress);
    assert.equal(challenge.platformFeeBps, '2000');
    assert.equal(challenge.payee, config.paymentReceiver);
    assert.equal(challenge.token, config.paymentToken);
});

// --- assertReceiptMatchesChallenge -------------------------------------------

test('정상 영수증은 통과한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.doesNotThrow(() =>
        assertReceiptMatchesChallenge(validReceipt(), challenge, config, NOW + 60000),
    );
});

test('만료된 challenge는 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () => assertReceiptMatchesChallenge(validReceipt(), challenge, config, NOW + 999999),
        /Challenge has expired/,
    );
});

test('다른 Package가 찍은 이벤트는 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);
    const receipt = validReceipt({
        type: '0xdead::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>',
    });

    assert.throws(
        () => assertReceiptMatchesChallenge(receipt, challenge, config, NOW + 60000),
        /Payment event type mismatch/,
    );
});

test('다른 코인으로 낸 결제는 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);
    const receipt = validReceipt({
        type: `${PACKAGE_ID}::payment_splitter::SignalPaymentReceiptEvent<0xbeef::usdc::USDC>`,
    });

    assert.throws(
        () => assertReceiptMatchesChallenge(receipt, challenge, config, NOW + 60000),
        /Payment event type mismatch/,
    );
});

test('남이 낸 결제는 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ payer: '0x9999' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /Payer is not the Agora agent/,
    );
});

test('수령자나 Provider가 다르면 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ payee: '0x2222' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /Payment receiver mismatch/,
    );

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ signal_provider_id: '0xbeef' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /Signal provider mismatch/,
    );
});

test('금액이 모자라면 거부하고, 더 냈으면 통과한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ amount: '999999' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /below the required price/,
    );

    assert.doesNotThrow(() =>
        assertReceiptMatchesChallenge(
            validReceipt({ amount: '2000000' }),
            challenge,
            config,
            NOW + 60000,
        ),
    );
});

test('Treasury를 자기 주소로 바꾼 결제는 거부한다', () => {
    // payment_splitter는 treasury_address를 호출자에게서 그대로 받는다. 서버가
    // 대조하지 않으면 payer가 Provider 몫만 채우고 플랫폼 수수료를 가로챌 수 있다.
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ treasury: '0x9999' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /Treasury address mismatch/,
    );
});

test('플랫폼 수수료를 덜 낸 결제는 거부하고, 더 낸 것은 통과한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ platform_fee_amount: '199999' }),
                challenge,
                config,
                NOW + 60000,
            ),
        /Platform fee is below the required share/,
    );

    // 총액을 더 냈다면 수수료도 그만큼 커진다. 하한선만 보므로 통과해야 한다.
    assert.doesNotThrow(() =>
        assertReceiptMatchesChallenge(
            validReceipt({ amount: '2000000', platform_fee_amount: '400000' }),
            challenge,
            config,
            NOW + 60000,
        ),
    );
});

test('challenge 발급 전의 옛날 결제는 거부한다', () => {
    const challenge = createPaymentChallenge(config, NOW);

    assert.throws(
        () =>
            assertReceiptMatchesChallenge(
                validReceipt({ timestamp: String(NOW - 1) }),
                challenge,
                config,
                NOW + 60000,
            ),
        /predates the challenge/,
    );
});

// --- createPaymentDigestStore ------------------------------------------------

test('같은 digest는 두 번 쓸 수 없다', () => {
    const store = createPaymentDigestStore();

    store.consume('0xAAA', NOW);

    assert.throws(() => store.consume('0xAAA', NOW + 1000), /already been used/);
    assert.doesNotThrow(() => store.consume('0xBBB', NOW + 1000));
});

test('빈 digest는 거부한다', () => {
    const store = createPaymentDigestStore();

    assert.throws(() => store.consume('   ', NOW), /digest is missing/);
    assert.throws(() => store.consume(undefined, NOW), /digest is missing/);
});

test('보관 기간이 지나면 청소된다', () => {
    const store = createPaymentDigestStore();

    store.consume('0xAAA', NOW);

    assert.doesNotThrow(() => store.consume('0xAAA', NOW + 5 * 60 * 1000));
});

// --- createChallengeStore ----------------------------------------------------

test('발급한 challenge를 requestId로 되찾는다', () => {
    const store = createChallengeStore();
    const issued = store.issue(config, NOW);

    assert.deepEqual(store.get(issued.requestId, NOW), issued);
});

test('모르는 requestId는 거부한다', () => {
    const store = createChallengeStore();

    assert.throws(() => store.get('made-up-id', NOW), /Unknown or expired request id/);
    assert.throws(() => store.get('', NOW), /Request id is missing/);
});

test('get은 1회용이 아니다 — 재시도할 수 있어야 한다', () => {
    const store = createChallengeStore();
    const issued = store.issue(config, NOW);

    store.get(issued.requestId, NOW);

    assert.doesNotThrow(() => store.get(issued.requestId, NOW + 1000));
});

test('만료된 challenge는 청소된다', () => {
    const store = createChallengeStore();
    const issued = store.issue(config, NOW);

    assert.equal(store.size(), 1);

    // expiresAtMs(+5분) + retentionMs(+5분) 을 넘기면 사라진다.
    assert.throws(
        () => store.get(issued.requestId, NOW + 11 * 60 * 1000),
        /Unknown or expired request id/,
    );
    assert.equal(store.size(), 0);
});

// --- verifySignalPayment -----------------------------------------------------

const wire = () => ({
    challengeStore: createChallengeStore(),
    digestStore: createPaymentDigestStore(),
});

test('정상 흐름: 발급 -> 결제 -> 검증 통과', () => {
    const { challengeStore, digestStore } = wire();
    const challenge = challengeStore.issue(config, NOW);

    assert.doesNotThrow(() =>
        verifySignalPayment(
            {
                receipt: validReceipt(),
                requestId: challenge.requestId,
                txDigest: '0xTX1',
                config,
                challengeStore,
                digestStore,
            },
            NOW + 60000,
        ),
    );
});

test('같은 결제 tx로 두 번 신호를 받을 수 없다', () => {
    const { challengeStore, digestStore } = wire();
    const challenge = challengeStore.issue(config, NOW);

    const params = {
        receipt: validReceipt(),
        requestId: challenge.requestId,
        txDigest: '0xTX1',
        config,
        challengeStore,
        digestStore,
    };

    verifySignalPayment(params, NOW + 60000);

    assert.throws(() => verifySignalPayment(params, NOW + 61000), /already been used/);
});

test('검증에 실패하면 digest가 태워지지 않는다 (재시도 가능)', () => {
    const { challengeStore, digestStore } = wire();
    const challenge = challengeStore.issue(config, NOW);

    // 먼저 금액이 모자란 영수증으로 실패시킨다.
    assert.throws(
        () =>
            verifySignalPayment(
                {
                    receipt: validReceipt({ amount: '1' }),
                    requestId: challenge.requestId,
                    txDigest: '0xTX1',
                    config,
                    challengeStore,
                    digestStore,
                },
                NOW + 60000,
            ),
        /below the required price/,
    );

    // 같은 digest가 아직 살아 있어야 한다.
    assert.doesNotThrow(() =>
        verifySignalPayment(
            {
                receipt: validReceipt(),
                requestId: challenge.requestId,
                txDigest: '0xTX1',
                config,
                challengeStore,
                digestStore,
            },
            NOW + 60000,
        ),
    );
});

test('클라이언트가 지어낸 challenge는 통하지 않는다', () => {
    const { challengeStore, digestStore } = wire();

    // 공격자가 issuedAtMs를 0으로, expiresAtMs를 먼 미래로 적어 보낸 상황.
    // 서버는 자기 저장소만 보므로 requestId 단계에서 막힌다.
    assert.throws(
        () =>
            verifySignalPayment(
                {
                    receipt: validReceipt({ timestamp: '1' }),
                    requestId: 'forged-request-id',
                    txDigest: '0xTX1',
                    config,
                    challengeStore,
                    digestStore,
                },
                NOW + 60000,
            ),
        /Unknown or expired request id/,
    );
});

// --- fetchPaymentReceipt (가짜 reader 주입) -----------------------------------

const fakeReader = (response) => ({ query: async () => response });

const receiptEventNode = {
    contents: {
        type: {
            repr: `${PACKAGE_ID}::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>`,
        },
        json: {
            payer: '0x5678',
            payee: '0x1111',
            treasury: '0x3333',
            signal_provider_id: '0xabcd',
            amount: '1000000',
            platform_fee_amount: '200000',
            timestamp: '1786632060000',
        },
    },
};

test('성공한 tx에서 영수증을 뽑아낸다', async () => {
    const reader = fakeReader({
        data: {
            transaction: {
                digest: '0xTX1',
                effects: { status: 'SUCCESS', events: { nodes: [receiptEventNode] } },
            },
        },
    });

    const receipt = await fetchPaymentReceipt(reader, '0xTX1');

    assert.equal(receipt.payer, '0x5678');
    assert.equal(receipt.amount, '1000000');
    assert.equal(receipt.timestamp, '1786632060000');
    assert.match(receipt.type, /SignalPaymentReceiptEvent<0x2::sui::SUI>$/);
});

test('실패한 tx는 거부한다', async () => {
    const reader = fakeReader({
        data: {
            transaction: {
                digest: '0xTX1',
                effects: { status: 'FAILURE', events: { nodes: [] } },
            },
        },
    });

    await assert.rejects(
        () => fetchPaymentReceipt(reader, '0xTX1'),
        /did not succeed/,
    );
});

test('없는 tx, GraphQL 오류, 영수증 없는 tx를 각각 구분해 거부한다', async () => {
    await assert.rejects(
        () => fetchPaymentReceipt(fakeReader({ data: { transaction: null } }), '0xTX1'),
        /was not found/,
    );

    await assert.rejects(
        () =>
            fetchPaymentReceipt(
                fakeReader({ errors: [{ message: 'boom' }] }),
                '0xTX1',
            ),
        /Payment lookup failed: boom/,
    );

    await assert.rejects(
        () =>
            fetchPaymentReceipt(
                fakeReader({
                    data: {
                        transaction: {
                            digest: '0xTX1',
                            effects: { status: 'SUCCESS', events: { nodes: [] } },
                        },
                    },
                }),
                '0xTX1',
            ),
        /no signal payment receipt/,
    );

    await assert.rejects(() => fetchPaymentReceipt(fakeReader({}), '  '), /digest is missing/);
});

// --- createSignalHandler (HTTP 층) --------------------------------------------

/* 핸들러가 필요로 하는 것만 모아 준다. 네트워크도 체인도 타지 않는다. */
function handlerHarness({ receipt, fetchReceipt, produceSignal } = {}) {
    const challengeStore = createChallengeStore();
    const digestStore = createPaymentDigestStore();
    let now = NOW;

    const handle = createSignalHandler({
        config,
        challengeStore,
        digestStore,
        fetchReceipt:
            fetchReceipt ?? (async () => receipt ?? validReceipt()),
        produceSignal: produceSignal ?? (async ({ requestId }) => ({ requestId, side: 'BUY' })),
        now: () => now,
    });

    return {
        handle,
        setNow(value) { now = value; },
        /* 402를 받아 결제까지 끝낸 척하고 두 번째 요청을 만든다. */
        async paidRequest(overrides = {}) {
            const challenge = (await handle({})).body;
            now = NOW + 60000;

            return {
                challenge,
                request: {
                    headers: {
                        'PAYMENT-SIGNATURE': '0xTX1',
                        'payment-request-id': challenge.requestId,
                        ...overrides,
                    },
                },
            };
        },
    };
}

test('결제 증빙이 없으면 402와 challenge를 준다', async () => {
    const { handle } = handlerHarness();

    const response = await handle({ headers: {}, body: { vaultId: '0x1' } });

    assert.equal(response.status, 402);
    assert.equal(response.body.error, 'Payment Required');
    assert.match(response.body.requestId, /^[0-9a-f-]{36}$/);
    // 클라이언트가 PTB를 만들 수 있어야 한다.
    assert.equal(response.body.treasury, config.treasuryAddress);
    assert.equal(response.body.platformFeeBps, '2000');
});

test('발급한 challenge는 서버가 기억한다 — 지어낸 requestId는 통하지 않는다', async () => {
    const { handle } = handlerHarness();

    await handle({});

    const response = await handle({
        headers: {
            'payment-signature': '0xTX1',
            'payment-request-id': 'made-up-request-id',
        },
    });

    assert.equal(response.status, 402);
    assert.match(response.body.reason, /request/i);
});

test('결제를 냈는데 requestId가 없으면 400으로 알려준다', async () => {
    const { handle } = handlerHarness();

    const response = await handle({ headers: { 'payment-signature': '0xTX1' } });

    assert.equal(response.status, 400);
    assert.match(response.body.reason, /payment-request-id/);
});

test('정상 결제는 200과 시그널을 준다', async () => {
    const harness = handlerHarness();
    const { request, challenge } = await harness.paidRequest();

    const response = await harness.handle(request);

    assert.equal(response.status, 200);
    assert.deepEqual(response.body, { requestId: challenge.requestId, side: 'BUY' });
});

test('헤더 이름 대소문자는 가리지 않는다', async () => {
    const harness = handlerHarness();
    const { challenge } = await harness.paidRequest();

    const response = await harness.handle({
        headers: {
            'Payment-Signature': '0xTX1',
            'Payment-Request-Id': challenge.requestId,
        },
    });

    assert.equal(response.status, 200);
});

test('같은 결제로 두 번째 requestId를 채우려 하면 거부한다', async () => {
    const harness = handlerHarness();

    const first = await harness.paidRequest();
    assert.equal((await harness.handle(first.request)).status, 200);

    // 새 challenge를 받아 같은 tx digest를 다시 낸다.
    const second = await harness.paidRequest();
    const response = await harness.handle(second.request);

    assert.equal(response.status, 402);
    assert.match(response.body.reason, /digest/i);
});

test('같은 requestId로 재시도하면 검증 없이 같은 시그널을 다시 준다', async () => {
    // digest는 첫 성공에서 이미 태워졌다. 응답이 유실됐을 때 재시도가 막히면
    // 클라이언트는 돈만 내고 아무것도 못 받는다.
    let produced = 0;
    const harness = handlerHarness({
        produceSignal: async ({ requestId }) => {
            produced += 1;
            return { requestId, nth: produced };
        },
    });

    const { request } = await harness.paidRequest();

    const first = await harness.handle(request);
    const second = await harness.handle(request);

    assert.equal(first.status, 200);
    assert.equal(second.status, 200);
    assert.deepEqual(second.body, first.body);
    assert.equal(produced, 1);
});

test('체인 조회 실패는 502다 — 결제 자체는 유효할 수 있다', async () => {
    const harness = handlerHarness({
        fetchReceipt: async () => { throw new Error('GraphQL is down'); },
    });

    const { request } = await harness.paidRequest();
    const response = await harness.handle(request);

    assert.equal(response.status, 502);
    assert.match(response.body.reason, /GraphQL is down/);
});

test('검증 실패는 digest를 태우지 않는다 — 고쳐서 재시도할 수 있다', async () => {
    let receipt = validReceipt({ payer: '0xdead' });
    const harness = handlerHarness({ fetchReceipt: async () => receipt });

    const { request } = await harness.paidRequest();

    const rejected = await harness.handle(request);
    assert.equal(rejected.status, 402);
    assert.match(rejected.body.reason, /Payer is not the Agora agent/);

    // 같은 digest로 다시 — 태워지지 않았으므로 이번엔 통과해야 한다.
    receipt = validReceipt();
    assert.equal((await harness.handle(request)).status, 200);
});

test('결제는 받았는데 시그널을 못 만들면 500으로 드러낸다', async () => {
    // digest가 이미 태워진 상태라 클라이언트가 스스로 복구할 수 없다. 조용히 넘기면 안 된다.
    const harness = handlerHarness({
        produceSignal: async () => { throw new Error('strategy engine offline'); },
    });

    const { request, challenge } = await harness.paidRequest();
    const response = await harness.handle(request);

    assert.equal(response.status, 500);
    assert.match(response.body.reason, /Payment was accepted/);
    assert.equal(response.body.txDigest, '0xTX1');
    assert.equal(response.body.requestId, challenge.requestId);
});

test('지어낸 requestId는 체인을 조회하기 전에 402로 끊는다', async () => {
    // 조회를 먼저 하면 인증 없는 호출자가 이 서버의 GraphQL 왕복을 유발할 수 있다.
    let lookups = 0;
    const harness = handlerHarness({
        fetchReceipt: async () => { lookups += 1; return validReceipt(); },
    });

    await harness.handle({});

    const response = await harness.handle({
        headers: {
            'payment-signature': '0xTX1',
            'payment-request-id': 'made-up-request-id',
        },
    });

    assert.equal(response.status, 402);
    assert.equal(lookups, 0);
});
