// -----------------------------------------------------------------------------
// 내부 시그널 → 온체인 실행.
//
// 시그널이 어떻게 도착했는지 알지 못한다. 어댑터가 정규화한 것만 받는다.
// 여기가 흡수하는 것: 가격 스케일 변환 · 최소 수령량 · DEEP 분리 · PTB 조립 · 거부 해석
// -----------------------------------------------------------------------------

import { Transaction } from '@mysten/sui/transactions';

const CLOCK_OBJECT_ID = '0x6';
const PRICE_SCALE = 1_000_000_000n;
const MAX_U64 = (1n << 64n) - 1n;

/* 사람이 읽는 가격(fiat per crypto)을 온체인 price_e9으로 바꾼다.
 *
 * 컨트랙트는 quote_price_e9 = fiat_amount * 1e9 / base_out 으로 계산한다.
 * fiat_amount와 base_out은 각 코인의 **최소단위**다. 따라서
 *   price_e9 = P * 10^fiatDecimals / 10^cryptoDecimals * 1e9
 * 예) SUI(9) per DEEP(6), P=0.0272 -> 0.0272 * 1e9 / 1e6 * 1e9 = 2.72e10
 *
 * 자릿수를 틀리면 1000배씩 어긋나 가격 편차 가드에 걸린다. 실제로 겪은 함정이다.
 */
export function toPriceE9(humanPrice, fiatDecimals, cryptoDecimals) {
    if (!Number.isFinite(humanPrice) || humanPrice <= 0) {
        throw new Error('price must be a positive number.');
    }

    const scaled = humanPrice * 10 ** (fiatDecimals - cryptoDecimals) * 1e9;

    if (!Number.isFinite(scaled) || scaled < 1) {
        throw new Error('price is too small to express as price_e9.');
    }

    const result = BigInt(Math.round(scaled));
    if (result > MAX_U64) throw new Error('price_e9 does not fit in u64.');

    return result;
}

/** 슬리피지를 반영한 최소 수령량. 0으로 두면 샌드위치 공격 경로가 된다. */
export function applySlippage(expected, slippageBps) {
    return (expected * (10_000n - slippageBps)) / 10_000n;
}

/* signalId 문자열을 온체인 vector<u8>로 바꾼다.
   Vault마다 별도 Table이라 같은 시그널을 여러 Vault에 한 번씩 쓸 수 있다
   (팬아웃 설계). 같은 Vault에 두 번은 영구 차단된다. */
export function signalIdBytes(signalId) {
    return Array.from(Buffer.from(signalId, 'utf8'));
}

/* 거래 크기를 정한다.
 *
 * Providing Agent는 사용자 Vault 크기를 모르므로 방향만 준다. 금액은 Agora가 정한다.
 * 지금은 설정값 고정이다 — Vault 잔액 비례나 confidence 반영은 아직 없다.
 * 어느 쪽이든 Vault의 max_trade_amount가 최종 상한이고, Pool의 min_size가 하한이다.
 */
export function tradeAmountFor(side, config) {
    return side === 'BUY' ? config.buyFiatAmount : config.sellCryptoAmount;
}

export function buildExecuteTransaction({ config, signal, chainNowMs }) {
    const tx = new Transaction();
    const isBuy = signal.side === 'BUY';

    const priceE9 = toPriceE9(
        signal.price,
        config.fiatDecimals,
        config.cryptoDecimals
    );

    // whitelisted Pool에는 잔액 0인 Coin<DEEP>을 넣어야 한다. 넣으면 전액 소모된다.
    const deepFee = config.poolWhitelisted
        ? tx.moveCall({
            target: '0x2::coin::zero',
            typeArguments: [config.deepType],
        })
        : tx.splitCoins(tx.object(config.deepCoinId), [config.deepPerTrade])[0];

    // 최소 수령량은 시그널 가격 기준 기대치에서 슬리피지를 뺀 값이다.
    // SELL의 min_fiat_output은 수수료를 뗀 **순액** 기준이다 — 컨트랙트가
    // gross_min_output()으로 알아서 올려 잡으므로 여기서는 순액을 넣으면 된다.
    const inputAmount = tradeAmountFor(signal.side, config);
    const expectedOutput = isBuy
        ? (inputAmount * PRICE_SCALE) / priceE9
        : (inputAmount * priceE9) / PRICE_SCALE;

    tx.moveCall({
        target: `${config.packageId}::deepbook_executor::${isBuy ? 'execute_buy' : 'execute_sell'}`,
        typeArguments: [config.fiatType, config.cryptoType],
        arguments: [
            tx.object(config.vaultId),
            tx.object(config.poolId),
            deepFee,
            tx.pure.u64(inputAmount),
            tx.pure.u64(applySlippage(expectedOutput, config.slippageBps)),
            tx.pure.vector('u8', signalIdBytes(signal.signalId)),
            tx.pure.u64(BigInt(signal.timestampMs)),
            tx.pure.u64(priceE9),
            // 위험도는 Agent가 아니라 Agora가 매긴다. 느린 시계가 없는 동안은
            // 보수적인 고정값을 쓴다. Vault의 max_risk_score_bps가 상한이다.
            tx.pure.u64(config.riskScoreBps),
            tx.pure.u64(BigInt(chainNowMs + 60_000)),
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
    'investment_vault::5': '1회 거래 한도 초과 (E_TRADE_LIMIT_EXCEEDED)',
    'investment_vault::6': 'epoch 누적 거래 한도 초과 — 다음 epoch까지 대기',
    'investment_vault::7': 'Vault 잔액 부족 (E_INSUFFICIENT_BALANCE)',
    'investment_vault::17': '이미 사용된 signalId (E_DUPLICATE_SIGNAL)',
    'vault_policy::2': '시그널 시각이 체인보다 미래 (E_SIGNAL_FROM_FUTURE)',
    'vault_policy::5': '시그널 가격이 실제 호가와 너무 벌어짐 (편차 한도 초과)',
};

export function explainFailure(message) {
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
