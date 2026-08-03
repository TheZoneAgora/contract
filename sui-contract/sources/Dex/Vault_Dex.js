// Sui Programmable Transaction Block(PTB)을 조립하는 SDK 클래스다.
import { Transaction } from '@mysten/sui/transactions';

// 주소 형식을 검사하고 32바이트 표준 주소로 바꾸는 SDK 도구다.
import {
    isValidSuiAddress,
    normalizeSuiAddress,
} from '@mysten/sui/utils';

// 배포된 agent_market Move package ID다.
// Move.toml의 개발용 named address인 0x0과는 다른 값이다.
export const PACKAGE_ID =
    process.env.NEXT_PUBLIC_AGENT_MARKET_PACKAGE_ID;

// Move module: agent_market::investment_vault
export const VAULT_MODULE = 'investment_vault';
export const ORDER_EXECUTOR_MODULE = 'order_executor';
export const CLOCK_OBJECT_ID = '0x6';

// 로컬 개발에서 참조할 수 있는 SUI 타입 상수다.
export const SUI_COIN_TYPE = '0x2::sui::SUI';

// 사용자가 선택하지 않는 Agora 기준 자산과 운용 자산 타입이다.
export const AGORA_FIAT_COIN_TYPE =
    process.env.NEXT_PUBLIC_AGORA_FIAT_COIN_TYPE; // 🆕 사용자 입력 제거, 배포 USDC 설정
export const AGORA_CRYPTO_COIN_TYPE =
    process.env.NEXT_PUBLIC_AGORA_CRYPTO_COIN_TYPE; // 🔄 사용자 Crypto 선택 → Agora 배포 설정
export const AGORA_AGENT_OPERATOR =
    process.env.NEXT_PUBLIC_AGORA_AGENT_OPERATOR; // 🔄 사용자 Agent 주소 입력 → Agora 배포 설정

// Move의 u64가 표현할 수 있는 최댓값: 2^64 - 1
const MAX_U64 = (1n << 64n) - 1n;

// Sui 주소 또는 object ID를 검증하고 정규화한다.
function requireAddress(value, label) {
    // 주소는 문자열로 받아야 trim, 정규화, 형식 검증을 안전하게 할 수 있다.
    if (typeof value !== 'string') {
        // label을 사용해 어느 파라미터가 잘못됐는지 오류에 표시한다.
        throw new Error(`${label} must be a string.`);
    }

    // 0x1 같은 짧은 주소도 0x000...001 형태의 표준 주소로 바꾼다.
    const normalized = normalizeSuiAddress(value);

    // 정규화된 결과가 실제 Sui 주소 규칙을 만족하는지 마지막으로 확인한다.
    if (!isValidSuiAddress(normalized)) {
        throw new Error(`${label} must be a valid Sui address.`);
    }

    // 이후 Transaction에는 항상 동일한 표준 주소 형태를 사용한다.
    return normalized;
}

// package ID가 함수 인자로 없으면 환경변수에서 가져온다.
function requirePackageId(packageId) {
    // package ID가 없으면 호출 대상 Move package를 정할 수 없다.
    if (!packageId) {
        throw new Error(
            'NEXT_PUBLIC_AGENT_MARKET_PACKAGE_ID is required.',
        );
    }

    // Package ID도 Sui object 주소이므로 같은 주소 검증 함수를 사용한다.
    return requireAddress(packageId, 'packageId');
}

// Move의 T type argument로 사용할 전체 타입인지 확인한다.
function requireCoinType(coinType) {
    // 전체 Move 타입은 보통 package::module::struct 형태이므로 ::가 필요하다.
    if (
        typeof coinType !== 'string' ||
        !coinType.includes('::')
    ) {
        throw new Error(
            'coinType must be a fully qualified Move type.',
        );
    }

    // 검사를 통과한 타입 문자열을 moveCall의 typeArguments에 사용한다.
    return coinType;
}

// Move u64에 전달할 값인지 확인하고 bigint로 변환한다.
function requireU64(value, label) {
    // JavaScript number는 큰 정수에서 정밀도를 잃으므로 안전한 정수만 허용한다.
    // 큰 금액은 1000000000n 같은 bigint 또는 정수 문자열로 전달한다.
    if (
        typeof value === 'number' &&
        !Number.isSafeInteger(value)
    ) {
        throw new Error(
            `${label} must be a safe integer, bigint, or integer string.`,
        );
    }

    // 변환 결과를 저장할 변수다.
    let result;

    try {
        // number, bigint, 정수 문자열을 모두 bigint 하나로 통일한다.
        result = BigInt(value);
    } catch {
        // 소수나 숫자가 아닌 문자열처럼 bigint로 바꿀 수 없는 값을 차단한다.
        throw new Error(`${label} must be an integer.`);
    }

    // Move u64는 음수를 허용하지 않고 2^64 - 1을 넘을 수 없다.
    if (result < 0n || result > MAX_U64) {
        throw new Error(`${label} must fit in u64.`);
    }

    // 검증된 bigint를 transaction.pure.u64에 전달한다.
    return result;
}

// 입금·출금·거래 요청처럼 양수가 필요한 값인지 확인한다.
function requirePositiveU64(value, label) {
    // 먼저 공통 u64 형식과 범위를 검사한다.
    const result = requireU64(value, label);

    // 0원 입금, 0원 출금, 0원 거래 요청은 의미가 없으므로 차단한다.
    if (result === 0n) {
        throw new Error(`${label} must be greater than zero.`);
    }

    // 1 이상인 검증된 bigint를 호출자에게 돌려준다.
    return result;
}

function requireSignalId(value) {
    const bytes = typeof value === 'string'
        ? new TextEncoder().encode(value)
        : value;
    if (!(bytes instanceof Uint8Array) || bytes.length === 0 || bytes.length > 128) {
        throw new Error('signalId must encode to between 1 and 128 bytes.');
    }
    return Array.from(bytes);
}

// 모든 Vault moveCall에서 공통으로 사용하는 Transaction 생성 함수다.
// 이 함수는 네트워크에 전송하지 않고 서명 전 Transaction만 반환한다.
function buildVaultMoveCall({
    // 실제 네트워크에 배포된 agent_market package 주소
    packageId,
    // investment_vault.move에서 호출할 public 함수 이름
    functionName,
    // 각 함수에 필요한 arguments 배열을 만드는 콜백
    buildArguments,
}) {
    // 아직 명령이 없는 빈 Sui Transaction을 만든다.
    const transaction = new Transaction();

    // 빈 Transaction에 investment_vault Move 함수 호출 명령을 한 개 추가한다.
    transaction.moveCall({
        // 어느 Move package를 호출할지 지정한다.
        package: requirePackageId(packageId),
        // package 내부의 investment_vault 모듈을 지정한다.
        module: VAULT_MODULE,
        // create_vault, deposit_more 같은 실제 Move 함수명을 지정한다.
        function: functionName,
        // Move 제네릭 순서에 맞춰 FiatT와 CryptoT를 전달한다.
        typeArguments: [
            requireCoinType(AGORA_FIAT_COIN_TYPE), // 🆕 사용자가 아닌 Agora USDC 설정
            requireCoinType(AGORA_CRYPTO_COIN_TYPE), // 🔄 사용자가 아닌 Agora 설정 사용
        ],
        // 같은 Transaction을 사용해 object, Coin, pure 값을 만든다.
        arguments: buildArguments(transaction),
    });

    // 아직 실행하지 않고 UI가 지갑에 넘길 Transaction 객체만 반환한다.
    return transaction;
}

// 사용자 USDC 입금과 Agora 기본 설정으로 UserVault<FiatT, CryptoT>를 만든다.
// CryptoT 잔액은 0으로 시작하며 향후 성공한 BUY 결과로만 증가해야 한다.
export function buildCreateVaultTransaction({
    // 생략하면 NEXT_PUBLIC_AGENT_MARKET_PACKAGE_ID를 사용한다.
    packageId = PACKAGE_ID,
    // Vault를 만들 때 사용자가 처음 넣을 최소 단위 금액
    depositAmount,
    // 거래 요청 한 건에서 허용할 최대 금액
    maxTradeAmount,
    // 현재 epoch 전체에서 허용할 누적 요청 금액
    maxEpochTradeAmount,
    // CryptoT 1회 매도 요청 최대 수량
    maxCryptoSellAmount,
    // 한 epoch 동안 매도할 수 있는 CryptoT 누적 수량
    maxEpochCryptoSellAmount,
}) {
    // 최초 입금액을 양수 u64로 검증하고 bigint로 통일한다.
    const deposit = requirePositiveU64(
        depositAmount,
        'depositAmount',
    );

    // 1회 거래 한도를 양수 u64로 검증한다.
    const tradeLimit = requirePositiveU64(
        maxTradeAmount,
        'maxTradeAmount',
    );

    // epoch 누적 한도를 양수 u64로 검증한다.
    const epochLimit = requirePositiveU64(
        maxEpochTradeAmount,
        'maxEpochTradeAmount',
    );

    const cryptoSellLimit = requirePositiveU64(
        maxCryptoSellAmount,
        'maxCryptoSellAmount',
    );

    const epochCryptoSellLimit = requirePositiveU64(
        maxEpochCryptoSellAmount,
        'maxEpochCryptoSellAmount',
    );

    // 1회 한도가 전체 epoch 한도보다 크면 설정 자체가 모순이므로 미리 차단한다.
    // Move의 create_vault도 같은 조건을 다시 검사해 최종 보안을 담당한다.
    if (tradeLimit > epochLimit) {
        throw new Error(
            'maxTradeAmount cannot exceed maxEpochTradeAmount.',
        );
    }

    if (cryptoSellLimit > epochCryptoSellLimit) {
        throw new Error(
            'maxCryptoSellAmount cannot exceed maxEpochCryptoSellAmount.',
        );
    }

    // 검증된 값으로 investment_vault::create_vault 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        // 공통 빌더에 배포된 package 주소를 전달한다.
        packageId,
        // 호출 대상은 Move의 public fun create_vault다.
        functionName: 'create_vault',
        // create_vault가 요구하는 Move 인자 배열을 만든다.
        buildArguments: (transaction) => {
            // 사용자의 보유 코인에서 정확히 deposit만큼 Coin<T> 입력을 준비한다.
            const depositCoin = transaction.coin({
                // 사용자가 선택하지 않는 Agora 배포 USDC 타입을 사용한다.
                type: AGORA_FIAT_COIN_TYPE, // 🔄 사용자 coinType 입력 제거
                // Coin<T>에 담을 최소 단위 금액을 지정한다.
                balance: deposit,
            });

            // Move 함수 선언 순서와 정확히 같은 순서로 인자를 반환한다.
            return [
                // 1번 인자: deposit: Coin<T>
                depositCoin,

                // 2번 인자: agora_agent_operator: address
                transaction.pure.address(
                    // AgoraAgent 주소를 검증한 다음 Move address 값으로 직렬화한다.
                    requireAddress(
                        AGORA_AGENT_OPERATOR, // 🔄 사용자 입력 없이 AgoraAgent 자동 연결
                        'NEXT_PUBLIC_AGORA_AGENT_OPERATOR',
                    ),
                ),

                // 3번 인자: max_trade_amount: u64
                transaction.pure.u64(tradeLimit),

                // 4번 인자: max_epoch_trade_amount: u64
                transaction.pure.u64(epochLimit),

                // 5번 인자: max_crypto_sell_amount: u64
                transaction.pure.u64(cryptoSellLimit),

                // 6번 인자: max_epoch_crypto_sell_amount: u64
                transaction.pure.u64(epochCryptoSellLimit),

                // 7번 ctx는 Sui가 자동 주입하므로 배열에 넣지 않는다.
            ];
        },
    });
}

// owner가 기존 Vault에 같은 타입의 Coin<T>를 추가 입금한다.
// Move: deposit_more<T>(vault, deposit, ctx)
export function buildDepositMoreTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // 추가 입금할 shared UserVault<T>의 object ID
    vaultId,
    // 추가로 입금할 최소 단위 금액
    amount,
}) {
    // 0보다 큰 u64 입금액인지 검사한다.
    const depositAmount = requirePositiveU64(
        amount,
        'amount',
    );

    // investment_vault::deposit_more 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        // Move의 public fun deposit_more를 호출한다.
        functionName: 'deposit_more',
        // Move 인자 순서: vault, deposit. ctx는 자동 주입된다.
        buildArguments: (transaction) => [
            // 1번 인자: vaultId를 &mut UserVault<T> object 입력으로 만든다.
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: 사용자의 코인에서 amount만큼 Coin<T>를 준비한다.
            transaction.coin({
                type: AGORA_FIAT_COIN_TYPE, // 🔄 USDC 타입은 Agora 설정으로 고정
                balance: depositAmount,
            }),
        ],
    });
}

// owner가 Vault의 전체 잔액을 출금한다.
// Move: withdraw_all_assets<T>(vault, ctx)
export function buildWithdrawAllTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // 전체 출금할 shared Vault object ID
    vaultId,
}) {
    // investment_vault::withdraw_all_assets 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        // Move의 전체 출금 함수를 지정한다.
        functionName: 'withdraw_all_assets',
        // 이 Move 함수의 명시적 입력은 vault 하나뿐이다.
        buildArguments: (transaction) => [
            // vaultId를 수정 가능한 shared UserVault<T> 입력으로 만든다.
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // ctx는 자동 주입되며 owner 검사는 Move가 수행한다.
        ],
    });
}

// owner가 amount만큼 일부 잔액을 출금한다.
// Move: withdraw_amount<T>(vault, amount, ctx)
export function buildWithdrawAmountTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // 일부 출금할 shared Vault object ID
    vaultId,
    // 출금할 최소 단위 금액
    amount,
}) {
    // 0보다 큰 u64 출금액인지 검사한다.
    const withdrawAmount = requirePositiveU64(
        amount,
        'amount',
    );

    // investment_vault::withdraw_amount 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        functionName: 'withdraw_amount',
        // Move 인자 순서: vault, amount. ctx는 자동 주입된다.
        buildArguments: (transaction) => [
            // 1번 인자: 수정할 UserVault<T> object
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: amount를 Move u64 값으로 직렬화한다.
            transaction.pure.u64(withdrawAmount),
        ],
    });
}

// owner가 Vault의 crypto_balance에서 일부 금액을 출금한다.
// Move: withdraw_crypto_amount<FiatT, CryptoT>(vault, amount, ctx)
export function buildWithdrawCryptoAmountTransaction({
    packageId = PACKAGE_ID,
    vaultId,
    amount,
}) {
    const withdrawAmount = requirePositiveU64(amount, 'amount');

    return buildVaultMoveCall({
        packageId,
        functionName: 'withdraw_crypto_amount',
        buildArguments: (transaction) => [
            // 1번 인자: 수정할 shared UserVault<FiatT, CryptoT>
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: crypto_balance에서 분리할 수량
            transaction.pure.u64(withdrawAmount),
        ],
    });
}

// owner가 AgoraAgent의 거래 권한을 중지한다.
// Move: revoke_agent<T>(vault, ctx)
export function buildRevokeAgentTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // AgoraAgent 권한을 중지할 Vault object ID
    vaultId,
}) {
    // investment_vault::revoke_agent 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        // 이 Move 함수는 AgoraAgent 상태를 PAUSED로 변경한다.
        functionName: 'revoke_agent',
        // 명시적 Move 인자는 vault 하나이며 ctx는 자동 주입된다.
        buildArguments: (transaction) => [
            // 변경할 shared Vault를 object 입력으로 만든다.
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),
        ],
    });
}

// owner가 현재 등록된 AgoraAgent를 다시 활성화한다.
// Move: reactivate_agent<T>(vault, ctx)
export function buildReactivateAgentTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // AgoraAgent 권한을 다시 켤 Vault object ID
    vaultId,
}) {
    // investment_vault::reactivate_agent 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        // 이 Move 함수는 현재 AgoraAgent 주소를 유지하고 ACTIVE로 만든다.
        functionName: 'reactivate_agent',
        buildArguments: (transaction) => [
            // 변경할 shared Vault를 object 입력으로 만든다.
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),
        ],
    });
}

// owner가 AgoraAgent 운영 주소를 새 주소로 교체한다.
// Move: replace_agent<T>(vault, new_agora_agent_operator, ctx)
export function buildReplaceAgentTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // AgoraAgent를 교체할 Vault object ID
    vaultId,
}) {
    // investment_vault::replace_agent 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        // 이 Move 함수는 주소 교체와 동시에 AgoraAgent를 ACTIVE로 만든다.
        functionName: 'replace_agent',
        // Move 인자 순서: vault, new_agora_agent_operator
        buildArguments: (transaction) => [
            // 1번 인자: 수정할 UserVault<T>
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: 검증한 새 AgoraAgent 주소를 Move address로 직렬화한다.
            transaction.pure.address(
                requireAddress(
                    AGORA_AGENT_OPERATOR, // 🔄 사용자 선택 없이 최신 AgoraAgent 설정으로 교체
                    'NEXT_PUBLIC_AGORA_AGENT_OPERATOR',
                ),
            ),
        ],
    });
}

// owner가 한 번의 거래 요청 한도를 변경한다.
// Move: update_trade_limit<T>(vault, new_max_trade_amount, ctx)
export function buildUpdateTradeLimitTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // 1회 한도를 변경할 Vault object ID
    vaultId,
    // 새 max_trade_amount 최소 단위 값
    newLimit,
}) {
    // 현재 JS 정책에서는 1회 한도를 0보다 큰 u64로 제한한다.
    const limit = requirePositiveU64(
        newLimit,
        'newLimit',
    );

    // investment_vault::update_trade_limit 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        functionName: 'update_trade_limit',
        // Move 인자 순서: vault, new_max_trade_amount
        buildArguments: (transaction) => [
            // 1번 인자: 수정할 UserVault<T>
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: 새 1회 한도를 Move u64로 직렬화한다.
            transaction.pure.u64(limit),
        ],
    });
}

// owner가 현재 epoch의 누적 거래 요청 한도를 변경한다.
// Move: update_epoch_trade_limit<T>(vault, new_limit, ctx)
export function buildUpdateEpochTradeLimitTransaction({
    // 호출할 배포 package ID
    packageId = PACKAGE_ID,
    // epoch 한도를 변경할 Vault object ID
    vaultId,
    // 새 max_epoch_trade_amount 최소 단위 값
    newLimit,
}) {
    // 0도 허용한다. 새 epoch에서 0으로 설정하면 거래 요청을 막을 수 있다.
    // 현재 epoch에서 이미 사용한 금액보다 작으면 Move 함수가 실패한다.
    const limit = requireU64(newLimit, 'newLimit');

    // investment_vault::update_epoch_trade_limit 호출 Transaction을 만든다.
    return buildVaultMoveCall({
        packageId,
        functionName: 'update_epoch_trade_limit',
        // Move 인자 순서: vault, new_limit
        buildArguments: (transaction) => [
            // 1번 인자: 수정할 UserVault<T>
            transaction.object(
                requireAddress(vaultId, 'vaultId'),
            ),

            // 2번 인자: 새 epoch 한도를 Move u64로 직렬화한다.
            transaction.pure.u64(limit),
        ],
    });
}

// AgoraAgent가 FiatT -> CryptoT BUY 요청을 기록한다.
// BUY 금액은 반드시 fiat_balance와 fiat 전용 한도만 검사한다.
export function buildRequestBuyTransaction() {
    throw new Error(
        'Direct request_buy is internal. Use buildExecuteBuyTransaction.',
    );
}

// 기존 FE 이름을 유지하지만 동작은 항상 FiatT BUY다.
export const buildRequestTradeTransaction =
    buildRequestBuyTransaction;

// AgoraAgent가 CryptoT -> FiatT SELL 요청을 기록한다.
// SELL 수량은 반드시 crypto_balance와 crypto 전용 한도만 검사한다.
// CryptoT는 사용자 입력이 아니라 Agora 배포 설정의 AGORA_CRYPTO_COIN_TYPE을 사용한다.
export function buildRequestSellTransaction() {
    throw new Error(
        'Direct request_sell is internal. Use buildExecuteSellTransaction.',
    );
}

// build... 함수가 반환한 Transaction을 연결된 Sui 지갑으로 전송한다.
// 이 단계에서 사용자 승인 창이 열리고, 승인 후 네트워크에 제출된다.
export async function executeVaultTransaction({
    // React의 useDAppKit()으로 얻는 현재 지갑 연결 객체
    dAppKit,
    // 위 build... 함수 중 하나가 반환한 Sui Transaction
    transaction,
    // 선택 사항: 특정 연결 계정으로 서명할 때 전달한다.
    account,
}) {
    // 지갑이 연결되지 않았거나 잘못된 객체를 전달한 경우 실행 전에 차단한다.
    if (!dAppKit?.signAndExecuteTransaction) {
        throw new Error(
            'A connected dAppKit instance is required.',
        );
    }

    // 일반 객체가 아니라 SDK가 만든 Transaction인지 검사한다.
    if (!(transaction instanceof Transaction)) {
        throw new Error(
            'transaction must be a Sui Transaction.',
        );
    }

    // 지갑에 서명 요청을 보내고, 승인되면 Sui 네트워크에서 실행한다.
    // account가 undefined면 dAppKit이 현재 선택된 계정을 사용한다.
    return dAppKit.signAndExecuteTransaction({
        transaction,
        account,
    });
}

// Owner가 원자적 주문 실행에 적용할 Vault 안전 정책을 설정한다.
export function buildConfigureExecutionPolicyTransaction({
    packageId = PACKAGE_ID,
    vaultId,
    allowedPool,
    maxDailyFiatVolume,
    maxPositionSize,
    maxLossAmount,
    tradingStartMinuteUtc = 0,
    tradingEndMinuteUtc = 0,
    maxSignalDelayMs,
    maxPriceDeviationBps,
}) {
    return buildVaultMoveCall({
        packageId,
        functionName: 'configure_execution_policy',
        buildArguments: (transaction) => [
            transaction.object(requireAddress(vaultId, 'vaultId')),
            transaction.pure.address(requireAddress(allowedPool, 'allowedPool')),
            transaction.pure.u64(requirePositiveU64(maxDailyFiatVolume, 'maxDailyFiatVolume')),
            transaction.pure.u64(requirePositiveU64(maxPositionSize, 'maxPositionSize')),
            transaction.pure.u64(requireU64(maxLossAmount, 'maxLossAmount')),
            transaction.pure.u64(requireU64(tradingStartMinuteUtc, 'tradingStartMinuteUtc')),
            transaction.pure.u64(requireU64(tradingEndMinuteUtc, 'tradingEndMinuteUtc')),
            transaction.pure.u64(requirePositiveU64(maxSignalDelayMs, 'maxSignalDelayMs')),
            transaction.pure.u64(requireU64(maxPriceDeviationBps, 'maxPriceDeviationBps')),
        ],
    });
}

function buildAtomicOrderTransaction({
    packageId,
    functionName,
    vaultId,
    poolId,
    amount,
    minAmountOut,
    signalId,
    signalTimestampMs,
    signalPriceE9,
    deadlineMs,
}) {
    const transaction = new Transaction();
    transaction.moveCall({
        package: requirePackageId(packageId),
        module: ORDER_EXECUTOR_MODULE,
        function: functionName,
        typeArguments: [
            requireCoinType(AGORA_FIAT_COIN_TYPE),
            requireCoinType(AGORA_CRYPTO_COIN_TYPE),
        ],
        arguments: [
            transaction.object(requireAddress(vaultId, 'vaultId')),
            transaction.object(requireAddress(poolId, 'poolId')),
            transaction.pure.u64(requirePositiveU64(amount, 'amount')),
            transaction.pure.u64(requirePositiveU64(minAmountOut, 'minAmountOut')),
            transaction.pure.vector('u8', requireSignalId(signalId)),
            transaction.pure.u64(requireU64(signalTimestampMs, 'signalTimestampMs')),
            transaction.pure.u64(requirePositiveU64(signalPriceE9, 'signalPriceE9')),
            transaction.pure.u64(requireU64(deadlineMs, 'deadlineMs')),
            transaction.object(CLOCK_OBJECT_ID),
        ],
    });
    return transaction;
}

export function buildExecuteBuyTransaction(params) {
    return buildAtomicOrderTransaction({
        ...params,
        packageId: params.packageId ?? PACKAGE_ID,
        functionName: 'execute_buy',
    });
}

export function buildExecuteSellTransaction(params) {
    return buildAtomicOrderTransaction({
        ...params,
        packageId: params.packageId ?? PACKAGE_ID,
        functionName: 'execute_sell',
    });
}

// 이전 통합 함수명은 호환 안내를 위해 남겨 둔다.
// 실제 거래에는 방향별 buildExecuteBuyTransaction 또는
// buildExecuteSellTransaction을 사용해야 한다.
export function buildVaultDexTradeTransaction() {
    // 잘못된 구형 호출로 사용자가 가스를 낭비하지 않도록 즉시 차단한다.
    throw new Error(
        'Use buildExecuteBuyTransaction or buildExecuteSellTransaction.',
    );
}

/*
Vault_Dex.js 함수 workflow

1. UI가 buildCreateVaultTransaction을 호출한다.
2. buildCreateVaultTransaction이 buildVaultMoveCall을 호출한다.
3. buildVaultMoveCall이 Transaction과 create_vault MoveCall을 만든다.
4. UI가 executeVaultTransaction을 호출한다.
5. 연결된 지갑이 트랜잭션을 사용자에게 승인받는다.
6. Sui 네트워크가 investment_vault::create_vault를 실행한다.
7. 이후 owner의 입금·출금·AgoraAgent 관리는 각각 해당 build 함수를 사용한다.
8. AgoraAgent BUY는 buildRequestBuyTransaction으로 FiatT만 사용한다.
9. AgoraAgent SELL은 buildRequestSellTransaction으로 CryptoT만 사용한다.
10. 현재 두 함수는 실제 DEX swap이 아니라 검증·누적·이벤트 기록만 한다.
11. 실제 DEX 연결은 Move의 execute_buy/execute_sell이 구현된 뒤
    buildVaultDexTradeTransaction에 추가한다.

공통 구조:

UI 행동
  → build...Transaction
  → Transaction 생성
  → executeVaultTransaction
  → 지갑 서명
  → Sui 네트워크
  → investment_vault.move 실행
*/
