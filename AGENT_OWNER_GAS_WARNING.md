# AgoraAgent 가스비 및 운영 정책

최종 갱신: 2026-07-26  
상태: 내부 운영 정책 초안

> 파일명은 이전 개별 Agent 모델의 흔적이다. 현재는 Agent Owner 등록이나 사용자 Follow 정책이 아니라 AgoraAgent의 내부 가스 운영 정책을 다룬다.

## 1. 현재 원칙

사용자는 투자 Agent, Signal Provider 또는 Crypto 타입을 선택하지 않는다.

```text
회원가입
→ 지갑 연결
→ 개인 Vault 생성 및 AgoraAgent 연결
→ USDC 예치
→ AgoraAgent 자동 운용
→ 사용자 Wallet 출금
```

AgoraAgent는 외부 Signal Provider를 평가하고 x402로 신호를 구매한 뒤 사용자별 Vault 한도 안에서 BUY/SELL을 요청한다.

## 2. 가스 부담 주체

| 작업 | 기본 서명자 | 가스 부담 |
| --- | --- | --- |
| 지갑 연결·회원가입 | 없음 | 없음 |
| Vault 생성 및 AgoraAgent 연결 | 사용자 | 사용자 |
| Vault USDC 예치 | 사용자 | 사용자 |
| Vault 자산 Wallet 출금 | 사용자 | 사용자 |
| Signal Provider x402 결제 | AgoraAgent | Agora |
| 자동 BUY/SELL 요청 | AgoraAgent | Agora |
| 향후 DEX 실행·정산 | AgoraAgent | Agora |
| Owner의 PAUSED·REDUCE_ONLY·한도 변경 | 사용자 | 사용자 또는 향후 Sponsor |

“자동 투자에 가스가 없다”가 아니라 “자동 투자 가스를 Agora가 부담하므로 사용자 지갑에서 차감되지 않는다”가 정확한 표현이다.

## 3. 사용자에게 표시할 문구

> 자동 투자와 외부 투자 신호 구매에 필요한 네트워크 가스는 AgoraAgent가 부담합니다. Vault 생성, USDC 예치 및 Wallet 출금처럼 사용자가 직접 서명하는 온체인 작업에는 Sui 네트워크 가스가 발생할 수 있습니다.

지갑 연결과 일반 회원가입은 온체인 트랜잭션이 아니므로 가스가 발생하지 않는다.

## 4. AgoraAgent 내부 비용

```text
Agora 자동 운용 비용
= Signal Provider x402 비용
+ x402 결제 가스
+ Vault BUY/SELL 실행 가스
+ 향후 DEX 및 정산 비용
+ 실패·재시도 비용
+ RPC·서버·KMS·모니터링 비용
```

Signal Provider의 x402 수령액:

```text
Provider 실수령액
= AgoraAgent가 지불한 x402 금액
- 플랫폼 수수료
```

사용자에게 Follow fee 또는 Provider별 사용료를 직접 청구하지 않는다.

## 5. 다중 Vault 실행

사용자별 `UserVault`를 유지하면 처리 비용은 Vault 수와 명령 수에 따라 증가할 수 있다.

### 개별 실행

- 구현과 실패 격리가 단순하다.
- 사용자별 잔액·한도를 다르게 적용하기 쉽다.
- Vault 수에 따라 Transaction과 가스가 증가한다.

### Chunked PTB batch

- 여러 Vault 명령이 Transaction 고정 overhead를 공유할 수 있다.
- 하나의 명령 실패가 전체 PTB를 롤백할 수 있다.
- 사전 잔액·권한·한도 검사와 안전한 chunk 크기가 필요하다.
- PTB 크기는 고정 숫자가 아니라 최신 protocol config와 시뮬레이션으로 정한다.

### Master Pool

- 사용자 수와 거래 횟수를 직접 연결하지 않을 수 있다.
- 현재 사용자별 Vault 모델과 다른 금융 상품이다.
- share 회계, 입출금 가격, 손익 귀속, 감사 없이는 도입하지 않는다.

## 6. 권장 실행 절차

```text
Signal Provider 신호 수집
→ 신호 만료·조작·성과 검증
→ 대상 Vault 조회
→ 잔액·AgoraAgent 상태·한도 사전 검사
→ 실패 가능 Vault 제외
→ 안전한 크기의 PTB로 분할
→ dry-run
→ 가스 예산·deadline 설정
→ AgoraAgent signer 제출
→ digest·effects·signal digest 저장
```

## 7. 위험 상태

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

Signal Provider 이상, 시장 위험 또는 운영 장애가 감지되면 신규 BUY를 중단하고 필요에 따라 REDUCE_ONLY 또는 PAUSED로 전환한다.

## 8. 운영 체크리스트

- [ ] AgoraAgent 운영 키를 KMS/HSM 등으로 보호한다.
- [ ] x402 결제 payer가 AgoraAgent 주소인지 서버에서 검증한다.
- [ ] Signal Provider별 가격·성공률·오류율을 저장한다.
- [ ] 동일 payment digest 재사용을 Redis/DB에서 차단한다.
- [ ] DEX package·pool allowlist를 적용한다.
- [ ] `min_amount_out`, deadline, 최대 슬리피지를 강제한다.
- [ ] 거래 전 dry-run을 수행한다.
- [ ] 일일 가스 예산과 Auto-Refill 상한을 둔다.
- [ ] 실제 Transaction effects로 비용을 집계한다.
- [ ] 사용자당·Vault당 P50/P95 비용을 모니터링한다.

## 9. 금지할 표현

- “모든 온체인 작업이 완전 무료”
- “가스비는 항상 고정”
- “PTB를 쓰면 비용이 항상 일정”
- “사용자 수가 늘어도 Agora 비용은 증가하지 않음”
- “수익률 또는 원금 보장”

실제 비용은 네트워크 가스 가격, PTB 복잡도, DEX 경로, shared object 혼잡과 실패율에 따라 달라진다.

## 10. 다음 구현

1. 실행 가능한 AgoraAgent 서버와 운영 signer
2. Signal Provider 평가·선택 로직
3. Redis/DB replay 저장소
4. Mock DEX 기반 원자적 `execute_buy/execute_sell`
5. Pool allowlist·슬리피지·deadline
6. 실제 가스 effects 및 사용자당 운영 비용 집계
7. Owner 설정 변경용 Sponsored Transaction 검토
