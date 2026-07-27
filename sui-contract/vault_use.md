# Agora UserVault 사용 흐름

최종 갱신: 2026-07-26

현재 Vault는 사용자 자산을 보관하고 AgoraAgent의 권한·거래 한도를 검사한다. 실제 DEX swap은 아직 구현되지 않았으며 BUY/SELL 요청과 이벤트만 기록한다.

## 1. 전체 구조

```text
사용자
├─ 개인 Vault 생성
├─ USDC 예치
└─ Wallet 출금

외부 Signal Provider
└─ x402로 AgoraAgent에 신호 제공

AgoraAgent
├─ 신호 검증·조합
├─ 위험 점수 계산
└─ AgoraInvest BUY/SELL 요청

AgoraInvest
├─ signal_digest 기록
├─ risk_score_bps 기록
└─ UserVault 검사 함수 호출

UserVault
├─ AgoraAgent 주소 검사
├─ ACTIVE/REDUCE_ONLY/PAUSED 검사
├─ 잔액 검사
├─ 1회·epoch 한도 검사
└─ Owner 출금 권한 강제
```

## 2. 사용자가 선택하지 않는 항목

사용자는 다음을 선택하거나 입력하지 않는다.

- 투자 Agent
- Signal Provider
- Follow
- Follow fee
- Fiat coin type
- Crypto coin type
- AgoraAgent 운영 주소

`Vault_Dex.js`는 배포 환경 설정을 사용한다.

```env
NEXT_PUBLIC_AGENT_MARKET_PACKAGE_ID=...
NEXT_PUBLIC_AGORA_AGENT_OPERATOR=...
NEXT_PUBLIC_AGORA_FIAT_COIN_TYPE=...USDC
NEXT_PUBLIC_AGORA_CRYPTO_COIN_TYPE=...
```

Move 내부의 `UserVault<FiatT, CryptoT>` 타입은 타입 안전성을 위해 유지한다. 사용자가 타입을 선택한다는 뜻은 아니다.

## 3. Vault 생성

사용자는 앱에서 USDC 예치 금액과 위험 한도를 설정한다. AgoraAgent 주소와 자산 타입은 앱 배포 설정이 자동으로 넣는다.

Move 함수:

```move
create_vault<FiatT, CryptoT>(
    deposit,
    agora_agent_operator,
    max_trade_amount,
    max_epoch_trade_amount,
    max_crypto_sell_amount,
    max_epoch_crypto_sell_amount,
    ctx,
)
```

초기 상태:

```text
owner = transaction sender
agora_agent_operator = 배포 설정의 AgoraAgent
agora_agent_status = ACTIVE
fiat_balance = 최초 USDC 예치액
crypto_balance = 0
epoch 사용량 = 0
```

Vault는 shared object지만 함수 내부 권한 검사로 Owner와 AgoraAgent 역할을 구분한다.

## 4. 사용자 작업

| 작업 | 함수 | 권한 | 자산 이동 |
| --- | --- | --- | --- |
| 최초 생성·예치 | `create_vault` | 사용자 | USDC → Vault |
| 추가 USDC 예치 | `deposit_more` | Owner | USDC → Vault |
| USDC 일부 출금 | `withdraw_amount` | Owner | Vault → Wallet |
| 투자 자산 일부 출금 | `withdraw_crypto_amount` | Owner | Vault → Wallet |
| 전액 출금 | `withdraw_all_assets` | Owner | Vault → Wallet |
| 완전 중지 | `revoke_agent` | Owner | 없음 |
| 위험 축소 | `set_reduce_only` | Owner | 없음 |
| 재활성화 | `reactivate_agent` | Owner | 없음 |
| AgoraAgent 주소 동기화 | `replace_agent` | Owner | 없음 |
| 거래 한도 변경 | `update_*_limit` | Owner | 없음 |

모든 Owner 작업은 별도 온체인 트랜잭션이다. Sponsored Transaction을 적용하지 않으면 Owner 지갑이 가스를 낸다.

## 5. AgoraAgent 상태

```text
ACTIVE
├─ BUY 허용
└─ SELL 허용

REDUCE_ONLY
├─ BUY 차단
└─ SELL 허용

PAUSED
├─ BUY 차단
└─ SELL 차단
```

- `revoke_agent`는 상태를 `PAUSED`로 만든다.
- `set_reduce_only`는 신규 BUY를 막고 기존 포지션 SELL만 허용한다.
- `reactivate_agent`는 `ACTIVE`로 복구한다.
- 기존 공개 함수 이름은 SDK 호환을 위해 유지한다.

## 6. AgoraInvest BUY

권장 호출:

```move
agora_invest::request_buy(
    vault,
    fiat_amount,
    signal_digest,
    risk_score_bps,
    ctx,
)
```

실행 순서:

```text
signal_digest 비어 있지 않은지 검사
→ risk_score_bps ≤ 10,000 검사
→ Vault의 AgoraAgent 주소 검사
→ ACTIVE 상태 검사
→ epoch 갱신
→ FiatT 1회·epoch 한도 검사
→ fiat_balance 검사
→ BUY 요청 누적량 증가
→ FiatBuyRequested 이벤트
→ AgoraBuyDecisionRecorded 이벤트
```

## 7. AgoraInvest SELL

권장 호출:

```move
agora_invest::request_sell(
    vault,
    crypto_amount,
    signal_digest,
    risk_score_bps,
    ctx,
)
```

SELL은 `ACTIVE`와 `REDUCE_ONLY` 상태에서 허용된다.

```text
신호·위험 점수 검사
→ AgoraAgent 주소 및 PAUSED 여부 검사
→ CryptoT 1회·epoch 한도 검사
→ crypto_balance 검사
→ SELL 요청 누적량 증가
→ CryptoSellRequested 이벤트
→ AgoraSellDecisionRecorded 이벤트
```

## 8. 현재 이벤트

Vault:

- `FiatBuyRequested<FiatT, CryptoT>`
- `CryptoSellRequested<FiatT, CryptoT>`

AgoraInvest:

- `AgoraBuyDecisionRecorded<FiatT, CryptoT>`
- `AgoraSellDecisionRecorded<FiatT, CryptoT>`

x402:

- `SignalPaymentReceiptEvent<T>`

`signal_digest`는 외부 응답 원문을 온체인에 저장하지 않고, 실행에 사용한 신호 묶음을 추적하기 위한 해시다.

## 9. 현재 요청 단계의 한계

현재 `request_buy/request_sell`은 실제 자산을 거래하지 않는다.

```text
Vault 잔액 감소 없음
DEX 호출 없음
결과 Coin 수령 없음
요청 이벤트와 epoch 사용량만 변경
```

따라서 요청만 반복해 epoch 한도를 소진할 수 있다. 실제 운용 전에는 다음을 한 트랜잭션으로 묶어야 한다.

```text
권한·신호·위험 검사
→ 한도 검사
→ 허용된 DEX/Pool 거래
→ min_amount_out·deadline 검사
→ 결과 자산을 동일 Vault에 보관
→ 성공 시에만 epoch 사용량 증가
→ 실행 이벤트 기록
```

## 10. 자산 타입 정책

현재 MVP:

```text
Vault 하나
= Agora 배포 설정의 FiatT/CryptoT 거래쌍 하나
```

사용자는 Crypto를 선택하지 않는다. 다만 AgoraAgent가 한 Vault에서 여러 Crypto를 자유롭게 거래하려면 현재 단일 `Balance<CryptoT>`로는 부족하다. 그 단계에서는 Dynamic Field/Bag 또는 별도 position object 설계가 필요하다.

## 11. 가스 정책

사용자가 부담:

- Vault 생성
- USDC 예치
- Wallet 출금
- 직접 실행하는 Owner 설정 변경

Agora가 부담:

- Signal Provider x402 결제
- AgoraInvest BUY/SELL 요청
- 향후 DEX 실행·정산

## 12. 검증

```bash
cd sui-contract
sui move test
```

현재 결과:

```text
30 passed
0 failed
```
