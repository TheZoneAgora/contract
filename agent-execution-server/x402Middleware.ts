import type { NextFunction, Request, RequestHandler, Response } from 'express';
import { SuiJsonRpcClient } from '@mysten/sui/jsonRpc';
import {
    fromBase58,
    isValidSuiAddress,
    isValidTransactionDigest,
    normalizeStructTag,
    normalizeSuiAddress,
} from '@mysten/sui/utils';

const PAYMENT_HEADER = 'PAYMENT-SIGNATURE';
const PAYMENT_EVENT_MODULE = 'payment_splitter';
const PAYMENT_EVENT_NAME = 'SignalPaymentReceiptEvent'; // 🔄 신호 구매 전용 이벤트
const BPS_DENOMINATOR = 10_000n;

type PaymentReceiptFields = {
    payer: string;
    payee: string;
    treasury: string;
    signal_provider_id: string; // 🔄 사용자 선택 Agent ID 제거
    amount: string;
    platform_fee_amount: string;
    digest: number[];
    timestamp: string;
};

export type PaymentChallenge = {
    error: 'Payment Required';
    price: string;
    payee: string;
    treasury: string;
    token: string;
    signalProviderId: string; // 🔄 AgoraAgent가 선택한 Provider ID
    platformFeeBps: string;
};

/**
 * Production deployments should implement this interface with Redis or a DB
 * that has a UNIQUE constraint on the digest. That prevents replay across
 * multiple server processes and after restarts.
 */
export interface PaymentReplayStore {
    claim(digest: string): Promise<boolean>;
}

export class InMemoryPaymentReplayStore implements PaymentReplayStore {
    readonly #usedDigests = new Set<string>();

    async claim(digest: string): Promise<boolean> {
        if (this.#usedDigests.has(digest)) {
            return false;
        }

        this.#usedDigests.add(digest);
        return true;
    }
}

export type X402MiddlewareOptions = {
    rpcUrl: string;
    network?: 'mainnet' | 'testnet' | 'devnet' | 'localnet';
    packageId: string;
    agoraAgentAddress: string; // 🆕 x402 결제를 허용할 AgoraAgent 운영 주소
    signalProviderId: string; // 🔄 사용자 입력이 아닌 Agora 내부 설정
    price: bigint | string;
    payee: string;
    treasury: string;
    token: string;
    platformFeeBps?: bigint | string;
    maxPaymentAgeMs?: number;
    client?: SuiJsonRpcClient;
    replayStore?: PaymentReplayStore;
};

type NormalizedOptions = {
    packageId: string;
    agoraAgentAddress: string; // 🆕 영수증 payer 검증 기준
    signalProviderId: string;
    price: bigint;
    payee: string;
    treasury: string;
    token: string;
    platformFeeBps: bigint;
    maxPaymentAgeMs: number;
    client: SuiJsonRpcClient;
    replayStore: PaymentReplayStore;
};

function parsePositiveU64(value: bigint | string, label: string): bigint {
    let parsed: bigint;

    try {
        parsed = BigInt(value);
    } catch {
        throw new Error(`${label} must be an integer.`);
    }

    if (parsed <= 0n || parsed > 0xffff_ffff_ffff_ffffn) {
        throw new Error(`${label} must be a positive u64.`);
    }

    return parsed;
}

function requireSuiAddress(value: string, label: string): string {
    const normalized = normalizeSuiAddress(value);

    if (!isValidSuiAddress(normalized)) {
        throw new Error(`${label} must be a valid Sui address.`);
    }

    return normalized;
}

function normalizeOptions(options: X402MiddlewareOptions): NormalizedOptions {
    const platformFeeBps = BigInt(options.platformFeeBps ?? 2_000);

    if (platformFeeBps < 0n || platformFeeBps > BPS_DENOMINATOR) {
        throw new Error('platformFeeBps must be between 0 and 10000.');
    }

    const maxPaymentAgeMs = options.maxPaymentAgeMs ?? 5 * 60_000;
    if (!Number.isSafeInteger(maxPaymentAgeMs) || maxPaymentAgeMs <= 0) {
        throw new Error('maxPaymentAgeMs must be a positive safe integer.');
    }

    const network = options.network ?? 'testnet';

    return {
        packageId: requireSuiAddress(options.packageId, 'packageId'),
        agoraAgentAddress: requireSuiAddress(
            options.agoraAgentAddress,
            'agoraAgentAddress',
        ), // 🆕 사용자가 아닌 AgoraAgent payer 고정
        signalProviderId: requireSuiAddress(
            options.signalProviderId,
            'signalProviderId',
        ), // 🔄 AgoraAgent가 선택한 Provider 검증
        price: parsePositiveU64(options.price, 'price'),
        payee: requireSuiAddress(options.payee, 'payee'),
        treasury: requireSuiAddress(options.treasury, 'treasury'),
        token: normalizeStructTag(options.token),
        platformFeeBps,
        maxPaymentAgeMs,
        client:
            options.client ??
            new SuiJsonRpcClient({ url: options.rpcUrl, network }),
        replayStore:
            options.replayStore ?? new InMemoryPaymentReplayStore(),
    };
}

function createChallenge(options: NormalizedOptions): PaymentChallenge {
    return {
        error: 'Payment Required',
        price: options.price.toString(),
        payee: options.payee,
        treasury: options.treasury,
        token: options.token,
        signalProviderId: options.signalProviderId, // 🔄 Provider ID challenge
        platformFeeBps: options.platformFeeBps.toString(),
    };
}

function sendPaymentRequired(
    response: Response,
    challenge: PaymentChallenge,
): void {
    response
        .status(402)
        .set('Cache-Control', 'no-store')
        .json(challenge);
}

function isRecord(value: unknown): value is Record<string, unknown> {
    return typeof value === 'object' && value !== null;
}

function parseReceipt(value: unknown): PaymentReceiptFields | null {
    if (!isRecord(value)) {
        return null;
    }

    const digest = value.digest;
    if (
        typeof value.payer !== 'string' ||
        typeof value.payee !== 'string' ||
        typeof value.treasury !== 'string' ||
        typeof value.signal_provider_id !== 'string' || // 🔄 Provider 영수증 필드
        typeof value.amount !== 'string' ||
        typeof value.platform_fee_amount !== 'string' ||
        !Array.isArray(digest) ||
        !digest.every(
            (byte) =>
                Number.isInteger(byte) && byte >= 0 && byte <= 255,
        ) ||
        typeof value.timestamp !== 'string'
    ) {
        return null;
    }

    return value as PaymentReceiptFields;
}

function hasExpectedDigest(
    receiptDigest: number[],
    transactionDigest: string,
): boolean {
    const expected = fromBase58(transactionDigest);

    return (
        receiptDigest.length === expected.length &&
        receiptDigest.every((byte, index) => byte === expected[index])
    );
}

function matchesReceipt(
    receipt: PaymentReceiptFields,
    transactionDigest: string,
    options: NormalizedOptions,
): boolean {
    let amount: bigint;
    let platformFeeAmount: bigint;
    let timestamp: bigint;
    let payer: string;
    let payee: string;
    let treasury: string;
    let signalProviderId: string;

    try {
        amount = BigInt(receipt.amount);
        platformFeeAmount = BigInt(receipt.platform_fee_amount);
        timestamp = BigInt(receipt.timestamp);
        payer = requireSuiAddress(receipt.payer, 'receipt.payer'); // 🆕 payer 주소 검증
        payee = requireSuiAddress(receipt.payee, 'receipt.payee');
        treasury = requireSuiAddress(
            receipt.treasury,
            'receipt.treasury',
        );
        signalProviderId = requireSuiAddress(
            receipt.signal_provider_id,
            'receipt.signal_provider_id',
        ); // 🔄 Provider ID 검증
    } catch {
        return false;
    }

    const expectedPlatformFee =
        (amount / BPS_DENOMINATOR) * options.platformFeeBps +
        ((amount % BPS_DENOMINATOR) * options.platformFeeBps) /
            BPS_DENOMINATOR;
    const now = BigInt(Date.now());
    const maxAge = BigInt(options.maxPaymentAgeMs);

    return (
        payer === options.agoraAgentAddress && // 🆕 AgoraAgent 결제만 승인
        payee === options.payee &&
        treasury === options.treasury &&
        signalProviderId === options.signalProviderId && // 🔄 구매 대상 Provider 일치
        amount === options.price &&
        platformFeeAmount === expectedPlatformFee &&
        timestamp <= now + 30_000n &&
        now - timestamp <= maxAge &&
        hasExpectedDigest(receipt.digest, transactionDigest)
    );
}

/**
 * Verifies AgoraAgent's Sui payment before allowing a Signal Provider route.
 *
 * PAYMENT-SIGNATURE intentionally contains the Sui transaction digest in this
 * project's x402 flow. It is a bearer receipt, so replay protection is required.
 */
export function createX402Middleware(
    input: X402MiddlewareOptions,
): RequestHandler {
    const options = normalizeOptions(input);
    const challenge = createChallenge(options);
    const expectedEventType = normalizeStructTag(
        `${options.packageId}::${PAYMENT_EVENT_MODULE}::${PAYMENT_EVENT_NAME}<${options.token}>`,
    );

    return async function x402Middleware(
        request: Request,
        response: Response,
        next: NextFunction,
    ): Promise<void> {
        const paymentDigest = request.get(PAYMENT_HEADER)?.trim();

        if (!paymentDigest || !isValidTransactionDigest(paymentDigest)) {
            sendPaymentRequired(response, challenge);
            return;
        }

        let transaction;

        try {
            transaction = await options.client.getTransactionBlock({
                digest: paymentDigest,
                options: {
                    showEffects: true,
                    showEvents: true,
                },
            });
        } catch (error) {
            const message =
                error instanceof Error ? error.message : 'Unknown RPC error';

            response.status(503).json({
                error: 'Payment verification unavailable',
                detail: message,
            });
            return;
        }

        if (transaction.effects?.status.status !== 'success') {
            sendPaymentRequired(response, challenge);
            return;
        }

        const matchingReceipt = transaction.events?.find((event) => {
            if (normalizeStructTag(event.type) !== expectedEventType) {
                return false;
            }

            const receipt = parseReceipt(event.parsedJson);
            return (
                receipt !== null &&
                matchesReceipt(receipt, paymentDigest, options)
            );
        });

        if (!matchingReceipt) {
            sendPaymentRequired(response, challenge);
            return;
        }

        // Atomic claim prevents one paid transaction from unlocking the API twice.
        if (!(await options.replayStore.claim(paymentDigest))) {
            sendPaymentRequired(response, challenge);
            return;
        }

        response.locals.x402Payment = {
            digest: paymentDigest,
            receipt: matchingReceipt.parsedJson,
        };

        next();
    };
}
