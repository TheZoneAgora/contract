import { randomUUID } from 'node:crypto';
import { normalizeSuiAddress, normalizeStructTag } from '@mysten/sui/utils'

// receipt : 결제가 실제로 체인에 찍혔다는 온체인 영수증 — 정확히는 payment_splitter.move 가 emit한 SignalPaymentReceiptEvent 를 tx digest로 다시 읽어와 JS 객체로 파싱한 것입니다.

/* Provider Agent가 결제를 요구할 떄 반환할 402 challenge를 만든다
@param {{
    providerId: string,
    paymentReceiver: string,
    paymentToken: string,
    paymentAmount: bigint,
}} config
@param {number} [nowMs=Date.now()]
@returns {{
    error: 'Payment Required', ex) 'Payment Required'
    requestId: string, ex) '74a9271f-062e-48a4-9efd-bfa60ba75903'
    price: string, ex) '1000000'
    payee: string, ex) '0x0000...1234'
    token: string, ex) '0x0000...::usdc::USDC'
    signalProviderId: string, ex) '0x0000...5678'
    treasury: string, ex) '0x0000...2222'
    platformFeeBps: string, ex) '2000'
    issuedAtMs: string, ex) '1786632000000'
    expiresAtMs: string, ex) '1786632300000'
}}
 */
export function createPaymentChallenge(
    config,
    nowMs = Date.now()
) {
    const requestId = randomUUID();
    const challengeLifetimeMs = 5 * 60 * 1000;
    const expiresAtMs = nowMs + challengeLifetimeMs;

    return{
        error: 'Payment Required',
        requestId,
        price: config.paymentAmount.toString(),
        payee: config.paymentReceiver,
        token: config.paymentToken,
        signalProviderId: config.providerId,
        // treasury와 platformFeeBps가 없으면 클라이언트는
        // payment_splitter::pay_signal_provider_usage_fee를 아예 호출할 수 없다.
        // 둘 다 그 함수의 필수 인자다.
        treasury: config.treasuryAddress,
        platformFeeBps: config.platformFeeBps.toString(),
        issuedAtMs: nowMs.toString(),
        expiresAtMs: expiresAtMs.toString(),
    };

}

/* challenge 금액에서 Treasury가 받아야 할 몫을 구한다.
   payment_splitter.move의 계산(u64 overflow를 피하려 몫과 나머지를 나눠 곱함)을
   그대로 옮긴 것이다. 어긋나면 정상 결제가 거부되므로 반드시 같아야 한다.

   @param {bigint} amount
   @param {bigint} platformFeeBps
   @returns {bigint}
*/
function expectedPlatformFeeAmount(amount, platformFeeBps) {
    const BPS_DENOMINATOR = 10_000n;
    const wholeUnits = amount / BPS_DENOMINATOR;
    const remainder = amount % BPS_DENOMINATOR;

    return (
        wholeUnits * platformFeeBps
        + (remainder * platformFeeBps) / BPS_DENOMINATOR
    );
}

/* 온체인 영수증 이벤트가 이 challenge에 대한 정당한 결제인지 검사한다
   통과하면 조용히 리턴하고, 하나라도 어긋나면 throw 한다.

   @param {{
            type: string, ex)'0x0000...1234::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>'
            payer: string,
            payee: string,
            signal_provider_id: string,
            amount: string, ex) '1000000'
            timestamp: string, ex) '1786632000000'
   }} receipt
    @param {ReturnType<typeof createPaymentChallenge>} challenge
    @param {ReturnType<typeof loadProviderConfig>} config
    @param {number} [nowMs=Date.now()]
    @returns {void}
 */

export function assertReceiptMatchesChallenge(
    receipt,
    challenge,
    config,
    nowMs = Date.now(),
) {
    // 1. challenge가 아직 살아 있어야 함
    if (nowMs > Number(challenge.expiresAtMs)) {
        throw new Error('Challenge has expired.');
    }

    // 2. 우리 Package에서, 우리가 요구한 토큰으로 찍힌 이벤트여야 한다.
    //    Package를 확인하지 않으면 공격자가 이름만 같은 모듈을 배포해 영수증을 위조할 수 있다.
    const expectedType =
        `${config.packageId}::payment_splitter::SignalPaymentReceiptEvent<${config.paymentToken}>`;

    if (normalizeStructTag(receipt.type) !== normalizeStructTag(expectedType)) {
        throw new Error('Payment event type mismatch.');
    }

    // 3. Agora 운영 Agent가 낸 결제여야 한다.
    //    이 검사가 없으면 남이 낸 결제 tx digest를 주워서 신호를 받을 수 있다.
    if (normalizeSuiAddress(receipt.payer) !== config.agoraAgentAddress) {
        throw new Error('Payer is not the Agora agent.');
    }

    // 4. 수령자와 Provider 식별자가 이 서버의 설정과 일치해야 한다.
    if (normalizeSuiAddress(receipt.payee) !== config.paymentReceiver) {
        throw new Error('Payment receiver mismatch.');
    }

    if (normalizeSuiAddress(receipt.signal_provider_id) !== config.providerId) {
        throw new Error('Signal provider mismatch.');
    }

    // 5. 요구 금액 이상이어야 한다. 더 낸 것은 허용한다.
    if (BigInt(receipt.amount) < config.paymentAmount) {
        throw new Error('Payment amount is below the required price.');
    }

    // 5-1. Treasury 몫이 우리가 요구한 주소로, 요구한 만큼 갔어야 한다.
    //      payment_splitter는 treasury_address와 platform_fee_bps를 호출자에게서
    //      그대로 받는다. 여기서 보지 않으면 payer가 treasury를 자기 주소로 바꾸거나
    //      fee를 0으로 낮춰 Provider 몫만 채우고 신호를 받아갈 수 있다.
    //      challenge에 실어 보낸 조건이므로 그대로 지켜졌는지 확인한다.
    if (normalizeSuiAddress(receipt.treasury) !== config.treasuryAddress) {
        throw new Error('Treasury address mismatch.');
    }

    // 요구 금액보다 더 낸 경우 수수료도 그만큼 늘어나므로 하한선으로만 본다.
    const requiredFee = expectedPlatformFeeAmount(
        config.paymentAmount,
        config.platformFeeBps,
    );

    if (BigInt(receipt.platform_fee_amount) < requiredFee) {
        throw new Error('Platform fee is below the required share.');
    }

    // 6. challenge를 발급한 뒤에 일어난 결제여야 한다.
    //    영수증에 requestId가 없으므로, 시간 하한선이 옛날 결제 재활용을 막는 유일한 장치다.
    if (Number(receipt.timestamp) < Number(challenge.issuedAtMs)) {
        throw new Error('Payment predates the challenge.');
    }
}

/* 이미 사용한 결제 digest를 기억해 재사용을 막는다
   challenge 유효기간 (5분)이 지난 digest는 어짜피 6번 검사에서 걸리므로
   메모리에 영원히 쌓아 둘 필요가 없다. 그래서 만료 시각과 함께 저장하고
   지날 때마다 청소한다.

   ⚠️ 프로세스 메모리에만 남는다. 서버를 여러 대로 늘리면 Redis 같은 공유 저장소로 바꿔야 한다.

   @param {number} [retentionMs=5*60*1000]
   @returns {{ consume: (digest: string, nowMs?: number) => void }}
*/
export function createPaymentDigestStore(retentionMs = 5 * 60 * 1000) {
    /** @type {Map<string, number>} digest -> 폐기해도 되는 시각 */
    const usedDigests = new Map();

    return {
        /* digest를 1회용으로 소비한다. 이미 썼으면 throw.
           @param {string} digest
           @param {number} [nowMs=Date.now()]
           @returns {void}
        */

        consume(digest, nowMs = Date.now()) {
            if (typeof digest !== 'string' || digest.trim().length === 0) {
                throw new Error('Payment digest is missing.')
            }

            // 만료된 항목부터 치운다, 안 치우면 Map이 무한히 커진다
            for (const [seen, expiresAt] of usedDigests) {
                if (nowMs >= expiresAt) {
                    usedDigests.delete(seen);
                }
            }

            if (usedDigests.has(digest)) {
                throw new Error('Payment digest has already been used.');
            }

            usedDigests.set(digest, nowMs + retentionMs);
        },
    };
}

// -----------------------------------------------------------------------------
// 아래는 Claude가 작성한 부분입니다 (진웅님이 직접 적은 코드가 아님).
// 리뷰 포인트 3개:
//   (1) createChallengeStore 가 왜 필요한가  -> 함수 주석
//   (2) get() 이 왜 1회용이 아닌가            -> 함수 주석
//   (3) verifySignalPayment 의 검사 순서      -> 함수 주석
// -----------------------------------------------------------------------------

/* 서버가 발급한 challenge를 requestId로 되찾을 수 있게 보관한다.

   왜 필요한가:
   402 응답을 받은 클라이언트는 결제 후 requestId와 tx digest를 들고 다시 온다.
   이때 서버가 "내가 진짜 발급한 challenge"를 스스로 기억하고 있지 않으면,
   클라이언트가 보내온 issuedAtMs/expiresAtMs를 그대로 믿어야 한다.
   그러면 assertReceiptMatchesChallenge의 1번(만료)과 6번(발급 이후) 검사가
   전부 무력해진다. 공격자가 issuedAtMs를 0으로 적어 보내면 끝이다.
   그래서 challenge는 반드시 서버 쪽 저장소에서 꺼내 와야 한다.

   ⚠️ createPaymentDigestStore와 같은 한계 — 프로세스 메모리에만 남는다.
      서버를 여러 대로 늘리거나 재시작하면 발급 기록이 날아가므로,
      그때는 Redis 같은 공유 저장소로 바꿔야 한다.

    @param {number} [retentionMs=5*60*1000] 만료된 challenge를 폐기할 때까지의 여유
    @returns {{
        issue: (config: object, nowMs?: number) => object,
        get: (requestId: string, nowMs?: number) => object,
        size: () => number,
    }}
*/
export function createChallengeStore(retentionMs = 5 * 60 * 1000) {
    /** @type {Map<string, ReturnType<typeof createPaymentChallenge>>} */
    const issuedChallenges = new Map();

    // 만료된 challenge를 치운다. expiresAtMs를 이미 지난 것은 어차피
    // assertReceiptMatchesChallenge 1번 검사에서 걸리므로 들고 있을 이유가 없다.
    const sweep = (nowMs) => {
        for (const [requestId, challenge] of issuedChallenges) {
            if (nowMs >= Number(challenge.expiresAtMs) + retentionMs) {
                issuedChallenges.delete(requestId);
            }
        }
    };

    return {
        /* challenge를 발급하고 저장한 뒤 그대로 반환한다. 402 본문으로 내보내면 된다.
            @param {object} config loadProviderConfig()의 결과
            @param {number} [nowMs=Date.now()]
            @returns {ReturnType<typeof createPaymentChallenge>}
        */
        issue(config, nowMs = Date.now()) {
            sweep(nowMs);

            const challenge = createPaymentChallenge(config, nowMs);
            issuedChallenges.set(challenge.requestId, challenge);

            return challenge;
        },

        /* requestId로 발급 기록을 되찾는다. 없으면 throw.

           일부러 1회용(꺼내면 삭제)으로 만들지 않았다.
           결제는 이미 체인에서 끝난 상태이므로, 검증이 일시적 오류로 실패했을 때
           클라이언트가 재시도할 길을 막으면 "돈은 냈는데 신호는 못 받는" 상태가 된다.
           재사용 차단은 challenge가 아니라 digest 쪽에서 한다 —
           희소한 자원은 requestId가 아니라 결제 tx digest다.

            @param {string} requestId
            @param {number} [nowMs=Date.now()]
            @returns {ReturnType<typeof createPaymentChallenge>}
        */
        get(requestId, nowMs = Date.now()) {
            sweep(nowMs);

            if (typeof requestId !== 'string' || requestId.trim().length === 0) {
                throw new Error('Request id is missing.');
            }

            const challenge = issuedChallenges.get(requestId.trim());

            if (challenge === undefined) {
                throw new Error('Unknown or expired request id.');
            }

            return challenge;
        },

        /* 테스트에서 청소가 실제로 돌았는지 보기 위한 용도.
            @returns {number}
        */
        size() {
            return issuedChallenges.size;
        },
    };
}

/* 결제 증빙 하나를 끝까지 검증한다. x402 재요청 처리의 진입점.

   검사 순서가 중요하다. digest 소비(consume)를 반드시 마지막에 한다.
   먼저 소비해 버리면, 뒤쪽 검사에서 throw 났을 때 정상 결제의 digest가
   영구히 태워진다. 그 결제는 두 번 다시 쓸 수 없으므로 사용자는 돈만 잃는다.
   그래서 "판정을 모두 통과한 뒤에 소비"가 유일하게 안전한 순서다.

    @param {{
        receipt: object,        fetchPaymentReceipt()의 결과
        requestId: string,      클라이언트가 보내온 requestId
        txDigest: string,       클라이언트가 보내온 결제 tx digest
        config: object,         loadProviderConfig()의 결과
        challengeStore: ReturnType<typeof createChallengeStore>,
        digestStore: ReturnType<typeof createPaymentDigestStore>,
    }} params
    @param {number} [nowMs=Date.now()]
    @returns {void} 통과하면 조용히 리턴, 아니면 throw
*/
export function verifySignalPayment(
    {
        receipt,
        requestId,
        txDigest,
        config,
        challengeStore,
        digestStore,
    },
    nowMs = Date.now(),
) {
    // 1. 클라이언트 말이 아니라 서버 발급 기록에서 challenge를 꺼낸다.
    const challenge = challengeStore.get(requestId, nowMs);

    // 2. 영수증이 이 challenge에 대한 정당한 결제인지 판정한다.
    assertReceiptMatchesChallenge(receipt, challenge, config, nowMs);

    // 3. 전부 통과한 뒤에야 digest를 태운다.
    digestStore.consume(txDigest, nowMs);
}