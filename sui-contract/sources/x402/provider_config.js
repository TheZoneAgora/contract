import {
    isValidSuiAddress,
    normalizeSuiAddress,
    normalizeStructTag,
} from '@mysten/sui/utils'

// 2의 64제곱 -1
const MAX_U64 = (1n << 64n) - 1n;

export function requireEnv(name) {
    const value = process.env[name];

    if (typeof value !== 'string' || value.trim().length === 0) {
        throw new Error(`Missing required environment variable: ${name}`);
    }

    return value.trim();
}

/* 필수 환경변수를 읽고 Sui 주소 형식인지 검사
    @param {string} name
    @returns {string}
*/
export function requireAddressEnv(name) {
    const value = requireEnv(name);
    const normalizedAddress = normalizeSuiAddress(value);

    if (!isValidSuiAddress(normalizedAddress)) {
        throw new Error(
            `${name} must contain a valid Sui address. `,
        );
    }

    return normalizedAddress;
}

/* 환경변수를 읽고 Move 
    @param {string} name
    @param {boolean} [allowZero=false]
    @returns {bigint}
*/
export function requireU64Env(name, allowZero = false) {
    const value = requireEnv(name);

    let parsed;

    // 문자열을 bigint로 반환
    try {
        parsed = BigInt(value);
    } catch {
        throw new Error(`${name} must contain an integer.`)
    }

    // 음수 혹은 u64초과 시 차단
    if (parsed < 0n || parsed > MAX_U64) {
        throw new Error(`${name} must fit in Move u64.`);
    }

    // 결재 금액이 0이면 안됨
    if (!allowZero && parsed === 0n) {
        throw new Error(`${name} must be greater than zero.`)
    }

    return parsed;
}

/* 환경변수를 읽고 완전한 Move 코인 타입으로 정규화

    예) 
    0x2::sui::SUI
    0x1234::usdc::USDC

    @param {string} name
    @returns {string}
*/
export function requireCoinTypeEnv(name){
    // 코인타입이란? sui에서 코인은 주소 하나로만 구분하지 않고 다음과 같은 Move 타입으로 구분
    // [Package주소::Module 이름::Struct이름]
    // 0x2::sui::SUI, 0x1234::usdc::USDC
    const value = requireEnv(name);

    let normalizedType;

    try {
        // Move 타입 문법을 검사하고 주소 부분을 표준화함
        // ex)   normalizeStructTag('0x2::sui::SUI');
        //  -->   0x0000000000000000000000000000000000000000000000000000000000000002::sui::SUI
        normalizedType = normalizeStructTag(value);
    } catch {
        throw new Error(
            `${name} must contain a fully qualified Move coin type.`
        );
    }

    return normalizedType;
}

/* Signal Provider 서버의 x402 설정을 환경번수에서 읽음
    @returns {{
        rpcUrl: string, ex)'https://fullnode.testnet.sui.io:443
        packageId: string, ex)'0x0000...1234'
        agoraAgentAddress: string, ex)'0x0000...5678'
        providerId: string, ex) '0x0000...abcd'
        paymentReceiver: string, ex) '0x0000...1111'
        treasuryAddress: string, ex) '0x0000...2222'
        platformFeeBps: bigint, ex) 2000n
        paymentToken: string, ex) '0x0000...::usdc::USDC'
        paymentAmount: bigint, ex) 1000000n
    }}
*/
export function loadProviderConfig() {
    // ------------------------------------------------------------------
    // 여기부터 return 시작 줄까지 Claude가 고친 부분 (rpcUrl -> graphqlUrl).
    // 이유: 공용 fullnode에서 JSON-RPC가 폐기돼 SuiClient로는 tx 조회가 안 된다.
    //       (이번 세션에 MethodNotFound를 직접 확인)
    //       그래서 GraphQL 엔드포인트를 받도록 바꿨다.
    // .env 에 추가 필요: X402_SUI_GRAPHQL_URL=https://graphql.testnet.sui.io/graphql
    // ------------------------------------------------------------------
    const graphqlUrl = requireEnv('X402_SUI_GRAPHQL_URL');

    // new URL(graphqlUrl) 을통해 URL문법을 확인
    try {
        new URL(graphqlUrl);
    } catch {
        throw new Error(
            'X402_SUI_GRAPHQL_URL must contain a valid URL.'
        );
    }

    // payment_splitter.move가 platform_fee_bps <= 10000을 assert한다. 설정이 이를 넘으면
    // 모든 결제가 온체인에서 abort하므로, 요청을 받기 전 기동 시점에 끊는다.
    const platformFeeBps = requireU64Env('X402_PLATFORM_FEE_BPS', true);

    if (platformFeeBps > 10_000n) {
        throw new Error(
            'X402_PLATFORM_FEE_BPS must be between 0 and 10000.'
        );
    }

    return {
        graphqlUrl,
        platformFeeBps,
    // ------------------------------------------------------------------
    // 여기까지 Claude가 고친 부분. 아래는 원래 코드 그대로.
    // ------------------------------------------------------------------

        packageId: requireAddressEnv(
            'X402_PACKAGE_ID', 
            // payment_splitter.move가 배포된 Agora 컨트랙트 Package 주소, 
            // 서버는 결제 이벤트가 만드시 이 Pacakge에서 나왔는지 확인
        ),

        agoraAgentAddress: requireAddressEnv(
            'X402_AGORA_AGENT_ADDRESS',
            // 결제해야 하는 Agora 운영 Agent주소, 
            // 다른 사용자가 결제한 트랜잭션을 가져와 Signal을 받는 것을 막는데 사용
        ),

        providerId: requireAddressEnv(
            'X402_SIGNAL_PROVIDER_ID',
            // Signal Provider의 식별자
            // 결제 이벤트의 signal_provider_id와 비교
        ),

        paymentReceiver: requireAddressEnv(
            'X402_PAYMENT_RECEIVER',
            // Signal Provider가 사용료를 받을 주소.
            // payment_splitter의 signal_provider_payment_receiver이자 영수증의 payee다.
            // (플랫폼 수수료를 받는 쪽은 아래 treasuryAddress다 — 혼동 주의)
        ),

        treasuryAddress: requireAddressEnv(
            'X402_TREASURY_ADDRESS',
            // Agora 플랫폼 수수료를 받을 Treasury 주소.
            // challenge로 내려보내 클라이언트가 PTB를 만들 수 있게 하고,
            // 영수증의 treasury 필드와 다시 대조한다.
        ),

        paymentToken: requireCoinTypeEnv(
            'X402_PAYMENT_TOKEN',
            // 결제에 사용되는 코인 type
        ),

        paymentAmount: requireU64Env(
            'X402_PAYMENT_AMOUNT',
            // Provider가 요구하는 총 결제 금액 (Provider 몫 + Treasury 몫)
        ),
    };
}