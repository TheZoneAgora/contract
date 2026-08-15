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

const NOW = 1786632000000;
const PACKAGE_ID =
    '0x0f5a55d4768a22382295652b415c0df973db45e4ac1d65c8ceadc3a331c68bfa';

const config = {
    packageId: PACKAGE_ID,
    agoraAgentAddress:
        '0x0000000000000000000000000000000000000000000000000000000000005678',
    providerId:
        '0x000000000000000000000000000000000000000000000000000000000000abcd',
    paymentReceiver:
        '0x0000000000000000000000000000000000000000000000000000000000001111',
    paymentToken:
        '0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI',
    paymentAmount: 1000000n,
};

const validReceipt = (overrides = {}) => ({
    type: `${PACKAGE_ID}::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>`,
    payer: '0x5678',
    payee: '0x1111',
    signal_provider_id: '0xabcd',
    amount: '1000000',
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
