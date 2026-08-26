// -----------------------------------------------------------------------------
// 이 파일은 전체가 Claude가 작성한 부분입니다 (진웅님이 직접 적은 코드가 아님).
//
// 리뷰 포인트 2개:
//   (1) effects.status 검사가 왜 제일 중요한가 -> PAYMENT_RECEIPT_QUERY 주석
//   (2) 이벤트를 왜 느슨하게(marker) 찾는가     -> RECEIPT_EVENT_MARKER 주석
//
// 확인 완료된 사항 (2026-08-15, testnet):
//   - SuiGraphQLClient(@mysten/sui 2.24.0)는 문자열 쿼리를 그대로 받는다 (codegen 불필요)
//   - transaction(digest:) 는 $digest: String! 변수와 함께 동작한다
//   - 이벤트 모양: contents.type.repr = 제네릭 포함 전체 타입, contents.json = 필드 값
//   - 엔드포인트: https://graphql.testnet.sui.io/graphql
//     (fullnode JSON-RPC는 공용 노드에서 폐기됨 — SuiClient로는 조회가 안 된다)
// -----------------------------------------------------------------------------

import { SuiGraphQLClient } from '@mysten/sui/graphql';

/* transaction(digest:) 은 성공한 tx든 실패한 tx든 똑같이 돌려주므로
   effects.status를 반드시 확인해야 한다. 실패한 tx도 digest를 가지고 체인에 남기
   때문에, 이 검사를 빼먹으면 "결제가 abort된 tx의 digest"로도 신호를 받아갈 수 있다.
*/
const PAYMENT_RECEIPT_QUERY = `
    query PaymentReceipt($digest: String!) {
        transaction(digest: $digest) {
            digest
            effects {
                status
                events {
                    nodes {
                        contents {
                            type { repr }
                            json
                        }
                    }
                }
            }
        }
    }
`;

/* 제네릭 파라미터(<코인타입>)와 Package 주소를 뺀 이벤트 이름.

   일부러 느슨하게 찾는다. 여기서 Package와 코인 타입까지 정확히 맞춰 골라내면
   검증 로직이 이 파일과 assertReceiptMatchesChallenge 두 곳으로 쪼개진다.
   그러면 나중에 한쪽만 고쳤을 때 구멍이 난다.
   이 파일은 "후보 하나 집어오기"만 하고, 맞다/틀리다 판정은 전부 assert 함수 한 곳에 둔다.
*/
const RECEIPT_EVENT_MARKER = '::payment_splitter::SignalPaymentReceiptEvent<';

/* GraphQL 클라이언트를 만든다. 서버 기동 시 한 번만 부르고 재사용한다.

    @param {string} graphqlUrl ex) 'https://graphql.testnet.sui.io/graphql'
    @returns {SuiGraphQLClient}
*/
export function createReceiptReader(graphqlUrl) {
    if (typeof graphqlUrl !== 'string' || graphqlUrl.trim().length === 0) {
        throw new Error('GraphQL url is missing.');
    }

    return new SuiGraphQLClient({ url: graphqlUrl.trim() });
}

/* 결제 tx를 조회해 assertReceiptMatchesChallenge가 먹을 수 있는 모양으로 만든다.

    @param {SuiGraphQLClient} reader
    @param {string} txDigest ex) '7gWwQGCQ32peuV97xftNhbRBmoJ2cSkc8HBAMYxWsDqh'
    @returns {Promise<{
        type: string,               ex) '0x0f5a...8bfa::payment_splitter::SignalPaymentReceiptEvent<0x2::sui::SUI>'
        payer: string,               ex) '0x0000...5678'
        payee: string,               ex) '0x0000...1111'
        treasury: string,            ex) '0x0000...2222'
        signal_provider_id: string,  ex) '0x0000...abcd'
        amount: string,              ex) '1000000'
        platform_fee_amount: string, ex) '200000'
        timestamp: string,           ex) '1786632120000'
    }>}
*/
export async function fetchPaymentReceipt(reader, txDigest) {
    if (typeof txDigest !== 'string' || txDigest.trim().length === 0) {
        throw new Error('Payment digest is missing.');
    }

    const response = await reader.query({
        query: PAYMENT_RECEIPT_QUERY,
        variables: { digest: txDigest.trim() },
    });

    // GraphQL은 실패해도 HTTP 200을 주므로 errors를 직접 봐야 한다.
    if (response.errors?.length) {
        throw new Error(`Payment lookup failed: ${response.errors[0].message}`);
    }

    const transaction = response.data?.transaction;

    if (!transaction) {
        throw new Error('Payment transaction was not found.');
    }

    // 실패한 tx에서는 자금이 움직이지 않았다.
    if (transaction.effects?.status !== 'SUCCESS') {
        throw new Error('Payment transaction did not succeed.');
    }

    const events = transaction.effects.events?.nodes ?? [];

    const receiptEvent = events.find(
        (node) => node.contents?.type?.repr?.includes(RECEIPT_EVENT_MARKER),
    );

    if (!receiptEvent) {
        throw new Error('Payment transaction has no signal payment receipt.');
    }

    const fields = receiptEvent.contents.json;

    return {
        type: receiptEvent.contents.type.repr,
        payer: fields.payer,
        payee: fields.payee,
        treasury: fields.treasury,
        signal_provider_id: fields.signal_provider_id,
        amount: fields.amount,
        platform_fee_amount: fields.platform_fee_amount,
        timestamp: fields.timestamp,
    };
}
