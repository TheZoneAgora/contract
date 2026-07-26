# Agora 전체 프로젝트 개발 진행 및 기술 보고서

최종 갱신: 2026-07-26
기준 경로: 프로젝트 최상위 `MarketPlace/` 전체
검증 상태: 2026-07-26 아키텍처 변경 검증 진행 중

> 2026-07-26 변경: 사용자의 Agent 선택·Follow·Follow fee를 제거했다. 모든 Vault는 AgoraAgent만 실행자로 연결하고, AgoraAgent가 외부 Signal Provider를 선택해 x402 비용과 자동 투자 가스를 부담한다.

## 0. 전체 영역 진행 상태

| 영역 | 폴더 | 현재 상태 |
|---|---|---|
| Frontend / UX | `thezoneagora-main/` | 랜딩과 Sui Wallet 연결 기반 구현. 기존 Agent 비교·선택 UI는 새 Agora 자동 운용 UX로 개편 필요 |
| Smart Contract / SDK | `sui-contract/` | 2자산 Vault, AgoraAgent 권한·한도, Signal Provider Registry, x402 분배 및 Transaction 빌더 구현 |
| Agent Backend | `agent-execution-server/` | x402 결제 검증 미들웨어 구현. 실제 Express 실행 서버·AI 판단·Agent signer·거래 라우트는 아직 없음 |
| 기획·보고 자료 | `Project_Info/` | Agent onboarding, Vault 설명, Marketplace 및 전략 보고서 HTML 보관 |
| 통합 E2E | 전체 | FE 지갑 → x402 결제 → Agent 실행 → Vault → 실제 DEX의 전체 트랙은 아직 미완성 |

현재 가장 중요한 통합 과제는 프런트엔드, Agent 실행 서버, Sui 컨트랙트 사이의 인터페이스를 고정하고 Testnet에서 단계별로 연결하는 것이다.

## 1. 프로젝트 개요

이 프로젝트는 사용자가 자산 소유권과 최종 출금 권한을 유지하면서 AgoraAgent에 제한된 자동 거래 권한만 위임하는 Sui 기반 투자 Vault 시스템이다.

외부 Signal Provider API의 유료 호출에는 HTTP `402 Payment Required` 기반 x402 흐름을 사용한다. AgoraAgent가 신호 사용료와 결제 가스를 부담하면 Provider와 플랫폼 Treasury에 분배되고, Provider 서버는 결제 영수증을 검증한 뒤 신호를 반환한다.

현재 구현 범위는 다음과 같다.

- 사용자의 기준 자산과 투자 자산을 분리 보관하는 shared Vault
- owner 전용 입금·출금·AgoraAgent 관리 기능
- AgoraAgent 전용 BUY/SELL 요청 권한과 1회·epoch 누적 한도
- FiatT는 BUY 입력, CryptoT는 SELL 입력으로 고정하는 자산 역할 정책
- 사용자의 Fiat/Crypto 타입 선택 제거 및 Agora 배포 환경 타입 사용
- Sui Transaction 빌더
- x402 온체인 사용료 분배 컨트랙트
- HTTP 402 응답, 결제 영수증 검증 및 재사용 방지 미들웨어
- AgoraAgent 운영 signer를 이용한 x402 결제·재요청 클라이언트
- Move 단위 테스트 및 TypeScript 정적 검사

아직 구현되지 않은 범위는 다음과 같다.

- 실제 DEX swap
- BUY 결과 CryptoT를 Vault에 정산하는 `execute_buy`
- SELL 결과 FiatT를 Vault에 정산하는 `execute_sell`
- Agent 서버의 실제 거래 실행 라우트 및 운영 키 관리
- 가스비·환율·DEX 비용을 집계하는 Unit Economics 백엔드
- Agent 수익 지갑의 SUI 자동 충전

## 2. 문제 정의와 핵심 가치

일반적인 자동매매 Agent에 사용자 자금을 직접 전송하면 Agent 서버 키 탈취, 임의 출금, 허용되지 않은 거래, 과도한 주문 같은 위험이 발생한다.

본 프로젝트는 다음과 같이 책임을 분리한다.

```text
사용자
├─ 자산의 최종 소유권 유지
├─ Vault 생성 및 FiatT 입금
├─ 출금 및 AgoraAgent 자동 운용 중지·복구
└─ Signal Provider 선택·결제에는 참여하지 않음

AgoraAgent
├─ 허용된 BUY/SELL 요청
├─ 1회 및 epoch 한도 준수
├─ 외부 Signal Provider 선택과 x402 결제
└─ 향후 허용된 DEX 거래 실행 및 가스 부담

Signal Provider
├─ AgoraAgent에 투자 신호 제공
├─ Vault 접근 권한 없음
└─ 사용자와 직접 Follow 관계 없음

온체인 Vault
├─ 자산 타입과 역할 분리
├─ 실제 서명자 기반 권한 검사
├─ 잔액 및 한도 검사
└─ 거래 결과를 Agent 지갑이 아닌 Vault에 보관

플랫폼
├─ Signal Provider Registry 운영
├─ x402 결제 검증
├─ 플랫폼 수수료 수령
└─ 향후 Agent 품질 및 수익성 지표 제공
```

## 3. 기술 스택

| 영역 | 기술 | 현재 사용 목적 |
|---|---|---|
| Blockchain | Sui | 객체 기반 자산 보관, 트랜잭션 실행, 이벤트 기록 |
| Smart Contract | Sui Move, edition 2024 | Vault, Signal Provider Registry, Fee Vault, Payment Splitter |
| Network | Sui Testnet 예정 | 지갑 연결 및 E2E 검수 |
| Frontend Framework | Next.js `^15.5.19`, React `18.3.1` | 랜딩 페이지와 Agent 비교 대시보드 |
| Frontend Language | TypeScript `5.5.4` | 컴포넌트, 데이터 모델, 지갑 규칙 |
| UI | Tailwind CSS `3.4.7`, Framer Motion `11.3.19` | 반응형 스타일과 화면 전환 애니메이션 |
| Chart | Lightweight Charts `4.1.6` | Agent 자산 곡선 시각화 |
| Wallet UI | `@mysten/dapp-kit-react` `^2.1.5` | Sui Wallet Provider와 연결 상태 |
| Frontend Sui SDK | `@mysten/sui` `^2.20.1` | 프런트엔드 Sui 네트워크 연동 기반 |
| Transaction SDK | `@mysten/sui` `^2.22.0` | PTB 생성, 코인 선택, RPC 조회, 서명·실행 연동 |
| Backend | Node.js `>=22` | Agent 실행 서버 |
| HTTP Server | Express `^5.2.1` | x402 미들웨어와 Agent API |
| Language | TypeScript `^5.9.3` | 서버 타입 안정성 |
| SDK Client | JavaScript + JSDoc `@ts-check` | Vault/x402 Transaction 빌더 |
| RPC | `SuiJsonRpcClient` | 결제 Transaction과 이벤트 검증 |
| Wallet | Sui Wallet/dApp Kit 연동 인터페이스 | 사용자 Vault 생성·입금·출금 서명 |
| Payment | HTTP 402 + 온체인 영수증 | AgoraAgent의 Signal Provider 유료 호출 및 분배 |
| Test | `sui move test`, `tsc --noEmit` | Move 보안 불변식 및 SDK 타입 검사 |

Move 패키지 이름은 `agent_market`이며 named address는 개발 시 `0x0`을 사용한다. 실제 Testnet 호출에는 배포 후 생성된 package ID가 필요하다.

## 4. 전체 프로젝트 구조와 파일 역할

```text
MarketPlace/
├─ PROGRESS.md                         전체 프로젝트 진행 기준 문서
├─ AGENT_OWNER_GAS_WARNING.md          AgoraAgent 가스·운영 정책(파일명은 이전 명칭)
│
├─ Project_Info/                       대회·기획·설명용 HTML 자료
│  ├─ agent-onboarding-verification.html
│  ├─ agent-vault-explainer.html
│  ├─ agent_trading_marketplace_report.html
│  └─ agora-strategy-summary.html
│
├─ thezoneagora-main/                  Next.js 프런트엔드
│  ├─ app/
│  │  ├─ page.tsx                      랜딩 진입점
│  │  ├─ layout.tsx                    전역 레이아웃·Wallet Provider
│  │  ├─ globals.css                   전역 Tailwind/CSS 스타일
│  │  ├─ dapp-kit.ts                   Sui dApp Kit 네트워크 설정
│  │  └─ dashboard/page.tsx            Agent 대시보드 라우트
│  ├─ components/
│  │  ├─ LoginPage.tsx                 랜딩·진입 UX
│  │  ├─ DashboardClient.tsx           대시보드 상태와 섹션 조합
│  │  ├─ AgentCard.tsx                 Agent 요약 카드
│  │  ├─ AgentDetailModal.tsx          Agent 상세 정보
│  │  ├─ Leaderboard.tsx               Agent 순위
│  │  ├─ RaceTrack.tsx                 경쟁 시각화
│  │  ├─ EquityCurveChart.tsx          자산 곡선 차트
│  │  ├─ MintDetailPanel.tsx           MINT 상세 데이터
│  │  └─ Sui-Wallet/                   지갑 Provider·로그인 UI
│  ├─ lib/
│  │  ├─ data/                         mock/실데이터 소스와 전략 시뮬레이터
│  │  ├─ types/                        Agent·Snapshot·MINT 타입
│  │  ├─ hooks/                        실시간 UI hook
│  │  ├─ leaderboard.ts                순위 계산
│  │  ├─ snapshot.ts                   대시보드 snapshot 조립
│  │  └─ walletRules.ts                지갑별 Agent 필터 규칙
│  └─ package.json
│
├─ agent-execution-server/             Agent HTTP 실행·결제 검증 계층
│  ├─ x402Middleware.ts                결제 challenge·영수증·replay 검증
│  ├─ package.json                     Node/Express/Sui SDK 의존성
│  └─ tsconfig.json                    TS 및 x402 JS 정적 검사
│
└─ sui-contract/                       Sui Move 컨트랙트·SDK·테스트
   ├─ Move.toml                        agent_market Move 패키지 설정
   ├─ Move.lock                        Move 의존성 잠금
   ├─ file_structure.md                컨트랙트 파일 구조 학습 문서
   ├─ test_structure.md                테스트 구조 학습 문서
   ├─ vault_use.md                     Vault 사용 학습 문서
   ├─ sources/
   │  ├─ vault/
   │  │  ├─ investment_vault.move      사용자 Vault 핵심 로직
   │  │  └─ fee_vault.move             성과 수수료 기초 로직
   │  ├─ marketplace/
   │  │  ├─ signal_provider_registry.move 외부 Signal Provider 정보
   │  │  └─ payment_splitter.move      AgoraAgent x402 사용료 온체인 분배
   │  ├─ AgoraAgent/
   │  │  └─ AgoraInvest.move           신호·위험 점수 기반 Vault 요청 계층
   │  └─ Dex/
   │     ├─ Vault_Dex.js               Vault PTB 빌더
   │     └─ x402_client.js              402 결제·재요청 클라이언트
   └─ tests/
      ├─ vault/                         Vault·Fee Vault Move 테스트
      └─ marketplace/                   Signal Provider Registry·Payment 테스트
```

생성 폴더와 파일인 `node_modules/`, `.next/`, `sui-contract/build/`, `tsconfig.tsbuildinfo`, `.DS_Store`는 위 구조에서 제외했다.

`build/`는 Move 컴파일 산출물이므로 직접 수정하지 않는다. `.env`에는 배포 package ID와 네트워크별 설정을 두되 개인키와 비밀값을 프런트엔드 환경변수에 저장하면 안 된다.

### 4.1 Frontend 현재 구현 상태

구현됨:

- 랜딩 페이지와 데모 진입 동선
- Sui Wallet Provider 및 지갑 연결 UI 기반
- 기존 설계의 Agent 필터·카드·리더보드·레이스 트랙 UI
- 기존 설계의 Agent별 equity curve
- mock 전략 시뮬레이터와 snapshot 데이터 계층
- MINT 실데이터 예시 패널
- 반응형 레이아웃과 애니메이션

기존 Agent 경쟁·선택 UI는 현재 제품 방향과 맞지 않으므로 개인 Vault·Agora 자동 운용 대시보드로 교체해야 한다.

아직 연결되지 않음:

- Testnet 배포 package ID 기반 Vault 생성·입금·출금
- `Vault_Dex.js` Transaction 빌더 import 및 지갑 실행
- AgoraAgent 서버와 Vault 실행 연동
- 개인 Vault 생성·USDC 예치·Agora 자동 운용 화면
- 정확한 사용자/Agora 가스 부담 안내
- 온체인 Signal Provider Registry 조회
- 실제 Vault 잔액·이벤트·거래 결과 표시

### 4.2 Agent 실행 서버 현재 구현 상태

현재 `x402Middleware.ts`만 구현되어 있다. HTTP 402 challenge 생성, Sui 결제 Transaction 조회, `SignalPaymentReceiptEvent` 검증, 결제 유효 시간과 replay를 검사한다.

실제 Express 앱 진입점, Agent AI 실행, 운영 signer, Vault BUY/SELL Transaction 제출, 거래 결과 DB, Redis replay 저장소와 가스 원가 수집기는 아직 없다.

### 4.3 Sui Contract 현재 구현 상태

Move 컨트랙트와 JavaScript Transaction 빌더는 Vault 권한·한도·자산 역할, AgoraInvest, Signal Provider Registry, x402 분배까지 구현되어 있다. 실제 DEX swap과 결과 자산 정산은 아직 없으며 상세 내용은 이후 장에서 모듈별로 정리한다.

## 5. Investment Vault 설계

### 5.1 Vault 데이터 구조

`UserVault<FiatT, CryptoT>`는 shared object다.

`FiatT`와 `CryptoT`는 Move 내부 타입 안전성을 위해 유지하지만 사용자가 선택하지 않는다. Vault SDK는 공개 함수에서 `coinType`, `cryptoCoinType`, AgoraAgent 주소를 받지 않고 `NEXT_PUBLIC_AGORA_FIAT_COIN_TYPE`, `NEXT_PUBLIC_AGORA_CRYPTO_COIN_TYPE`, `NEXT_PUBLIC_AGORA_AGENT_OPERATOR` 배포 설정을 사용한다.

| 필드 | 의미 |
|---|---|
| `id` | Vault 객체 UID |
| `owner` | 출금 및 설정 변경 권한을 가진 사용자 |
| `agora_agent_operator` | 거래 요청 권한을 가진 AgoraAgent 운영 지갑 |
| `agora_agent_status` | `ACTIVE`, `REDUCE_ONLY`, `PAUSED` 상태 |
| `max_trade_amount` | FiatT BUY 1회 최대 수량 |
| `max_epoch_trade_amount` | epoch당 FiatT BUY 누적 최대 수량 |
| `spent_this_epoch` | 현재 epoch의 FiatT BUY 요청 누적량 |
| `max_crypto_sell_amount` | CryptoT SELL 1회 최대 수량 |
| `max_epoch_crypto_sell_amount` | epoch당 CryptoT SELL 누적 최대 수량 |
| `spent_crypto_this_epoch` | 현재 epoch의 CryptoT SELL 요청 누적량 |
| `spending_epoch` | 누적량이 속한 Sui epoch |
| `fiat_balance` | `Balance<FiatT>`, 예: USDC |
| `crypto_balance` | `Balance<CryptoT>`, 예: SUI |

FiatT와 CryptoT를 제네릭 타입으로 분리했기 때문에 두 잔액은 Move 타입 시스템 차원에서 섞이지 않는다.

```text
UserVault<USDC, SUI>
├─ fiat_balance: Balance<USDC>  → BUY 입력 전용
└─ crypto_balance: Balance<SUI> → SELL 입력 전용
```

### 5.2 사용자와 AgoraAgent의 자산 역할

- 사용자는 공개 함수 `deposit_more`를 통해 FiatT만 입금할 수 있다.
- 운영 배포본에는 사용자가 CryptoT를 직접 입금하는 공개 경로가 없다.
- `deposit_crypto_for_testing`은 `#[test_only]`이므로 단위 테스트에서만 존재한다.
- CryptoT는 향후 성공한 `execute_buy`의 DEX 결과로만 증가해야 한다.
- AgoraAgent BUY는 `fiat_balance`만 검사한다.
- AgoraAgent SELL은 `crypto_balance`만 검사한다.
- owner는 FiatT와 CryptoT를 각각 또는 전부 출금할 수 있다.

이 정책은 사용자가 투자 결과인 것처럼 임의의 CryptoT를 주입하거나 AgoraAgent가 BUY에 CryptoT, SELL에 FiatT를 잘못 사용하는 것을 차단한다.

### 5.3 공개 함수 목록

| 함수 | 허용 호출자 | 현재 역할 |
|---|---|---|
| `create_vault` | 사용자 | FiatT 초기 예치, 배포 설정의 AgoraAgent 주소와 BUY/SELL 한도로 shared Vault 생성 |
| `deposit_more` | owner | FiatT 추가 입금 |
| `withdraw_all_assets` | owner | FiatT와 CryptoT 전액 출금 |
| `withdraw_amount` | owner | FiatT 일부 출금 |
| `withdraw_crypto_amount` | owner | CryptoT 일부 출금 |
| `revoke_agent` | owner | AgoraAgent 상태를 PAUSED로 변경 |
| `set_reduce_only` | owner | 신규 BUY 차단, SELL만 허용 |
| `reactivate_agent` | owner | AgoraAgent 상태를 ACTIVE로 복구 |
| `replace_agent` | owner | 배포 설정의 AgoraAgent 운영 주소로 교체 후 활성화 |
| `update_trade_limit` | owner | FiatT BUY 1회 한도 변경 |
| `update_epoch_trade_limit` | owner | FiatT BUY epoch 한도 변경 |
| `update_crypto_sell_limit` | owner | CryptoT SELL 1회 한도 변경 |
| `update_epoch_crypto_sell_limit` | owner | CryptoT SELL epoch 한도 변경 |
| `request_trade` | AgoraAgent | 기존 FE 호환용 BUY 별칭 |
| `request_buy` | AgoraAgent | FiatT BUY 요청 검증·누적·이벤트 |
| `request_sell` | AgoraAgent | CryptoT SELL 요청 검증·누적·이벤트 |
| `agora_agent_operator` | Move 호출부 | Vault에 연결된 AgoraAgent 주소 조회 |
| `is_agora_agent_active` | Move 호출부 | ACTIVE 상태 조회 |
| `is_reduce_only` | Move 호출부 | REDUCE_ONLY 상태 조회 |
| `vault_balance` | Move 호출부 | 호환용 FiatT 잔액 조회 |
| `fiat_balance` | Move 호출부 | FiatT 잔액 조회 |
| `crypto_balance` | Move 호출부 | CryptoT 잔액 조회 |

테스트 전용 `deposit_crypto_for_testing`은 운영 API가 아니다.

### 5.4 내부 보안 검사

- `assert_agora_agent_authorized`: `tx_context::sender(ctx)`가 연결된 AgoraAgent인지, PAUSED 상태가 아닌지 검사한다.
- `assert_buy_enabled`: BUY 요청에서 상태가 ACTIVE인지 검사한다.
- `assert_fiat_buy_amount_allowed`: BUY 금액이 0보다 크고 1회 한도 이하인지 검사한다.
- `assert_crypto_sell_amount_allowed`: SELL 수량이 0보다 크고 1회 한도 이하인지 검사한다.
- `refresh_spending_epoch`: epoch가 바뀌면 BUY/SELL 누적량을 모두 0으로 초기화한다.
- `assert_epoch_fiat_buy_amount_allowed`: BUY 요청을 더해도 FiatT epoch 한도를 넘지 않는지 검사한다.
- `assert_epoch_crypto_sell_amount_allowed`: SELL 요청을 더해도 CryptoT epoch 한도를 넘지 않는지 검사한다.

epoch 한도 변경 시 새 한도가 이미 사용한 양보다 작아질 수 없다. 이미 기록된 누적 사용량보다 작은 한도를 허용하면 `현재 사용량 > 현재 한도`라는 모순 상태가 생기기 때문이다.

### 5.5 이벤트

`FiatBuyRequested<FiatT, CryptoT>`:

- Vault ID
- AgoraAgent 운영 주소
- BUY FiatT 수량
- epoch
- 요청 후 epoch 누적 BUY 수량

`CryptoSellRequested<FiatT, CryptoT>`:

- Vault ID
- AgoraAgent 운영 주소
- SELL CryptoT 수량
- epoch
- 요청 후 epoch 누적 SELL 수량

현재 이벤트는 거래 실행 완료 증명이 아니라 요청 검증 완료 기록이다.

## 6. 현재 Vault 거래 Workflow

### 6.1 Vault 생성 및 입금

```text
사용자 FE
→ 배포 설정의 USDC Coin 사용
→ buildCreateVaultTransaction
→ 사용자 승인 및 서명
→ investment_vault::create_vault
→ FiatT가 fiat_balance에 보관됨
→ crypto_balance는 0으로 시작
```

### 6.2 AgoraInvest BUY 요청

```text
AgoraAgent 운영 지갑 서명
→ agora_invest::request_buy
→ signal_digest·risk_score_bps 검사
→ shared UserVault 입력
→ 실제 서명자 == agora_agent_operator 검사
→ agora_agent_status == ACTIVE 검사
→ epoch 변경 시 누적량 초기화
→ BUY 수량 > 0 검사
→ FiatT 1회 한도 검사
→ FiatT epoch 누적 한도 검사
→ fiat_balance 충분 여부 검사
→ spent_this_epoch 증가
→ FiatBuyRequested 발생
→ AgoraBuyDecisionRecorded 발생
```

### 6.3 AgoraInvest SELL 요청

```text
AgoraAgent 운영 지갑 서명
→ agora_invest::request_sell
→ signal_digest·risk_score_bps 검사
→ AgoraAgent 권한 및 PAUSED 상태 검사
→ epoch 갱신
→ CryptoT 1회 및 epoch 한도 검사
→ crypto_balance 충분 여부 검사
→ spent_crypto_this_epoch 증가
→ CryptoSellRequested 발생
→ AgoraSellDecisionRecorded 발생
```

현재 `request_buy`와 `request_sell`은 자산을 이동하거나 swap하지 않는다. 요청이 성공하면 누적량과 이벤트만 변경된다.

## 7. JavaScript Transaction 계층

### 7.1 `Vault_Dex.js`

Sui `Transaction`은 온체인에서 실행할 명령을 조립하는 PTB 빌더다. `new Transaction()`이나 `moveCall`만으로는 가스가 들거나 상태가 변경되지 않는다. 서명된 Transaction이 네트워크에 제출될 때 실행된다.

공통 검증:

- Sui 주소 및 object ID 정규화
- package ID 존재 여부
- 배포 설정의 Fiat/Crypto Move coin type 형식
- JavaScript 정수 정밀도
- Move `u64` 범위
- 0보다 큰 입금·출금·거래량
- 1회 한도와 epoch 한도의 관계

현재 Transaction 빌더:

- `buildCreateVaultTransaction`
- `buildDepositMoreTransaction`
- `buildWithdrawAllTransaction`
- `buildWithdrawAmountTransaction`
- `buildWithdrawCryptoAmountTransaction`
- `buildRevokeAgentTransaction`
- `buildReactivateAgentTransaction`
- `buildReplaceAgentTransaction`
- `buildUpdateTradeLimitTransaction`
- `buildUpdateEpochTradeLimitTransaction`
- `buildRequestBuyTransaction`
- `buildRequestTradeTransaction` — BUY 호환 별칭
- `buildRequestSellTransaction`
- `executeVaultTransaction`

`buildVaultDexTradeTransaction`은 안전한 Move `execute_buy/execute_sell`이 아직 없기 때문에 의도적으로 오류를 발생시킨다. 프런트엔드 검사는 사용자 경험을 위한 1차 검사이며 최종 보안 경계는 Move 컨트랙트다.

사용자 공개 입력에는 `coinType`, `cryptoCoinType`, `agoraAgentOperator`, `newAgoraAgentOperator`가 없다. 모두 Agora 배포 설정을 사용한다.

### 7.2 PTB 원자성

향후 실제 거래는 가능하면 다음 명령을 하나의 PTB로 묶는다.

```text
하나의 Transaction
├─ AgoraAgent 신호·위험·권한·한도·잔액 검증
├─ Vault에서 입력 Coin 분리
├─ 허용된 DEX swap
├─ min_amount_out 검사
├─ 결과 Coin을 Vault에 합치기
└─ 성공한 거래량과 이벤트 기록
```

중간 명령이 실패하면 전체 상태 변경이 롤백된다. 다만 실패한 온체인 트랜잭션도 실행에 사용된 가스가 발생할 수 있다.

### 7.3 `AgoraInvest.move`

`agora_invest::request_buy`와 `request_sell`은 `signal_digest`와 `risk_score_bps`를 검사·기록한 뒤 기존 Vault BUY/SELL 검사를 호출한다.

- 빈 signal digest 차단
- `risk_score_bps > 10_000` 차단
- `AgoraBuyDecisionRecorded`
- `AgoraSellDecisionRecorded`
- Vault 권한·잔액·한도 로직 재사용

현재 기존 Vault의 `request_buy/request_sell`도 public이므로 다음 단계에서는 AgoraInvest를 공식 유일 실행 경로로 제한해야 한다.

## 8. Signal Provider 모듈

### 8.1 `signal_provider_registry.move`

`SignalProvider` 객체는 이름, x402 결제 수령 주소, 활성 상태를 저장한다. 사용자는 이 객체를 선택하거나 follow하지 않으며 Vault 권한도 부여되지 않는다.

`create_signal_provider`, `payment_receiver`, `is_active`가 구현되어 있다. 현재 Provider는 생성자에게 전송되는 owned object이며 AgoraAgent의 Provider 탐색·평가 서버와 실제 연결은 아직 구현되지 않았다.

### 8.2 `fee_vault.move`

성과 수수료 수령 주소와 bps를 저장하고 `calculate_performance_fee`를 제공하는 학습용 뼈대다. 실제 Vault 수익 및 정산과 연결되지 않았다.

현재 개선 필요 사항:

- `performance_fee_bps <= 10_000` 검사
- `profit_mist * performance_fee_bps`의 `u64` overflow 방지
- 원금, 평가액, 확정 수익의 정의
- 실제 수수료 Coin 분리 및 전송

## 9. x402 결제 계층

### 9.1 온체인 `payment_splitter.move`

`pay_signal_provider_usage_fee<T>`는 AgoraAgent가 낸 `Coin<T>`를 Signal Provider와 플랫폼 Treasury에 즉시 분배한다.

```text
총 사용료 P
├─ Signal Provider 수령: P - platform_fee
└─ Treasury 수령: platform_fee

platform_fee = floor(P × platform_fee_bps / 10,000)
```

현재 기본 예시는 `2,000 bps = 20%`이며 Signal Provider 80%, 플랫폼 20%다. 곱셈 overflow 위험을 줄이기 위해 몫과 나머지를 나눠 계산한다.

`SignalPaymentReceiptEvent<T>` 기록값:

- `payer`
- `payee`
- `treasury`
- `signal_provider_id`
- `amount`
- `platform_fee_amount`
- Transaction `digest`
- Sui Clock `timestamp`
- 이벤트 제네릭 타입 `T`를 통한 결제 토큰 검증 정보

### 9.2 `x402Middleware.ts`

Express 미들웨어는 `PAYMENT-SIGNATURE` 헤더를 Sui Transaction Digest로 사용한다.

검증 항목:

- 헤더 존재 여부와 digest 형식
- RPC 조회 성공 여부
- Transaction 실행 성공 여부
- 정확한 package/module/event 타입
- 결제 토큰 타입
- 가격
- Signal Provider ID
- 제작자 수령 주소
- Treasury 주소
- 플랫폼 bps와 실제 분배 금액
- 이벤트 digest와 제출 digest 일치
- 결제 timestamp 유효 기간
- 동일 digest 재사용 여부

헤더가 없거나 유효하지 않으면 `402 Payment Required`, RPC 조회 장애는 `503`, 검증 성공 시 `next()`를 호출한다.

현재 replay 저장소는 프로세스 메모리의 `Set`이다. 프로덕션에서는 여러 서버 인스턴스와 재시작 이후에도 중복을 차단하도록 Redis 또는 DB의 UNIQUE digest 저장소가 필요하다.

### 9.3 `x402_client.js`

```text
Signal Provider API 최초 POST
→ 402 challenge 수신
→ 가격·토큰·주소·bps 검증
→ pay_signal_provider_usage_fee Transaction 생성
→ AgoraAgent 운영 signer 서명 및 제출
→ Tx Digest 획득
→ PAYMENT-SIGNATURE 헤더로 동일 요청 재전송
→ Signal Provider 신호 반환
```

클라이언트는 토큰 부족, SUI 가스 부족, 지갑 거절, 잘못된 402 응답, 결제 성공 후 재요청 네트워크 실패를 구분해 오류를 반환한다.

## 10. 가스비 부담 구조

### 10.1 기본 원칙

Sui에서 온체인 Transaction을 실행하면 gas owner가 SUI로 가스비를 낸다. Vault 내부 FiatT 또는 CryptoT 잔액에서 자동으로 차감되지 않는다.

일반 트랜잭션은 sender와 gas owner가 같고, Sponsored Transaction에서는 행동을 승인하는 sender와 가스를 부담하는 sponsor를 분리할 수 있다.

### 10.2 현재 권장 부담 주체

| 작업 | 서명자 | 기본 가스 부담자 |
|---|---|---|
| Vault 생성 | 사용자 | 사용자 지갑 |
| FiatT 추가 입금 | 사용자 | 사용자 지갑 |
| FiatT/CryptoT 출금 | 사용자 | 사용자 지갑 |
| AgoraAgent 중지·교체·한도 변경 | 사용자 | 사용자 지갑 또는 향후 Sponsor |
| x402 신호 사용료 결제·분배 | AgoraAgent | AgoraAgent 운영 지갑 |
| `request_buy`/`request_sell` | AgoraAgent | AgoraAgent 운영 지갑 |
| 향후 실제 DEX BUY/SELL | AgoraAgent | AgoraAgent 운영 지갑 |
| Move package 배포·업그레이드 | 관리자 | 관리자 지갑 |

`UserVault<USDC, SUI>`에서 사용자의 지갑 SUI는 가스용이고, Vault의 `crypto_balance<SUI>`는 투자 결과 자산이다. 타입이 같더라도 보관 위치와 역할은 별개다.

### 10.3 가스가 발생하는 경우

- Move 함수 실행
- 객체 생성·수정·삭제·공유·전송
- Coin 분리·병합·전송
- 이벤트 발생
- DEX swap
- package 배포 및 업그레이드
- 네트워크에 제출되어 실행된 실패 Transaction

가스가 발생하지 않는 경우:

- `Transaction` 객체 조립만 한 경우
- RPC 객체·잔액·이벤트 조회
- HTTP 402 요청과 응답
- 결제 영수증 RPC 조회
- 네트워크에 제출하지 않은 시뮬레이션/dry-run

### 10.4 현재 x402 + 거래 요청의 Transaction 수

```text
1. 최초 HTTP Signal Provider 호출           → 온체인 가스 없음
2. x402 신호 사용료 결제 Transaction        → AgoraAgent 가스 1회
3. PAYMENT-SIGNATURE를 포함한 HTTP 재요청   → 온체인 가스 없음
4. 서버의 결제 Transaction RPC 검증          → 온체인 가스 없음
5. AgoraAgent의 request_buy/request_sell 제출 → AgoraAgent 가스 1회
```

따라서 현재 유료 신호 구매 후 거래 요청까지 수행하면 기본적으로 온체인 Transaction 2개다. 두 트랜잭션 모두 AgoraAgent 운영 지갑이 가스를 부담하므로 사용자 지갑에서는 가스가 차감되지 않는다. 향후 요청 검증, DEX swap, Vault 정산을 하나의 AgoraAgent PTB로 묶으면 거래 실행은 가스 1회로 유지할 수 있다.

## 11. AgoraAgent와 Signal Provider Unit Economics

### 11.1 Agora 운영 비용

Agora는 사용자 대신 Signal Provider x402 비용과 자동 투자 가스를 부담한다.

$$
C_{agora} = P_{signal} + C_{gas,USDC} + C_{DEX} + C_{infra} + C_{other}
$$

$$
C_{gas,USDC} = G_{SUI} \times Price_{SUI/USDC}
$$

변수:

- $P_{signal}$: AgoraAgent가 Signal Provider에 지불한 x402 총비용
- $G_{SUI}$: AgoraAgent가 실제 사용한 순가스 SUI
- $Price_{SUI/USDC}$: 거래 시점 SUI/USDC 가격
- $C_{DEX}$: swap fee, price impact 등 거래 비용
- $C_{infra}$: RPC, 서버, 키 관리, 모니터링 비용
- $C_{other}$: 환전, 자동 충전, 실패·재시도 비용

Agora의 수익 모델은 향후 확정할 성과 수수료, 구독 또는 플랫폼 수익에서 위 비용을 회수해야 한다. 사용자에게 별도 follow fee나 Signal Provider별 사용료를 직접 청구하지 않는다.

Signal Provider의 x402 실수령액은 플랫폼 분배율이 적용된다.

$$
R_{provider} = P_{signal} \times (1 - f_{platform})
$$

### 11.2 가스비 고정값을 코드에 넣으면 안 되는 이유

`0.001~0.005 SUI` 같은 값은 특정 시점과 단순 PTB의 관측 예시로만 사용할 수 있으며 보장값이 아니다. 실제 가스는 다음에 따라 달라진다.

- PTB 명령 수와 계산량
- 생성·수정·삭제하는 객체와 스토리지 사용량
- DEX 경로와 pool 호출 복잡도
- 네트워크 reference gas price
- 성공·실패 및 재시도 횟수
- 스토리지 비용과 rebate

따라서 가격 정책은 하드코딩된 예상값이 아니라 실제 Transaction effects의 `gasUsed`를 집계해 결정해야 한다.

권장 순가스 집계 개념:

```text
Transaction Digest
→ RPC로 effects 포함 조회
→ computationCost
→ storageCost
→ storageRebate
→ nonRefundableStorageFee
→ SDK가 제공하는 실제 gasUsed/effects 기준으로 순비용 계산
→ 해당 시점 SUI/USDC 환율 적용
→ AgoraAgent 및 Signal Provider별 원가 DB 적재
```

정확한 필드 구조와 순비용 계산은 사용 중인 RPC 버전의 effects 응답을 기준으로 구현해야 한다.

### 11.3 사용자 증가와 비용 확장에 대한 주의

사용자 100명이 각자 별도의 Vault를 가지고 있으면 현재 구조에서는 일반적으로 Vault 100개에 대한 실행이 필요하다. 사용자가 자동 투자 가스를 직접 내지는 않지만 Agora 운영 비용은 사용자 수에 따라 증가할 수 있다.

```text
현재 구조
AgoraAgent가 필요한 Signal Provider 신호 구매
100개 Vault 거래 → AgoraAgent 가스도 최대 100건 수준
```

여러 Vault 작업을 하나의 PTB에 묶는 최적화는 가능하지만 다음 제약이 있다.

- PTB 명령·입력 크기 제한
- shared object 접근 및 혼잡
- 한 사용자 거래 실패 시 전체 batch 롤백 가능성
- 가스가 고정되지 않고 명령 수에 따라 증가
- 사용자별 슬리피지·한도·잔액 차이

따라서 사용자에게는 자동 투자 가스를 청구하지 않더라도 Agora 내부에서는 batch 전략, 신호 재사용 가능 범위, 거래 빈도 제한과 비용 상한이 필요하다.

### 11.4 가스비가 만드는 AgoraAgent 품질 인센티브

Agora가 거래 가스를 부담하면 다음과 같은 인센티브가 생긴다.

- 무의미한 고빈도 호출 감소
- 실패 가능성이 큰 Transaction의 사전 시뮬레이션
- 확신도가 높은 거래 신호 중심 실행
- PTB 단위 최적화
- Signal Provider별 성공률과 AgoraAgent 가스 원가 모니터링

다만 과도한 거래 억제가 반드시 사용자 수익률 상승을 보장하지는 않는다. 성과는 백테스트, 실현 손익, 슬리피지, 최대 낙폭 등 별도 지표로 검증해야 한다.

### 11.5 권장 비용 정책

Signal Provider별 가격과 품질을 함께 비교하고 Agora의 사용자당 비용 상한을 운영 데이터로 결정한다.

```text
최근 N건 Agora 자동 투자 작업의 P95 원가
├─ Signal Provider x402 비용
├─ 가스비 환산액
├─ 실패·재시도 예상비용
├─ DEX 관련 운영비
└─ 서버/RPC 원가 배분
        ↓
사용자당·Vault당 Agora 운영 비용 산정
```

권장 운영 지표:

- `signal_x402_cost`
- `platform_fee_amount`
- `provider_revenue`
- `agora_gas_sui`
- `agora_gas_usdc`
- `successful_trade_count`
- `failed_trade_count`
- `average_cost_per_success`
- `net_profit_per_trade`
- `net_margin_bps`
- `wallet_sui_runway`

### 11.6 Auto-Refill 구상

```text
Agora 운영 Treasury
→ 모니터가 AgoraAgent 운영 지갑 SUI 잔액 확인
→ 안전 기준 이하이면 운영 예산의 제한된 USDC만 사용
→ 허용된 DEX에서 USDC → SUI swap
→ AgoraAgent 운영 지갑 가스 잔액 보충
```

현재는 구현되지 않았다. 구현 시 다음 보안 정책이 필요하다.

- Agora Treasury와 AgoraAgent 실행 지갑의 관계 정의
- 자동 충전 전용 한도와 일일 최대액
- 허용 DEX package와 pool allowlist
- `min_amount_out`, 슬리피지, 만료 시간
- oracle 또는 견적 조작 방지
- 최소·목표 SUI 잔액과 cooldown
- 중복 실행 방지 lock
- 개인키를 FE나 저장소에 노출하지 않는 KMS/서명 서비스
- 실패 시 재시도 상한과 알림

Signal Provider x402 수령액은 Provider의 수익이며 AgoraAgent 가스 충전에 사용할 수 없다. Auto-Refill은 Agora 운영 Treasury의 별도 예산과 일일 상한으로 관리해야 한다.

## 12. 가스비 측정을 위한 코드 방향

현재 Move 컨트랙트를 수정해 가스비를 Vault나 이벤트에 직접 저장할 필요는 없다. Move 함수는 자신이 최종적으로 소비한 실제 가스비와 외부 환율을 신뢰성 있게 계산하는 계층이 아니며, Sui가 Transaction effects에 실행 비용을 제공한다.

권장 후속 서버 구성:

```text
Agent Transaction 실행 결과
→ digest와 effects 저장
→ gasUsed 추출
→ 성공/실패 분리
→ SUI/USDC 시점 가격 결합
→ x402 SignalPaymentReceiptEvent의 Provider 수령액과 연결
→ Signal Provider별 비용·품질 및 AgoraAgent 손익 DB 집계
```

현재 코드에는 실제 AgoraAgent 거래 실행 라우트와 DB가 없으므로 이번 갱신에서는 성급한 가스 회계 코드를 추가하지 않았다. 실제 `execute_buy/execute_sell`과 실행 서버가 연결될 때 signal provider ID, signal digest, gas effects, payment digest, vault ID를 하나의 실행 레코드로 저장해야 한다.

## 13. AgoraAgent 내부 가스 최적화 정책

사용자는 개별 Agent를 등록하거나 선택하지 않는다. 자동 투자 가스는 AgoraAgent가 부담하므로 다음 정책은 사용자 UX가 아니라 Agora 내부 운영 기준이다.

### 13.1 등록 시 권장 원칙

- AgoraAgent는 다수의 사용자 Vault를 무조건 개별 Transaction으로 반복 제출하지 않는다.
- 개별 Vault 구조를 유지한다면 여러 Vault 명령을 묶는 **chunked PTB batch**를 우선 검토한다.
- 단일 PTB가 너무 커지지 않도록 시뮬레이션 결과, 프로토콜 제한, 예상 가스, 실패 범위를 기준으로 batch 크기를 결정한다.
- 모든 사용자 자산을 하나의 Master Pool에 모으는 방식은 가스 효율이 높지만 현재 개별 Vault 모델과 다른 상품이므로 별도 회계·지분·출금·감사 설계 없이는 사용할 수 없다.
- 운영 전에 Testnet 실측 가스와 최악 비용, 예상 실행 빈도, 실패·재시도 정책을 검증한다.
- 운영 중 실제 Transaction effects를 수집해 예상 비용과 실제 비용의 차이를 모니터링한다.

“PTB 사용” 자체만으로 가스 최적화가 보장되지는 않는다. Sui SDK의 `Transaction`도 PTB이며, 하나의 Move call만 담은 PTB를 사용자 수만큼 반복하면 비용은 여전히 선형 증가한다. Agora가 요구해야 하는 것은 단순한 PTB 사용 여부가 아니라 **다중 Vault batch 전략 또는 그에 준하는 비용 효율화 계획**이다.

### 13.2 구조별 비용 증가 특성

| 구조 | 거래 제출 수 | 비용 특성 | 사용자별 설정 | 현재 권장도 |
|---|---:|---|---|---|
| 개별 처리 | 사용자 수에 비례 | 대체로 O(N) | 가능 | 초기 검증용 |
| Chunked PTB batch | batch 수에 비례 | 고정 overhead 공유, 명령·객체 수에 따라 증가 | 가능 | 개별 Vault의 권장 운영안 |
| Master Pool | 전략 거래 수에 비례 | 사용자 수와 직접 연결되지 않는 O(1)에 가까운 거래 실행 | 제한적 | 별도 상품으로만 검토 |

PTB batch도 가스가 완전히 고정되는 것은 아니다. 처리하는 Vault, Move call, Coin, shared object 수와 스토리지 작업이 늘면 가스도 증가한다. 또한 하나의 명령 실패가 전체 PTB를 롤백할 수 있으므로 모든 사용자 Vault를 무제한으로 한 Transaction에 묶지 않는다.

### 13.3 사용자 고지와 내부 책임

사용자에게는 자동 투자 Transaction의 가스를 AgoraAgent가 부담한다는 사실과, 사용자가 직접 실행하는 Vault 생성·입금·출금에는 가스가 발생한다는 사실을 구분해 표시한다.

> 자동 투자와 Signal Provider 신호 구매의 가스는 AgoraAgent가 부담합니다. Vault 생성, USDC 예치 및 Wallet 출금처럼 사용자가 직접 서명하는 온체인 작업에는 네트워크 가스가 발생할 수 있습니다.

Agora는 운영 signer의 SUI 잔액, 일일 가스 예산, 재시도 비용과 batch 실패 비용을 내부적으로 부담하고 모니터링한다.

### 13.4 Agora 운영 체크리스트

- 실행 모델: individual / chunked PTB batch / master pool
- batch당 최대 Vault 수와 결정 근거
- Testnet gas benchmark digest 및 effects
- 평균·P95·최악 예상 가스
- 일일 최대 거래 횟수
- dry-run과 실패 Transaction 차단 정책
- 부분 실패를 위한 batch 분할 정책
- shared object 혼잡과 stale object 재시도 정책
- AgoraAgent SUI 최소 잔액과 중단 기준
- Auto-Refill 사용 여부와 일일 한도
- Signal Provider별 x402 가격 대비 품질
- 사용자당·Vault당 예상 운영 비용

PTB 명령·입력 객체의 최대치는 Sui protocol version에 따라 달라질 수 있으므로 `1,024 commands`, `2,048 objects` 같은 숫자를 등록 정책에 영구 하드코딩하지 않는다. 배포 대상 네트워크의 최신 protocol config와 실제 Transaction build/simulation 결과를 기준으로 검사한다.

## 14. 테스트 현황

2026-07-26 재검증 결과:

```text
Move test result: OK
Total tests: 30
Passed: 30
Failed: 0

TypeScript check: PASS
Command: tsc --noEmit
```

주요 검증 범위:

- owner의 Vault 생성, FiatT 입금, 일부·전체 출금
- FiatT와 CryptoT의 분리 관리
- owner가 아닌 주소의 출금·설정 변경 차단
- AgoraAgent가 출금할 수 없음
- 등록된 AgoraAgent 요청 성공
- 미등록·중지·교체된 주소의 요청 실패
- BUY/SELL 0 수량 차단
- BUY/SELL 1회 한도
- BUY/SELL epoch 누적 한도
- epoch 변경 시 누적량 초기화
- BUY는 FiatT만, SELL은 CryptoT만 검사
- FiatT 잔액으로 CryptoT SELL을 충족할 수 없음
- 요청만으로 Vault 자산이 이동하지 않음
- AgoraAgent가 지불하는 x402 신호 사용료 80:20 분배
- 100% 초과 플랫폼 수수료 차단
- Signal Provider 등록 정보와 x402 수령 주소
- AgoraInvest 신호 digest와 위험 점수 기록
- 10,000 bps 초과 위험 점수 차단
- 성과 수수료 bps 계산

실행 명령:

```bash
cd sui-contract
sui move test

cd agent-execution-server
npm run typecheck
```

현재 Move 빌드에는 중복 import alias 경고가 있지만 테스트 실패는 아니다. 제출 전 코드 품질 정리 단계에서 제거할 수 있다.

## 15. Testnet E2E 검수 계획

### 15.1 자산 역할

```text
사용자 지갑 Testnet SUI  → 사용자 Transaction 가스
사용자 지갑 Testnet USDC → Vault FiatT 입금
AgoraAgent Testnet USDC   → Signal Provider x402 결제
AgoraAgent 지갑 Testnet SUI → x402 및 request_buy/request_sell 실행 가스
Vault CryptoT SUI        → 향후 DEX BUY 결과
```

Circle Sui Testnet USDC 타입 예시:

```text
0xa1ec7fc00a6f40db9693ad1415d0c193ad3906494428cf252621037bd7117e29::usdc::USDC
```

배포 전 공식 문서에서 최신 Testnet 주소를 다시 확인해야 한다.

### 15.2 지금 가능한 트랙

```text
FE Sui Wallet 연결
→ Testnet SUI와 USDC 준비
→ UserVault<USDC, SUI> 생성
→ FiatT 추가 입금
→ AgoraAgent의 x402 신호 사용료 결제 및 80:20 분배
→ 서버 결제 영수증 검증
→ AgoraInvest의 request_buy 실행
→ FiatBuyRequested·AgoraBuyDecisionRecorded 및 epoch 누적량 확인
→ CryptoT가 0인 SELL 실패 확인
```

### 15.3 아직 불가능한 트랙

```text
Vault USDC 감소
→ 실제 DEX에서 SUI 매수
→ Vault crypto_balance 증가
→ SUI 매도
→ Vault fiat_balance 증가
```

이를 완주하려면 Mock DEX 또는 실제 DEX와 `execute_buy/execute_sell` 정산 함수가 필요하다.

## 16. 현재 보안 불변식

- AgoraAgent는 owner가 아니다.
- AgoraAgent는 Vault에서 출금할 수 없다.
- owner는 언제든 AgoraAgent를 중지하거나 교체할 수 있다.
- Signal Provider는 Vault 권한이 없다.
- 사용자 일반 입금은 FiatT만 허용한다.
- BUY는 FiatT만 입력으로 사용한다.
- SELL은 CryptoT만 입력으로 사용한다.
- FiatT와 CryptoT 한도 및 epoch 누적량은 분리한다.
- 금액 0 요청을 차단한다.
- 새 epoch 한도는 이미 사용한 누적량보다 작을 수 없다.
- x402 결제 토큰·가격·수령자·Signal Provider·Treasury를 서버가 검증한다.
- 하나의 x402 digest는 API 권한 해제에 한 번만 사용할 수 있다.
- 실제 DEX 거래 결과는 향후 AgoraAgent 지갑이 아니라 동일 Vault에 직접 정산해야 한다.

## 17. 확인된 한계와 리스크

높은 우선순위:

1. 실제 DEX 실행과 자산 정산이 없다.
2. 요청 시점에 epoch 사용량이 증가하며 실제 거래 성공과 아직 결합되지 않았다.
3. 기존 Vault 요청 함수가 public이어서 AgoraInvest 신호 기록을 우회할 수 있다.
4. Signal Provider Registry와 AgoraAgent의 실제 탐색·평가 로직이 연결되지 않았다.
5. replay 저장소가 메모리 기반이다.
6. AgoraAgent 실행 키의 KMS·보안 정책이 없다.
7. Unit Economics DB와 실제 gas effects 수집기가 없다.
8. Auto-Refill이 없다.
9. Fee Vault의 bps 범위·overflow 방어가 부족하다.
10. 실제 DEX 슬리피지, deadline, pool allowlist, oracle 정책이 없다.
11. Dynamic Bag 전환 전에는 Vault당 FiatT/CryptoT 한 쌍만 지원한다.

## 18. 다음 개발 순서

1. AgoraInvest를 공식 유일 BUY/SELL 실행 경로로 제한
2. Signal Provider Registry와 AgoraAgent의 Provider 평가·선택 로직 연결
3. Fee Vault의 bps·overflow 보완
4. x402 replay 저장소를 Redis/DB로 교체
5. AgoraAgent 실행 라우트, 운영 signer, dry-run, 실패 처리 구현
6. 실행 레코드에 provider ID, signal digest, payment digest, trade digest, Vault ID, gas effects 저장
7. Signal Provider별 품질과 AgoraAgent Unit Economics 집계
8. Mock DEX로 `execute_buy/execute_sell` 원자적 정산 검증
9. 실제 Testnet DEX 한 개와 pool allowlist 연결
10. Auto-Refill 정책 및 제한된 실행기 구현
11. Dynamic Field/Bag 기반 다중 Crypto 확장
12. Owner 설정 변경용 Sponsored Transaction 적용 여부 검토

## 19. 대회 제출용 핵심 요약

본 프로젝트의 차별점은 외부 Signal Provider에게 사용자 자산을 직접 맡기지 않고, 온체인 Vault가 AgoraAgent의 권한·자산 타입·1회 한도·epoch 누적 한도를 강제한다는 점이다. AgoraAgent는 BUY와 SELL을 요청할 수 있지만 출금할 수 없고, 사용자는 언제든 AgoraAgent를 중지하거나 교체할 수 있다.

x402는 Signal Provider의 투자 신호를 유료 API로 전환한다. AgoraAgent가 지불한 사용료는 온체인에서 Provider와 플랫폼에 즉시 분배되며, 서버는 Transaction Digest와 `SignalPaymentReceiptEvent`를 검증해 결제된 요청만 실행한다.

지속 가능한 수익 모델은 단순히 “Sui 가스가 저렴하다”는 가정이 아니라 다음 조건으로 평가한다.

```text
Agora 서비스 수익
> Signal Provider x402 비용
  + AgoraAgent 가스비의 USDC 환산액
  + DEX 및 실패·재시도 비용
  + 서버/RPC/키 관리 비용
```

향후 실제 Transaction effects를 수집해 Signal Provider별 품질·비용과 AgoraAgent의 성공당 원가, 사용자당 운영비, SUI 잔여 운용 시간을 계산한다.

개별 Vault 모델에는 chunked PTB batch 또는 그에 준하는 비용 최적화가 필요하다. 실행 구조와 빈도로 발생하는 가스비는 Agora의 Unit Economics에 포함한다.

## 20. 참고 자료

- Sui Documentation: https://docs.sui.io/
- Sui TypeScript SDK Transactions: https://sdk.mystenlabs.com/sui/transactions/basics
- Sui Signing, Execution and Gas: https://sdk.mystenlabs.com/sui/transactions/signing-and-execution
- Sui Core API Transaction Effects: https://sdk.mystenlabs.com/sui/clients/core
- Sui Sponsor Best Practices: https://sdk.mystenlabs.com/sponsor/best-practices
- Circle USDC Contract Addresses: https://developers.circle.com/stablecoins/usdc-contract-addresses
