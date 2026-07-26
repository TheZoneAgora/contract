// @ts-check

import { Transaction } from '@mysten/sui/transactions';
import {
    isValidSuiAddress,
    normalizeStructTag,
    normalizeSuiAddress,
} from '@mysten/sui/utils';

const PAYMENT_HEADER = 'PAYMENT-SIGNATURE';
const CLOCK_OBJECT_ID = '0x6';
const MAX_U64 = (1n << 64n) - 1n;

/**
 * @typedef {Object} X402Challenge
 * @property {'Payment Required'} error
 * @property {string} price
 * @property {string} payee
 * @property {string} treasury
 * @property {string} token
 * @property {string} signalProviderId
 * @property {string} platformFeeBps
 */

/**
 * @param {unknown} value
 * @param {string} label
 * @returns {string}
 */
function requireAddress(value, label) {
    if (typeof value !== 'string') {
        throw new Error(`${label} must be a string.`);
    }

    const normalized = normalizeSuiAddress(value);
    if (!isValidSuiAddress(normalized)) {
        throw new Error(`${label} must be a valid Sui address.`);
    }

    return normalized;
}

/**
 * @param {unknown} value
 * @param {string} label
 * @param {boolean} [allowZero]
 * @returns {bigint}
 */
function requireU64(value, label, allowZero = false) {
    let parsed;

    try {
        parsed = BigInt(/** @type {string | number | bigint} */ (value));
    } catch {
        throw new Error(`${label} must be an integer.`);
    }

    if (
        parsed < 0n ||
        parsed > MAX_U64 ||
        (!allowZero && parsed === 0n)
    ) {
        throw new Error(
            `${label} must be ${allowZero ? 'a' : 'a positive'} u64.`,
        );
    }

    return parsed;
}

/**
 * @param {Response} response
 * @returns {Promise<unknown>}
 */
async function readResponseBody(response) {
    const contentType = response.headers.get('content-type') ?? '';

    if (contentType.includes('application/json')) {
        return response.json();
    }

    return response.text();
}

/**
 * @param {unknown} value
 * @returns {X402Challenge}
 */
function parseChallenge(value) {
    if (typeof value !== 'object' || value === null) {
        throw new Error('The Signal Provider returned an invalid x402 response body.'); // 🔄 Agent → Signal Provider
    }

    const body = /** @type {Record<string, unknown>} */ (value);
    if (
        body.error !== 'Payment Required' ||
        typeof body.price !== 'string' ||
        typeof body.payee !== 'string' ||
        typeof body.treasury !== 'string' ||
        typeof body.token !== 'string' ||
        typeof body.signalProviderId !== 'string' ||
        typeof body.platformFeeBps !== 'string'
    ) {
        throw new Error('The Signal Provider returned an incomplete x402 challenge.'); // 🔄 Agent → Signal Provider
    }

    return /** @type {X402Challenge} */ (body);
}

/**
 * @param {unknown} result
 * @returns {string}
 */
function getExecutionDigest(result) {
    if (typeof result !== 'object' || result === null) {
        throw new Error('The wallet returned an invalid execution result.');
    }

    const value = /** @type {Record<string, any>} */ (result);

    if (value.FailedTransaction) {
        const reason =
            value.FailedTransaction.status?.error?.message ??
            value.FailedTransaction.status?.error ??
            'Unknown Sui execution failure';
        throw new Error(`x402 payment transaction failed: ${reason}`);
    }

    const digest = value.digest ?? value.Transaction?.digest;
    if (typeof digest !== 'string' || digest.length === 0) {
        throw new Error('The wallet result did not contain a Tx Digest.');
    }

    return digest;
}

/**
 * Creates the on-chain x402 payment transaction.
 *
 * @param {Object} params
 * @param {string} params.packageId
 * @param {X402Challenge} params.challenge
 * @returns {Transaction}
 */
export function buildSignalProviderUsagePaymentTransaction({ // 🔄 사용자 Agent 결제 → AgoraAgent 신호 구매
    packageId,
    challenge,
}) {
    const normalizedPackageId = requireAddress(packageId, 'packageId');
    const price = requireU64(challenge.price, 'price');
    const platformFeeBps = requireU64(
        challenge.platformFeeBps,
        'platformFeeBps',
        true,
    );

    if (platformFeeBps > 10_000n) {
        throw new Error('platformFeeBps cannot exceed 10000.');
    }

    let token;
    try {
        token = normalizeStructTag(challenge.token);
    } catch {
        throw new Error('token must be a fully qualified Move coin type.');
    }

    const transaction = new Transaction();

    transaction.moveCall({
        target: `${normalizedPackageId}::payment_splitter::pay_signal_provider_usage_fee`, // 🔄 신호 구매 전용 Move 함수
        typeArguments: [token],
        arguments: [
            transaction.coin({
                type: token,
                balance: price,
            }),
            transaction.pure.address(
                requireAddress(
                    challenge.signalProviderId,
                    'signalProviderId',
                ), // 🔄 AgoraAgent가 선택한 Provider ID
            ),
            transaction.pure.address(
                requireAddress(challenge.payee, 'payee'),
            ),
            transaction.pure.address(
                requireAddress(challenge.treasury, 'treasury'),
            ),
            transaction.pure.u64(platformFeeBps),
            transaction.object(CLOCK_OBJECT_ID),
        ],
    });

    return transaction;
}

/**
 * AgoraAgent가 외부 Signal Provider의 HTTP API를 x402로 호출한다.
 *
 * 사용자의 연결 지갑은 사용하지 않는다. AgoraAgent 운영 signer가 신호 비용과
 * 결제 트랜잭션 가스를 부담한다.
 *
 * @param {Object} params
 * @param {string} params.signalProviderApiUrl
 * @param {string} params.vaultId
 * @param {bigint | number | string} params.amount
 * @param {string} params.packageId Deployed agent_market package ID
 * @param {{ signAndExecuteTransaction: Function }} params.agoraSigner
 * @param {typeof fetch} [params.fetchImpl]
 * @returns {Promise<unknown>}
 */
export async function executeSignalProviderWithX402({ // 🔄 사용자 호출 → AgoraAgent 내부 호출
    signalProviderApiUrl,
    vaultId,
    amount,
    packageId,
    agoraSigner, // 🔄 사용자 dAppKit → AgoraAgent 운영 signer
    fetchImpl = fetch,
}) {
    if (
        typeof signalProviderApiUrl !== 'string' ||
        !signalProviderApiUrl
    ) {
        throw new Error('signalProviderApiUrl is required.');
    }

    const normalizedVaultId = requireAddress(vaultId, 'vaultId');
    const tradeAmount = requireU64(amount, 'amount');

    if (!agoraSigner?.signAndExecuteTransaction) {
        throw new Error('An AgoraAgent signer is required.'); // 🔄 사용자 지갑 요구 제거
    }

    const requestBody = JSON.stringify({
        vaultId: normalizedVaultId,
        amount: tradeAmount.toString(),
    });

    let initialResponse;
    try {
        initialResponse = await fetchImpl(signalProviderApiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: requestBody,
        });
    } catch (error) {
        throw new Error('Could not reach the Signal Provider API.', {
            cause: error,
        });
    }

    if (initialResponse.status !== 402) {
        const result = await readResponseBody(initialResponse);
        if (!initialResponse.ok) {
            throw new Error(
                `Signal Provider API failed before payment (${initialResponse.status}): ${JSON.stringify(result)}`,
            );
        }

        return result;
    }

    const challenge = parseChallenge(
        await readResponseBody(initialResponse),
    );
    const paymentTransaction =
        buildSignalProviderUsagePaymentTransaction({ // 🔄 AgoraAgent 결제 트랜잭션
            packageId,
            challenge,
        });

    let paymentResult;
    try {
        paymentResult = await agoraSigner.signAndExecuteTransaction({ // 🔄 AgoraAgent가 코인·가스 지불
            transaction: paymentTransaction,
        });
    } catch (error) {
        throw new Error(
            'x402 payment failed. Check the AgoraAgent token and SUI gas balances.',
            { cause: error },
        );
    }

    const paymentDigest = getExecutionDigest(paymentResult);

    let paidResponse;
    try {
        paidResponse = await fetchImpl(signalProviderApiUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                [PAYMENT_HEADER]: paymentDigest,
            },
            body: requestBody,
        });
    } catch (error) {
        throw new Error(
            `Payment ${paymentDigest} succeeded, but the paid Signal Provider request could not be delivered.`,
            { cause: error },
        );
    }

    const finalResult = await readResponseBody(paidResponse);
    if (!paidResponse.ok) {
        throw new Error(
            `Paid Signal Provider request failed (${paidResponse.status}): ${JSON.stringify(finalResult)}`,
        );
    }

    return finalResult;
}
