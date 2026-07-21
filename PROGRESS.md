# Agora 전체 프로젝트 개발 진행 및 기술 보고서

최종 갱신: 2026-07-20
기준 경로: 프로젝트 최상위 `MarketPlace/` 전체
검증 상태: Move 테스트 27/27 통과, TypeScript/JavaScript 타입 검사 통과

## 0. 전체 영역 진행 상태

| 영역 | 폴더 | 현재 상태 |
|---|---|---|
| Frontend / UX | `thezoneagora-main/` | 랜딩, Sui Wallet 연결 기반, Agent 비교 대시보드와 차트 구현. Vault·x402·Agent 등록 실연동은 아직 없음 |
| Smart Contract / SDK | `sui-contract/` | 2자산 Vault, Agent 권한·한도, Marketplace 기초, x402 분배, Transaction 빌더와 27개 테스트 구현 |
| Agent Backend | `agent-execution-server/` | x402 결제 검증 미들웨어 구현. 실제 Express 실행 서버·AI 판단·Agent signer·거래 라우트는 아직 없음 |
| 기획·보고 자료 | `Project_Info/` | Agent onboarding, Vault 설명, Marketplace 및 전략 보고서 HTML 보관 |
| 통합 E2E | 전체 | FE 지갑 → x402 결제 → Agent 실행 → Vault → 실제 DEX의 전체 트랙은 아직 미완성 |

현재 가장 중요한 통합 과제는 프런트엔드, Agent 실행 서버, Sui 컨트랙트 사이의 인터페이스를 고정하고 Testnet에서 단계별로 연결하는 것이다.

## 1. 프로젝트 개요

이 프로젝트는 사용자가 자산 소유권과 최종 출금 권한을 유지하면서 AI Agent에게 제한된 자동 거래 권한만 위임하는 Sui 기반 투자 Vault 시스템이다.

Agent API의 유료 호출에는 HTTP `402 Payment Required` 기반 x402 흐름을 사용한다. 사용자가 Agent 사용료를 온체인에서 결제하면 제작자와 플랫폼 Treasury에 즉시 분배되고, Agent 서버는 결제 영수증을 검증한 뒤 Vault 거래 요청을 수행한다.

현재 구현 범위는 다음과 같다.

- 사용자의 기준 자산과 투자 자산을 분리 보관하는 shared Vault
- owner 전용 입금·출금·Agent 관리 기능
- Agent 전용 BUY/SELL 요청 권한과 1회·epoch 누적 한도
- FiatT는 BUY 입력, CryptoT는 SELL 입력으로 고정하는 자산 역할 정책
- Sui Transaction 빌더
- x402 온체인 사용료 분배 컨트랙트
- HTTP 402 응답, 결제 영수증 검증 및 재사용 방지 미들웨어
- 연결된 사용자 지갑을 이용한 x402 결제·재요청 클라이언트
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
├─ 출금 및 Agent 권한 중지·교체
└─ x402 Agent 사용료 결제

Agent
├─ 허용된 BUY/SELL 요청
├─ 1회 및 epoch 한도 준수
└─ 향후 허용된 DEX 거래 실행

온체인 Vault
├─ 자산 타입과 역할 분리
├─ 실제 서명자 기반 권한 검사
├─ 잔액 및 한도 검사
└─ 거래 결과를 Agent 지갑이 아닌 Vault에 보관

플랫폼
├─ Agent Marketplace 운영
├─ x402 결제 검증
├─ 플랫폼 수수료 수령
└─ 향후 Agent 품질 및 수익성 지표 제공
```

## 3. 기술 스택

| 영역 | 기술 | 현재 사용 목적 |
|---|---|---|
| Blockchain | Sui | 객체 기반 자산 보관, 트랜잭션 실행, 이벤트 기록 |
| Smart Contract | Sui Move, edition 2024 | Vault, Agent Registry, Follow, Fee Vault, Payment Splitter |
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
| Wallet | Sui Wallet/dApp Kit 연동 인터페이스 | 사용자 서명 및 결제 제출 |
| Payment | HTTP 402 + 온체인 영수증 | Agent 유료 호출 및 80:20 즉시 분배 |
| Test | `sui move test`, `tsc --noEmit` | Move 보안 불변식 및 SDK 타입 검사 |

Move 패키지 이름은 `agent_market`이며 named address는 개발 시 `0x0`을 사용한다. 실제 Testnet 호출에는 배포 후 생성된 package ID가 필요하다.

## 4. 전체 프로젝트 구조와 파일 역할

```text
MarketPlace/
├─ PROGRESS.md                         전체 프로젝트 진행 기준 문서
├─ AGENT_OWNER_GAS_WARNING.md          Agent 등록 가스 정책·향후 UX 요구사항
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
   │  │  ├─ agent_registry.move        Agent 정보 객체
   │  │  ├─ follow.move                Follow 비용·영수증
   │  │  └─ payment_splitter.move      x402 사용료 온체인 분배
   │  └─ Dex/
   │     ├─ Vault_Dex.js               Vault PTB 빌더
   │     └─ x402_client.js              402 결제·재요청 클라이언트
   └─ tests/
      ├─ vault/                         Vault·Fee Vault Move 테스트
      └─ marketplace/                   Registry·Follow·Payment 테스트
```

생성 폴더와 파일인 `node_modules/`, `.next/`, `sui-contract/build/`, `tsconfig.tsbuildinfo`, `.DS_Store`는 위 구조에서 제외했다.

`build/`는 Move 컴파일 산출물이므로 직접 수정하지 않는다. `.env`에는 배포 package ID와 네트워크별 설정을 두되 개인키와 비밀값을 프런트엔드 환경변수에 저장하면 안 된다.

### 4.1 Frontend 현재 구현 상태

구현됨:

- 랜딩 페이지와 데모 진입 동선
- Sui Wallet Provider 및 지갑 연결 UI 기반
- 지갑 종류에 따른 Agent 필터 규칙
- Agent 카드, 상세 모달, 리더보드, 레이스 트랙
- Agent별 equity curve 차트
- mock 전략 시뮬레이터와 snapshot 데이터 계층
- MINT 실데이터 예시 패널
- 반응형 레이아웃과 애니메이션

아직 연결되지 않음:

- Testnet 배포 package ID 기반 Vault 생성·입금·출금
- `Vault_Dex.js` Transaction 빌더 import 및 지갑 실행
- x402 클라이언트와 Agent API 호출
- Agent 등록 화면
- `AGENT_OWNER_GAS_WARNING.md`의 경고·필수 동의 UX
- 온체인 Agent Registry 및 FollowRecord 조회
- 실제 Vault 잔액·이벤트·거래 결과 표시

### 4.2 Agent 실행 서버 현재 구현 상태

현재 `x402Middleware.ts`만 구현되어 있다. HTTP 402 challenge 생성, Sui 결제 Transaction 조회, `PaymentReceiptEvent` 검증, 결제 유효 시간과 replay를 검사한다.

실제 Express 앱 진입점, Agent AI 실행, 운영 signer, Vault BUY/SELL Transaction 제출, 거래 결과 DB, Redis replay 저장소와 가스 원가 수집기는 아직 없다.

### 4.3 Sui Contract 현재 구현 상태

Move 컨트랙트와 JavaScript Transaction 빌더는 Vault 권한·한도·자산 역할, Marketplace 기초, x402 분배까지 구현되어 있다. 실제 DEX swap과 결과 자산 정산은 아직 없으며 상세 내용은 이후 장에서 모듈별로 정리한다.

## 5. Investment Vault 설계

### 5.1 Vault 데이터 구조

`UserVault<FiatT, CryptoT>`는 shared object다.

| 필드 | 의미 |
|---|---|
| `id` | Vault 객체 UID |
| `owner` | 출금 및 설정 변경 권한을 가진 사용자 |
| `agent_operator` | 거래 요청 권한을 가진 Agent 운영 지갑 |
| `agent_active` | Agent 권한 활성 여부 |
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

### 5.2 사용자와 Agent의 자산 역할

- 사용자는 공개 함수 `deposit_more`를 통해 FiatT만 입금할 수 있다.
- 운영 배포본에는 사용자가 CryptoT를 직접 입금하는 공개 경로가 없다.
- `deposit_crypto_for_testing`은 `#[test_only]`이므로 단위 테스트에서만 존재한다.
- CryptoT는 향후 성공한 `execute_buy`의 DEX 결과로만 증가해야 한다.
- Agent BUY는 `fiat_balance`만 검사한다.
- Agent SELL은 `crypto_balance`만 검사한다.
- owner는 FiatT와 CryptoT를 각각 또는 전부 출금할 수 있다.

이 정책은 사용자가 투자 결과인 것처럼 임의의 CryptoT를 주입하거나 Agent가 BUY에 CryptoT, SELL에 FiatT를 잘못 사용하는 것을 차단한다.

### 5.3 공개 함수 목록

| 함수 | 허용 호출자 | 현재 역할 |
|---|---|---|
| `create_vault` | 사용자 | FiatT 초기 예치, Agent 주소와 BUY/SELL 한도 설정, shared Vault 생성 |
| `deposit_more` | owner | FiatT 추가 입금 |
| `withdraw_all_assets` | owner | FiatT와 CryptoT 전액 출금 |
| `withdraw_amount` | owner | FiatT 일부 출금 |
| `withdraw_crypto_amount` | owner | CryptoT 일부 출금 |
| `revoke_agent` | owner | Agent 권한 비활성화 |
| `reactivate_agent` | owner | 기존 Agent 권한 재활성화 |
| `replace_agent` | owner | Agent 운영 주소 교체 후 활성화 |
| `update_trade_limit` | owner | FiatT BUY 1회 한도 변경 |
| `update_epoch_trade_limit` | owner | FiatT BUY epoch 한도 변경 |
| `update_crypto_sell_limit` | owner | CryptoT SELL 1회 한도 변경 |
| `update_epoch_crypto_sell_limit` | owner | CryptoT SELL epoch 한도 변경 |
| `request_trade` | 등록 Agent | 기존 FE 호환용 BUY 별칭 |
| `request_buy` | 등록 Agent | FiatT BUY 요청 검증·누적·이벤트 |
| `request_sell` | 등록 Agent | CryptoT SELL 요청 검증·누적·이벤트 |
| `vault_balance` | Move 호출부 | 호환용 FiatT 잔액 조회 |
| `fiat_balance` | Move 호출부 | FiatT 잔액 조회 |
| `crypto_balance` | Move 호출부 | CryptoT 잔액 조회 |

테스트 전용 `deposit_crypto_for_testing`은 운영 API가 아니다.

### 5.4 내부 보안 검사

- `assert_agent_authorized`: `tx_context::sender(ctx)`가 등록 Agent인지, Agent가 활성 상태인지 검사한다.
- `assert_fiat_buy_amount_allowed`: BUY 금액이 0보다 크고 1회 한도 이하인지 검사한다.
- `assert_crypto_sell_amount_allowed`: SELL 수량이 0보다 크고 1회 한도 이하인지 검사한다.
- `refresh_spending_epoch`: epoch가 바뀌면 BUY/SELL 누적량을 모두 0으로 초기화한다.
- `assert_epoch_fiat_buy_amount_allowed`: BUY 요청을 더해도 FiatT epoch 한도를 넘지 않는지 검사한다.
- `assert_epoch_crypto_sell_amount_allowed`: SELL 요청을 더해도 CryptoT epoch 한도를 넘지 않는지 검사한다.

epoch 한도 변경 시 새 한도가 이미 사용한 양보다 작아질 수 없다. 이미 기록된 누적 사용량보다 작은 한도를 허용하면 `현재 사용량 > 현재 한도`라는 모순 상태가 생기기 때문이다.

### 5.5 이벤트

`FiatBuyRequested<FiatT, CryptoT>`:

- Vault ID
- Agent 운영 주소
- BUY FiatT 수량
- epoch
- 요청 후 epoch 누적 BUY 수량

`CryptoSellRequested<FiatT, CryptoT>`:

- Vault ID
- Agent 운영 주소
- SELL CryptoT 수량
- epoch
- 요청 후 epoch 누적 SELL 수량

현재 이벤트는 거래 실행 완료 증명이 아니라 요청 검증 완료 기록이다.

## 6. 현재 Vault 거래 Workflow

### 6.1 Vault 생성 및 입금

```text
사용자 FE
→ 연결 지갑에서 FiatT Coin 선택
→ buildCreateVaultTransaction
→ 사용자 승인 및 서명
→ investment_vault::create_vault
→ FiatT가 fiat_balance에 보관됨
→ crypto_balance는 0으로 시작
```

### 6.2 Agent BUY 요청

```text
Agent 운영 지갑 서명
→ shared UserVault 입력
→ 실제 서명자 == agent_operator 검사
→ agent_active 검사
→ epoch 변경 시 누적량 초기화
→ BUY 수량 > 0 검사
→ FiatT 1회 한도 검사
→ FiatT epoch 누적 한도 검사
→ fiat_balance 충분 여부 검사
→ spent_this_epoch 증가
→ FiatBuyRequested 발생
```

### 6.3 Agent SELL 요청

```text
Agent 운영 지갑 서명
→ Agent 권한 및 활성 상태 검사
→ epoch 갱신
→ CryptoT 1회 및 epoch 한도 검사
→ crypto_balance 충분 여부 검사
→ spent_crypto_this_epoch 증가
→ CryptoSellRequested 발생
```

현재 `request_buy`와 `request_sell`은 자산을 이동하거나 swap하지 않는다. 요청이 성공하면 누적량과 이벤트만 변경된다.

## 7. JavaScript Transaction 계층

### 7.1 `Vault_Dex.js`

Sui `Transaction`은 온체인에서 실행할 명령을 조립하는 PTB 빌더다. `new Transaction()`이나 `moveCall`만으로는 가스가 들거나 상태가 변경되지 않는다. 서명된 Transaction이 네트워크에 제출될 때 실행된다.

공통 검증:

- Sui 주소 및 object ID 정규화
- package ID 존재 여부
- Move coin type 형식
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

### 7.2 PTB 원자성

향후 실제 거래는 가능하면 다음 명령을 하나의 PTB로 묶는다.

```text
하나의 Transaction
├─ Agent 권한·한도·잔액 검증
├─ Vault에서 입력 Coin 분리
├─ 허용된 DEX swap
├─ min_amount_out 검사
├─ 결과 Coin을 Vault에 합치기
└─ 성공한 거래량과 이벤트 기록
```

중간 명령이 실패하면 전체 상태 변경이 롤백된다. 다만 실패한 온체인 트랜잭션도 실행에 사용된 가스가 발생할 수 있다.

## 8. Marketplace 모듈

### 8.1 `agent_registry.move`

`Agent` 객체는 이름, SUI 단위 follow 비용, 수수료 수령 주소, 활성 상태를 저장한다. `create_agent`, `follow_fee`, `receiver`, `is_active`가 구현되어 있다.

현재 Agent는 생성자에게 전송되는 owned object다. 따라서 제3자가 `&Agent` 입력으로 follow하기 어려울 수 있다. 공개 Marketplace를 위해서는 Agent를 shared object로 전환하고, 수정 권한은 별도 `AgentAdminCap` owned object로 분리하는 것이 권장된다.

### 8.2 `follow.move`

활성 Agent에 정확한 SUI follow 비용을 지불하면 수령 주소로 Coin을 전송하고 사용자에게 `FollowRecord`를 발급한다.

현재 `FollowRecord.agent_id_hint`는 실제 Agent object ID가 아니라 수수료 수령 주소를 저장한다. 실제 Agent ID 저장으로 수정해야 한다.

### 8.3 `fee_vault.move`

성과 수수료 수령 주소와 bps를 저장하고 `calculate_performance_fee`를 제공하는 학습용 뼈대다. 실제 Vault 수익 및 정산과 연결되지 않았다.

현재 개선 필요 사항:

- `performance_fee_bps <= 10_000` 검사
- `profit_mist * performance_fee_bps`의 `u64` overflow 방지
- 원금, 평가액, 확정 수익의 정의
- 실제 수수료 Coin 분리 및 전송

## 9. x402 결제 계층

### 9.1 온체인 `payment_splitter.move`

`pay_agent_usage_fee<T>`는 사용자가 낸 `Coin<T>`를 Agent 제작자와 플랫폼 Treasury에 즉시 분배한다.

```text
총 사용료 P
├─ 제작자 수령: P - platform_fee
└─ Treasury 수령: platform_fee

platform_fee = floor(P × platform_fee_bps / 10,000)
```

현재 기본 예시는 `2,000 bps = 20%`이며 제작자 80%, 플랫폼 20%다. 곱셈 overflow 위험을 줄이기 위해 몫과 나머지를 나눠 계산한다.

`PaymentReceiptEvent<T>` 기록값:

- `payer`
- `payee`
- `treasury`
- `agent_id`
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
- Agent ID
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
Agent API 최초 POST
→ 402 challenge 수신
→ 가격·토큰·주소·bps 검증
→ pay_agent_usage_fee Transaction 생성
→ 연결된 사용자 지갑 서명 및 제출
→ Tx Digest 획득
→ PAYMENT-SIGNATURE 헤더로 동일 요청 재전송
→ Agent 최종 결과 반환
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
| Agent 중지·교체·한도 변경 | 사용자 | 사용자 지갑 |
| Agent follow | follower | follower 지갑 |
| x402 사용료 결제·분배 | 사용자 | 사용자 지갑 |
| `request_buy`/`request_sell` | Agent 운영 지갑 | Agent 운영자 |
| 향후 실제 DEX BUY/SELL | Agent 운영 지갑 | Agent 운영자 |
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
1. 최초 HTTP Agent 호출                    → 온체인 가스 없음
2. x402 사용료 결제 Transaction             → 사용자 가스 1회
3. PAYMENT-SIGNATURE를 포함한 HTTP 재요청   → 온체인 가스 없음
4. 서버의 결제 Transaction RPC 검증          → 온체인 가스 없음
5. Agent의 request_buy/request_sell 제출     → Agent 가스 1회
```

따라서 현재 한 번의 유료 Agent 거래 요청은 기본적으로 온체인 Transaction 2개다. 향후 요청 검증, DEX swap, Vault 정산을 하나의 Agent PTB로 묶으면 Agent 측 거래 실행은 가스 1회로 유지할 수 있다. 이를 여러 독립 Transaction으로 나누면 각 Transaction마다 별도 가스가 발생한다.

## 11. Agent Owner Unit Economics

### 11.1 정확한 순수익 공식

플랫폼 수수료가 20%인 현재 구조에서 Agent 제작자의 건당 실수령액은 총 x402 사용료가 아니라 분배 후 금액이다.

$$
R_{creator} = P_{x402} \times (1 - f_{platform})
$$

$$
C_{gas,USDC} = G_{SUI} \times Price_{SUI/USDC}
$$

$$
Profit_{agent} = R_{creator} - C_{gas,USDC} - C_{DEX} - C_{infra} - C_{other}
$$

변수:

- $P_{x402}$: 사용자가 낸 총 x402 사용료
- $f_{platform}$: 플랫폼 수수료율, 현재 예시 0.20
- $G_{SUI}$: Agent가 실제 사용한 순가스 SUI
- $Price_{SUI/USDC}$: 거래 시점 SUI/USDC 가격
- $C_{DEX}$: swap fee, price impact 등 Agent가 부담하기로 한 비용
- $C_{infra}$: RPC, 서버, 키 관리, 모니터링 비용
- $C_{other}$: 환전, 자동 충전, 실패·재시도 비용

손익분기 x402 가격은 다음과 같다.

$$
P_{break-even} =
\frac{C_{gas,USDC} + C_{DEX} + C_{infra} + C_{other}}
{1 - f_{platform}}
$$

예를 들어 플랫폼 수수료가 20%라면 Agent 제작자는 총 사용료의 80%를 받는다. 따라서 Agent 비용이 건당 0.04 USDC라면 이론상 최소 총 사용료는 `0.04 / 0.8 = 0.05 USDC`다. 실제 가격에는 SUI 가격 변동, 실패율, 운영 마진을 추가해야 한다.

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
→ Agent별·거래별 원가 DB 적재
```

정확한 필드 구조와 순비용 계산은 사용 중인 RPC 버전의 effects 응답을 기준으로 구현해야 한다.

### 11.3 팔로워 증가와 수익 확장에 대한 주의

팔로워 100명이 각자 별도의 Vault를 가지고 있으면 현재 구조에서는 일반적으로 Vault 100개에 대한 실행이 필요하다. 따라서 수익은 100배 늘지만 가스가 거의 그대로라는 가정은 현재 구현에 적용되지 않는다.

```text
현재 구조
100명 x402 결제 → 제작자 수익 100건
100개 Vault 거래 → Agent 가스도 최대 100건 수준
```

여러 Vault 작업을 하나의 PTB에 묶는 최적화는 가능하지만 다음 제약이 있다.

- PTB 명령·입력 크기 제한
- shared object 접근 및 혼잡
- 한 사용자 거래 실패 시 전체 batch 롤백 가능성
- 가스가 고정되지 않고 명령 수에 따라 증가
- 사용자별 슬리피지·한도·잔액 차이

따라서 대회 보고서에서는 “팔로워 증가로 매출이 확장되고 고정 인프라비가 분산된다”고 설명하는 것이 정확하다. 가스비가 팔로워 수와 무관하다고 단정하지 않는다.

### 11.4 가스비가 만드는 Agent 품질 인센티브

Agent 운영자가 거래 가스를 부담하면 다음과 같은 인센티브가 생긴다.

- 무의미한 고빈도 호출 감소
- 실패 가능성이 큰 Transaction의 사전 시뮬레이션
- 확신도가 높은 거래 신호 중심 실행
- PTB 단위 최적화
- Agent별 성공률, 가스 원가, 순마진 모니터링

다만 과도한 거래 억제가 반드시 사용자 수익률 상승을 보장하지는 않는다. 성과는 백테스트, 실현 손익, 슬리피지, 최대 낙폭 등 별도 지표로 검증해야 한다.

### 11.5 권장 가격 정책

단순 고정 가격보다 실제 운영 데이터를 이용한 안전 마진 기반 가격이 적합하다.

```text
최근 N건 Agent 거래의 P95 원가
├─ 가스비 환산액
├─ 실패·재시도 예상비용
├─ DEX 관련 운영비
└─ 서버/RPC 원가 배분
        ↓
목표 제작자 마진 추가
        ↓
플랫폼 수수료를 역산
        ↓
x402 사용자 가격 결정
```

권장 운영 지표:

- `gross_x402_revenue`
- `platform_fee_amount`
- `creator_revenue`
- `agent_gas_sui`
- `agent_gas_usdc`
- `successful_trade_count`
- `failed_trade_count`
- `average_cost_per_success`
- `net_profit_per_trade`
- `net_margin_bps`
- `wallet_sui_runway`

### 11.6 Auto-Refill 구상

```text
x402 결제
→ payment_splitter가 제작자 수익 지갑에 USDC 전송
→ 모니터가 Agent 운영 지갑 SUI 잔액 확인
→ 안전 기준 이하이면 제한된 USDC만 사용
→ 허용된 DEX에서 USDC → SUI swap
→ Agent 운영 지갑 가스 잔액 보충
```

현재는 구현되지 않았다. 구현 시 다음 보안 정책이 필요하다.

- 제작자 수익 지갑과 Agent 실행 지갑의 관계 정의
- 자동 충전 전용 한도와 일일 최대액
- 허용 DEX package와 pool allowlist
- `min_amount_out`, 슬리피지, 만료 시간
- oracle 또는 견적 조작 방지
- 최소·목표 SUI 잔액과 cooldown
- 중복 실행 방지 lock
- 개인키를 FE나 저장소에 노출하지 않는 KMS/서명 서비스
- 실패 시 재시도 상한과 알림

현재 `payment_splitter`의 `payee`는 Agent 운영 지갑과 자동으로 동일하지 않다. Auto-Refill을 만들기 전에 제작자 수익 지갑이 직접 충전할지, 플랫폼 Treasury가 관리형 sponsor가 될지 정책을 결정해야 한다.

## 12. 가스비 측정을 위한 코드 방향

현재 Move 컨트랙트를 수정해 가스비를 Vault나 이벤트에 직접 저장할 필요는 없다. Move 함수는 자신이 최종적으로 소비한 실제 가스비와 외부 환율을 신뢰성 있게 계산하는 계층이 아니며, Sui가 Transaction effects에 실행 비용을 제공한다.

권장 후속 서버 구성:

```text
Agent Transaction 실행 결과
→ digest와 effects 저장
→ gasUsed 추출
→ 성공/실패 분리
→ SUI/USDC 시점 가격 결합
→ x402 PaymentReceiptEvent의 creator 수령액과 연결
→ Agent별 손익 DB 집계
```

현재 코드에는 실제 Agent 거래 실행 라우트와 DB가 없으므로 이번 갱신에서는 성급한 가스 회계 코드를 추가하지 않았다. 실제 `execute_buy/execute_sell`과 실행 서버가 연결될 때 digest, gas effects, payment digest, vault ID를 하나의 실행 레코드로 저장해야 한다.

## 13. Agora Agent 등록 가스 최적화 정책

Agora에 Agent를 등록하려는 제작자는 거래 실행 구조와 가스비 책임을 사전에 확인해야 한다. 별도 UX 참고 문서는 프로젝트 최상위 `AGENT_OWNER_GAS_WARNING.md`에 정리한다.

### 13.1 등록 시 권장 원칙

- Agent는 다수의 사용자 Vault를 무조건 개별 Transaction으로 반복 제출하지 않는다.
- 개별 Vault 구조를 유지한다면 여러 Vault 명령을 묶는 **chunked PTB batch**를 우선 검토한다.
- 단일 PTB가 너무 커지지 않도록 시뮬레이션 결과, 프로토콜 제한, 예상 가스, 실패 범위를 기준으로 batch 크기를 결정한다.
- 모든 사용자 자산을 하나의 Master Pool에 모으는 방식은 가스 효율이 높지만 현재 개별 Vault 모델과 다른 상품이므로 별도 회계·지분·출금·감사 설계 없이는 사용할 수 없다.
- 등록 전에 Testnet 실측 가스와 최악 비용, 예상 실행 빈도, 실패·재시도 정책을 제출한다.
- 운영 중 실제 Transaction effects를 수집해 예상 비용과 실제 비용의 차이를 모니터링한다.

“PTB 사용” 자체만으로 가스 최적화가 보장되지는 않는다. Sui SDK의 `Transaction`도 PTB이며, 하나의 Move call만 담은 PTB를 사용자 수만큼 반복하면 비용은 여전히 선형 증가한다. Agora가 요구해야 하는 것은 단순한 PTB 사용 여부가 아니라 **다중 Vault batch 전략 또는 그에 준하는 비용 효율화 계획**이다.

### 13.2 구조별 비용 증가 특성

| 구조 | 거래 제출 수 | 비용 특성 | 사용자별 설정 | 현재 권장도 |
|---|---:|---|---|---|
| 개별 처리 | 사용자 수에 비례 | 대체로 O(N) | 가능 | 초기 검증용 |
| Chunked PTB batch | batch 수에 비례 | 고정 overhead 공유, 명령·객체 수에 따라 증가 | 가능 | 개별 Vault의 권장 운영안 |
| Master Pool | 전략 거래 수에 비례 | 사용자 수와 직접 연결되지 않는 O(1)에 가까운 거래 실행 | 제한적 | 별도 상품으로만 검토 |

PTB batch도 가스가 완전히 고정되는 것은 아니다. 처리하는 Vault, Move call, Coin, shared object 수와 스토리지 작업이 늘면 가스도 증가한다. 또한 하나의 명령 실패가 전체 PTB를 롤백할 수 있으므로 모든 팔로워를 무제한으로 한 Transaction에 묶지 않는다.

### 13.3 등록 UX에 표시할 책임 고지

향후 Agent 등록 화면에는 다음 의미의 경고와 필수 동의를 표시한다.

> Agent 제작자는 자신의 거래 실행 트랜잭션에서 발생하는 가스비와 재시도 비용을 부담합니다. 개별 Vault Transaction 반복 제출, 과도한 실행 빈도 또는 비용 최적화 미적용으로 발생한 추가 가스비는 원칙적으로 Agora의 보상 대상이 아닙니다. 등록 전 batch 전략과 예상 비용을 검증해 주세요.

최종 이용약관 문구는 서비스 국가의 소비자보호·전자금융·면책 제한 규정을 반영해 법률 검토가 필요하다. 플랫폼 장애, 잘못된 과금, 플랫폼 귀책 등까지 무조건 면책하는 문구로 확장하면 안 된다.

### 13.4 등록 심사 체크리스트

- 실행 모델: individual / chunked PTB batch / master pool
- batch당 최대 Vault 수와 결정 근거
- Testnet gas benchmark digest 및 effects
- 평균·P95·최악 예상 가스
- 일일 최대 거래 횟수
- dry-run과 실패 Transaction 차단 정책
- 부분 실패를 위한 batch 분할 정책
- shared object 혼잡과 stale object 재시도 정책
- Agent SUI 최소 잔액과 중단 기준
- Auto-Refill 사용 여부와 일일 한도
- x402 가격 대비 예상 순마진
- 사용자에게 비용 및 위험을 공개하는 방법

PTB 명령·입력 객체의 최대치는 Sui protocol version에 따라 달라질 수 있으므로 `1,024 commands`, `2,048 objects` 같은 숫자를 등록 정책에 영구 하드코딩하지 않는다. 배포 대상 네트워크의 최신 protocol config와 실제 Transaction build/simulation 결과를 기준으로 검사한다.

## 14. 테스트 현황

2026-07-20 재검증 결과:

```text
Move test result: OK
Total tests: 27
Passed: 27
Failed: 0

TypeScript check: PASS
Command: tsc --noEmit
```

주요 검증 범위:

- owner의 Vault 생성, FiatT 입금, 일부·전체 출금
- FiatT와 CryptoT의 분리 관리
- owner가 아닌 주소의 출금·설정 변경 차단
- Agent가 출금할 수 없음
- 등록 Agent 요청 성공
- 미등록·중지·교체된 Agent 요청 실패
- BUY/SELL 0 수량 차단
- BUY/SELL 1회 한도
- BUY/SELL epoch 누적 한도
- epoch 변경 시 누적량 초기화
- BUY는 FiatT만, SELL은 CryptoT만 검사
- FiatT 잔액으로 CryptoT SELL을 충족할 수 없음
- 요청만으로 Vault 자산이 이동하지 않음
- x402 사용료 80:20 분배
- 100% 초과 플랫폼 수수료 차단
- Agent 생성 정보
- follow 비용 전달과 잘못된 비용 차단
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
사용자 지갑 Testnet USDC → Vault FiatT 입금 및 x402 결제
Agent 지갑 Testnet SUI   → request_buy/request_sell 실행 가스
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
→ x402 사용료 결제 및 80:20 분배
→ 서버 결제 영수증 검증
→ 하드코딩 Agent의 request_buy 실행
→ FiatBuyRequested 및 epoch 누적량 확인
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

- Agent는 owner가 아니다.
- Agent는 Vault에서 출금할 수 없다.
- owner는 언제든 Agent를 중지하거나 교체할 수 있다.
- 사용자 일반 입금은 FiatT만 허용한다.
- BUY는 FiatT만 입력으로 사용한다.
- SELL은 CryptoT만 입력으로 사용한다.
- FiatT와 CryptoT 한도 및 epoch 누적량은 분리한다.
- 금액 0 요청을 차단한다.
- 새 epoch 한도는 이미 사용한 누적량보다 작을 수 없다.
- x402 결제 토큰·가격·수령자·Agent·Treasury를 서버가 검증한다.
- 하나의 x402 digest는 API 권한 해제에 한 번만 사용할 수 있다.
- 실제 DEX 거래 결과는 향후 Agent 지갑이 아니라 Vault에 직접 정산해야 한다.

## 17. 확인된 한계와 리스크

높은 우선순위:

1. 실제 DEX 실행과 자산 정산이 없다.
2. 요청 시점에 epoch 사용량이 증가하며 실제 거래 성공과 아직 결합되지 않았다.
3. Agent 객체가 owned여서 공개 follow 흐름에 제약이 있다.
4. `FollowRecord`가 실제 Agent object ID를 저장하지 않는다.
5. replay 저장소가 메모리 기반이다.
6. Agent 실행 키의 KMS·보안 정책이 없다.
7. Unit Economics DB와 실제 gas effects 수집기가 없다.
8. Auto-Refill이 없다.
9. Fee Vault의 bps 범위·overflow 방어가 부족하다.
10. 실제 DEX 슬리피지, deadline, pool allowlist, oracle 정책이 없다.
11. Dynamic Bag 전환 전에는 Vault당 FiatT/CryptoT 한 쌍만 지원한다.

## 18. 다음 개발 순서

1. Agent를 shared object로 전환하고 `AgentAdminCap` 추가
2. `FollowRecord`에 실제 Agent ID 저장
3. Fee Vault의 bps·overflow 보완
4. x402 replay 저장소를 Redis/DB로 교체
5. Agent 실행 라우트, 운영 signer, dry-run, 실패 처리 구현
6. 실행 레코드에 payment digest, trade digest, Vault ID, gas effects 저장
7. Agent별 Unit Economics 집계 및 손익분기 가격 계산
8. Mock DEX로 `execute_buy/execute_sell` 원자적 정산 검증
9. 실제 Testnet DEX 한 개와 pool allowlist 연결
10. Auto-Refill 정책 및 제한된 실행기 구현
11. Dynamic Field/Bag 기반 다중 Crypto 확장
12. Sponsored Transaction 적용 여부 검토
13. Agent 등록 UX에 가스 최적화 경고·필수 동의·심사 체크리스트 반영

## 19. 대회 제출용 핵심 요약

본 프로젝트의 차별점은 AI Agent에게 사용자 자산을 직접 맡기지 않고, 온체인 Vault가 권한·자산 타입·1회 한도·epoch 누적 한도를 강제한다는 점이다. Agent는 BUY와 SELL을 요청할 수 있지만 출금할 수 없고, 사용자는 언제든 Agent를 중지하거나 교체할 수 있다.

x402는 Agent 지식과 실행 능력을 유료 API로 전환한다. 사용료는 온체인에서 제작자와 플랫폼에 즉시 분배되며, 서버는 Transaction Digest와 `PaymentReceiptEvent`를 검증해 결제된 요청만 실행한다.

지속 가능한 수익 모델은 단순히 “Sui 가스가 저렴하다”는 가정이 아니라 다음 조건으로 평가한다.

```text
제작자 실수령 x402 수익
> 실제 Agent 가스비의 USDC 환산액
  + DEX 비용
  + 실패·재시도 비용
  + 서버/RPC/키 관리 비용
```

향후 실제 Transaction effects를 수집해 Agent별 순수익, 성공당 원가, 손익분기 가격과 SUI 잔여 운용 시간을 계산한다. 이 데이터는 Agent 성과뿐 아니라 경제적 지속 가능성을 검증하는 Marketplace 지표가 된다.

Agora는 Agent 등록 시 개별 Transaction 반복 실행의 비용 위험을 고지하고, 개별 Vault 모델에는 chunked PTB batch 또는 그에 준하는 최적화 계획을 요구한다. 제작자가 선택한 실행 구조와 빈도로 발생한 가스비는 제작자의 Unit Economics에 포함하며, 최적화 미준수로 발생한 추가 비용은 원칙적으로 플랫폼 보상 대상이 아니다.

## 20. 참고 자료

- Sui Documentation: https://docs.sui.io/
- Sui TypeScript SDK Transactions: https://sdk.mystenlabs.com/sui/transactions/basics
- Sui Signing, Execution and Gas: https://sdk.mystenlabs.com/sui/transactions/signing-and-execution
- Sui Core API Transaction Effects: https://sdk.mystenlabs.com/sui/clients/core
- Sui Sponsor Best Practices: https://sdk.mystenlabs.com/sponsor/best-practices
- Circle USDC Contract Addresses: https://developers.circle.com/stablecoins/usdc-contract-addresses
