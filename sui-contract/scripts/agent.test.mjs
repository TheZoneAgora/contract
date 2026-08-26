// -----------------------------------------------------------------------------
// 어댑터·시그널 정규화·가격 변환 테스트.
//
// 실행: cd sui-contract && npm run test:agent
//
// 네트워크도 지갑도 타지 않는다. 온체인 실행 자체는 testnet 수동 검증에 의존하고,
// 여기서는 그 앞단의 순수 판정만 본다 — 오늘까지 실수가 난 곳이 전부 여기다.
// -----------------------------------------------------------------------------

import test from 'node:test';
import assert from 'node:assert/strict';

import { fromMintPush } from '../sources/agent/adapters/mint.js';
import { deriveSignalId, normalizeSignal } from '../sources/agent/signal.js';
import { applySlippage, toPriceE9 } from '../sources/agent/executor.js';

const NOW = 1787733579000;
const opts = { chainNowMs: NOW, signalTtlMs: 300_000 };

const mintBody = (overrides = {}) => ({
    signal_id: 'mint-0001',
    agent_id: 'mint',
    side: 'BUY',
    symbol: 'SUI/USDC',
    price: 0.6842,
    timestamp_ms: NOW,
    ...overrides,
});

// --- 어댑터 ------------------------------------------------------------------

test('MINT의 snake_case를 내부 camelCase로 옮긴다', () => {
    // Agent에게 "우리 표기법에 맞춰주세요"라고 요구하지 않기 위한 변환이다.
    const signal = fromMintPush(mintBody());

    assert.equal(signal.signalId, 'mint-0001');
    assert.equal(signal.agentId, 'mint');
    assert.equal(signal.timestampMs, NOW);
});

test('side는 대소문자를 가리지 않는다', () => {
    assert.equal(fromMintPush(mintBody({ side: 'buy' })).side, 'BUY');
});

test('risk_score_bps를 보내와도 내부 시그널에 실리지 않는다', () => {
    // 위험도는 Agora가 매기는 값이다. Agent가 자기 위험도를 신고하면
    // "이 Agent를 믿을 수 있는가"라는 Agora의 존재 이유가 무너진다.
    const signal = fromMintPush(mintBody({ risk_score_bps: 0 }));

    assert.equal(signal.riskScoreBps, undefined);
    assert.ok(!('risk_score_bps' in signal));
});

// --- 정규화 ------------------------------------------------------------------

test('정상 시그널을 통과시킨다', () => {
    const signal = normalizeSignal(fromMintPush(mintBody()), opts);

    assert.equal(signal.side, 'BUY');
    assert.equal(signal.price, 0.6842);
    assert.equal(signal.timestampMs, NOW);
});

test('Agent가 본 가격이 없으면 거부한다', () => {
    // 우리가 채우면 온체인 편차 가드가 "우리 값 vs 우리 값"이 되어 무력화된다.
    assert.throws(
        () => normalizeSignal(fromMintPush(mintBody({ price: undefined })), opts),
        /agent-observed market price/
    );
    assert.throws(
        () => normalizeSignal(fromMintPush(mintBody({ price: 0 })), opts),
        /positive number/
    );
});

test('TTL이 지난 시그널은 체인에 가기 전에 끊는다', () => {
    assert.throws(
        () => normalizeSignal(fromMintPush(mintBody({ timestamp_ms: NOW - 400_000 })), opts),
        /older than/
    );
});

test('체인보다 미래인 시각은 거부하지 않고 당겨 준다', () => {
    // 체인 시각이 체크포인트 기준이라 로컬보다 ~1.7초 뒤처진다. Agent 잘못이 아니다.
    const signal = normalizeSignal(
        fromMintPush(mintBody({ timestamp_ms: NOW + 5_000 })),
        opts
    );

    assert.equal(signal.timestampMs, NOW);
});

test('잘못된 side와 symbol을 거부한다', () => {
    assert.throws(() => normalizeSignal(fromMintPush(mintBody({ side: 'HOLD' })), opts), /BUY/);
    assert.throws(() => normalizeSignal(fromMintPush(mintBody({ symbol: 'SUI' })), opts), /BASE\/QUOTE/);
});

test('confidence는 0~1일 때만 받는다', () => {
    assert.equal(
        normalizeSignal(fromMintPush(mintBody({ confidence: 0.72 })), opts).confidence,
        0.72
    );
    assert.throws(
        () => normalizeSignal(fromMintPush(mintBody({ confidence: 1.5 })), opts),
        /between 0 and 1/
    );
});

// --- signalId 생성 -----------------------------------------------------------

test('signalId가 없으면 결정론적으로 만든다', () => {
    // 점수만 내는 Agent나 폴링으로 읽어오는 외부 API에는 자체 id가 없다.
    const signal = normalizeSignal(fromMintPush(mintBody({ signal_id: undefined })), opts);

    assert.match(signal.signalId, /^mint-[0-9a-f]{24}$/);
});

test('같은 판단은 같은 id — 재시도가 안전하다', () => {
    const base = { agentId: 'mint', symbol: 'SUI/USDC', side: 'BUY', timestampMs: NOW };

    // 같은 1분 버킷 안이면 폴링이 여러 번 관측해도 같은 id가 나와야 한다.
    assert.equal(deriveSignalId(base), deriveSignalId({ ...base, timestampMs: NOW + 5_000 }));
});

test('다른 판단은 다른 id', () => {
    const base = { agentId: 'mint', symbol: 'SUI/USDC', side: 'BUY', timestampMs: NOW };

    assert.notEqual(deriveSignalId(base), deriveSignalId({ ...base, side: 'SELL' }));
    assert.notEqual(deriveSignalId(base), deriveSignalId({ ...base, symbol: 'BTC/USDC' }));
    assert.notEqual(deriveSignalId(base), deriveSignalId({ ...base, agentId: 'axiom' }));
    assert.notEqual(deriveSignalId(base), deriveSignalId({ ...base, timestampMs: NOW + 120_000 }));
});

test('signalId는 64바이트를 넘을 수 없다', () => {
    // 온체인에 vector<u8>로 저장된다.
    assert.throws(
        () => normalizeSignal(fromMintPush(mintBody({ signal_id: 'x'.repeat(65) })), opts),
        /64 bytes/
    );
});

// --- 가격 스케일 -------------------------------------------------------------

test('decimals 차이를 반영해 price_e9을 만든다', () => {
    // SUI(9) per DEEP(6), 0.0272 -> 0.0272 * 1e9/1e6 * 1e9 = 2.72e10
    // 여기서 1000배를 틀려 편차 가드에 걸린 적이 있다.
    assert.equal(toPriceE9(0.0272, 9, 6), 27_200_000_000n);
});

test('decimals가 같으면 그대로 1e9 배', () => {
    assert.equal(toPriceE9(1.5, 6, 6), 1_500_000_000n);
});

test('표현 불가능한 가격은 거부한다', () => {
    assert.throws(() => toPriceE9(0, 9, 6), /positive/);
    assert.throws(() => toPriceE9(-1, 9, 6), /positive/);
});

test('슬리피지를 뺀 최소 수령량', () => {
    assert.equal(applySlippage(1_000_000n, 300n), 970_000n);
    assert.equal(applySlippage(1_000_000n, 0n), 1_000_000n);
});
