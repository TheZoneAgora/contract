# THE ZONE AGORA — 작업 인수인계

최종 갱신: 2026-07-26 (Asia/Seoul)  
프로젝트 루트: `/Users/kim_jinwoong/Desktop/project/Project_Team/Agora_BlockBlock2026Summer`

## 1. 현재 제품 정의

THE ZONE AGORA는 사용자가 Agent나 Crypto를 고르는 Marketplace가 아니다.

사용자는 회원가입 후 개인 Vault에 USDC를 예치하고 Agora 및 AgoraAgent의 자동 운용을 사용한다. 사용자는 자산의 최종 출금 권한을 유지한다.

```text
외부 Signal Provider들
        │ x402
        ▼
AgoraAgent
        │ 신호 검증·조합·위험 평가
        ▼
AgoraInvest
        │ 신호 digest·위험 점수 기록
        ▼
UserVault
        │ 권한·잔액·한도 강제
        ▼
향후 허용된 DEX / Pool
```

## 2. 제거된 이전 구조

다음 개념은 현재 제품에 사용하지 않는다.

- 사용자의 개별 투자 Agent 선택
- Agent Follow
- Follow fee
- `FollowRecord`
- 사용자의 Signal Provider 선택
- 사용자의 Crypto 타입 선택
- 사용자 지갑의 x402 신호 결제

삭제된 Move 모듈:

- `sui-contract/sources/marketplace/agent_registry.move`
- `sui-contract/sources/marketplace/follow.move`

## 3. 현재 핵심 모듈

### Vault

- `sui-contract/sources/vault/investment_vault.move`
- `UserVault<FiatT, CryptoT>` shared object
- Owner만 입금·출금·설정 변경 가능
- AgoraAgent만 BUY/SELL 요청 가능
- `ACTIVE`, `REDUCE_ONLY`, `PAUSED` 상태
- Fiat/Crypto별 1회 및 epoch 누적 한도
- 현재 요청은 이벤트와 누적량만 기록하며 실제 DEX swap은 아직 없음

### AgoraInvest

- `sui-contract/sources/AgoraAgent/AgoraInvest.move`
- AgoraAgent의 BUY/SELL 전용 요청 계층
- `signal_digest`와 `risk_score_bps` 기록
- 실제 권한·잔액·한도 검사는 Vault 모듈 재사용

### Signal Provider

- `sui-contract/sources/marketplace/signal_provider_registry.move`
- Provider 이름, x402 수령 주소, 활성 상태
- 사용자와 Follow 관계 없음
- Vault 권한 없음

### x402

- `sui-contract/sources/marketplace/payment_splitter.move`
- `pay_signal_provider_usage_fee`
- `SignalPaymentReceiptEvent`
- AgoraAgent가 Provider와 Treasury에 신호 사용료 분배
- `agent-execution-server/x402Middleware.ts`가 결제 payer를 AgoraAgent 주소까지 검증
- `sui-contract/sources/Dex/x402_client.js`는 사용자 dAppKit이 아닌 Agora signer 사용

## 4. 사용자 흐름

```text
회원가입
→ 지갑 연결
→ 개인 Vault 생성
→ 배포 설정의 AgoraAgent 자동 연결
→ USDC 예치
→ AgoraAgent 자동 운용
→ 필요 시 Wallet 출금
```

사용자 공개 입력에서 다음을 제거했다.

- `coinType`
- `cryptoCoinType`
- `agoraAgentOperator`
- `newAgoraAgentOperator`

배포 설정:

```env
NEXT_PUBLIC_AGENT_MARKET_PACKAGE_ID=...
NEXT_PUBLIC_AGORA_AGENT_OPERATOR=...
NEXT_PUBLIC_AGORA_FIAT_COIN_TYPE=...USDC
NEXT_PUBLIC_AGORA_CRYPTO_COIN_TYPE=...
```

Move의 `FiatT`, `CryptoT`는 타입 안전성을 위해 내부적으로 유지한다. 현재 MVP에서는 Agora 배포 설정이 하나의 거래쌍을 정한다.

## 5. 가스 정책

사용자 부담:

- 최초 Vault 생성 및 AgoraAgent 연결
- Vault USDC 예치
- Vault 자산 Wallet 출금
- Owner가 직접 실행하는 상태·한도 변경

Agora 부담:

- Signal Provider x402 결제와 가스
- 자동 BUY/SELL 요청
- 향후 DEX 실행 및 정산

지갑 연결과 일반 회원가입에는 가스가 없다. 자동 투자에도 가스는 발생하지만 AgoraAgent가 부담하므로 사용자 Wallet에서 차감되지 않는다.

## 6. 현재 테스트

```bash
cd sui-contract
sui move test
# 30/30 PASS

cd ../agent-execution-server
npm run typecheck
# PASS

node --check ../sui-contract/sources/Dex/Vault_Dex.js
node --check ../sui-contract/sources/Dex/x402_client.js
# PASS
```

주요 테스트:

- Owner 입금·출금
- AgoraAgent 외 주소 거래 차단
- BUY/SELL 1회·epoch 한도
- ACTIVE/REDUCE_ONLY/PAUSED
- AgoraInvest 신호 digest·위험 점수
- 위험 점수 10,000 bps 초과 차단
- Signal Provider 등록
- AgoraAgent x402 결제 분배
- 플랫폼 수수료 100% 초과 차단

## 7. 현재 미구현

1. 실제 DEX swap과 Vault 원자적 정산
2. 실행 가능한 AgoraAgent HTTP 서버와 운영 signer
3. Signal Provider 평가·조합 로직
4. Redis/DB 기반 x402 replay 차단
5. Pool allowlist, `min_amount_out`, deadline
6. signal/payment/trade digest 통합 실행 DB
7. 실제 gas effects 기반 Agora Unit Economics
8. Testnet E2E
9. 기존 Agent 경쟁·선택형 프런트 UX 개편

## 8. 중요한 한계

- 현재 `request_buy/request_sell`은 실제 거래 전에 epoch 사용량을 증가시킨다.
- 공식 실행 경로를 `AgoraInvest`로 만들었지만 기존 Vault 요청 함수도 아직 public이다.
- 현재 Vault 하나는 배포 설정의 FiatT/CryptoT 한 쌍만 보유한다.
- AgoraAgent가 한 Vault에서 여러 Crypto를 운용하려면 별도 다중 자산 저장 설계가 필요하다.
- `fee_vault.move`는 아직 학습용 뼈대다.
- replay 저장소는 메모리 기반이다.

## 9. 보안 불변식

- Signal Provider는 Vault 권한이 없다.
- AgoraAgent는 Vault owner가 아니다.
- AgoraAgent는 사용자 Wallet으로 출금할 수 없다.
- Owner만 Vault 자산을 출금할 수 있다.
- 거래 결과 수령자는 향후 반드시 동일 Vault여야 한다.
- DEX 실행에는 Pool allowlist, 최소 수령량, deadline이 필요하다.
- x402 결제 payer는 설정된 AgoraAgent 주소여야 한다.
- 같은 payment digest를 두 번 사용할 수 없어야 한다.

## 10. 다음 작업 권장 순서

1. `AgoraInvest`를 공식 유일 실행 경로로 만들기
2. Mock DEX `execute_buy/execute_sell`
3. 실제 거래 성공 시에만 epoch 사용량 갱신
4. Signal Provider 평가·신호 조합 서버
5. 운영 signer와 KMS
6. Redis/DB replay 저장소
7. Testnet E2E
8. 사용자 중심 프런트 UX 개편

작업 전 `PROGRESS.md`, `20260726변경점.md`와 실제 코드를 함께 확인한다. 문서보다 실행 코드와 테스트 결과를 우선한다.
