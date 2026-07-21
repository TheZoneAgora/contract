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
 * @property {string} agentId
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
        throw new Error('The Agent returned an invalid x402 response body.');
    }

    const body = /** @type {Record<string, unknown>} */ (value);
    if (
        body.error !== 'Payment Required' ||
        typeof body.price !== 'string' ||
        typeof body.payee !== 'string' ||
        typeof body.treasury !== 'string' ||
        typeof body.token !== 'string' ||
        typeof body.agentId !== 'string' ||
        typeof body.platformFeeBps !== 'string'
    ) {
        throw new Error('The Agent returned an incomplete x402 challenge.');
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
export function buildAgentUsagePaymentTransaction({
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
        target: `${normalizedPackageId}::payment_splitter::pay_agent_usage_fee`,
        typeArguments: [token],
        arguments: [
            transaction.coin({
                type: token,
                balance: price,
            }),
            transaction.pure.address(
                requireAddress(challenge.agentId, 'agentId'),
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
 * Executes an Agent HTTP request using this project's digest-based x402 flow.
 *
 * `dAppKit` is required because JavaScript can build a transaction but cannot
 * authorize the user's coin payment without a connected wallet signature.
 *
 * @param {Object} params
 * @param {string} params.agentApiUrl
 * @param {string} params.vaultId
 * @param {bigint | number | string} params.amount
 * @param {string} params.packageId Deployed agent_market package ID
 * @param {{ signAndExecuteTransaction: Function }} params.dAppKit
 * @param {unknown} [params.account]
 * @param {typeof fetch} [params.fetchImpl]
 * @returns {Promise<unknown>}
 */
export async function executeAgentWithX402({
    agentApiUrl,
    vaultId,
    amount,
    packageId,
    dAppKit,
    account,
    fetchImpl = fetch,
}) {
    if (typeof agentApiUrl !== 'string' || !agentApiUrl) {
        throw new Error('agentApiUrl is required.');
    }

    const normalizedVaultId = requireAddress(vaultId, 'vaultId');
    const tradeAmount = requireU64(amount, 'amount');

    if (!dAppKit?.signAndExecuteTransaction) {
        throw new Error('A connected dAppKit wallet is required.');
    }

    const requestBody = JSON.stringify({
        vaultId: normalizedVaultId,
        amount: tradeAmount.toString(),
    });

    let initialResponse;
    try {
        initialResponse = await fetchImpl(agentApiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: requestBody,
        });
    } catch (error) {
        throw new Error('Could not reach the Agent API.', { cause: error });
    }

    if (initialResponse.status !== 402) {
        const result = await readResponseBody(initialResponse);
        if (!initialResponse.ok) {
            throw new Error(
                `Agent API failed before payment (${initialResponse.status}): ${JSON.stringify(result)}`,
            );
        }

        return result;
    }

    const challenge = parseChallenge(
        await readResponseBody(initialResponse),
    );
    const paymentTransaction = buildAgentUsagePaymentTransaction({
        packageId,
        challenge,
    });

    let paymentResult;
    try {
        paymentResult = await dAppKit.signAndExecuteTransaction({
            transaction: paymentTransaction,
            account,
        });
    } catch (error) {
        throw new Error(
            'x402 payment failed. Check the token balance and SUI gas balance.',
            { cause: error },
        );
    }

    const paymentDigest = getExecutionDigest(paymentResult);

    let paidResponse;
    try {
        paidResponse = await fetchImpl(agentApiUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                [PAYMENT_HEADER]: paymentDigest,
            },
            body: requestBody,
        });
    } catch (error) {
        throw new Error(
            `Payment ${paymentDigest} succeeded, but the paid Agent request could not be delivered.`,
            { cause: error },
        );
    }

    const finalResult = await readResponseBody(paidResponse);
    if (!paidResponse.ok) {
        throw new Error(
            `Paid Agent request failed (${paidResponse.status}): ${JSON.stringify(finalResult)}`,
        );
    }

    return finalResult;
}
