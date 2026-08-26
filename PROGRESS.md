# THE ZONE AGORA — 진행 상황

문서 갱신: 2026-08-26 · 상위 기준 문서: `RFC문서_8월2일.md` (8/2 회의 결과, 이 문서보다 우선한다)

## 지금 상태 한눈에

| | |
| --- | --- |
| Testnet Package | `0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26` |
| UpgradeCap | `0xb4dd36dc038f0a6ba96b7fb0c3f4020d676418225d7a48fa7a86ddcdf7839191` |
| 검증용 Vault | `0x5dc2a80f4a49736dbbf6228839a0f5eb7a86f6e5c65dd7b85b4f8f3cc0f7c4b5` (`UserVault<SUI, DEEP>`) |
| 테스트 | Move 70/70 · x402 37/37 |
| 실행 경로 | `deepbook_executor` 하나 (Mock DEX 제거됨) |
| 거래 수수료 | 10bps, 체결 시 FiatT로 즉시 징수 |

**처음 보는 사람이 읽는 순서**

1. §1~4 — 무엇을 만드는가, 왜 Agent가 2계층인가
2. §7 파일 구조 — 코드 지도. ★ 표시부터 읽으면 된다
3. §7 실행 흐름 — 주문 하나가 통과하는 검사 순서
4. §9 알려진 이슈 · §8 미구현 — 믿으면 안 되는 부분

**다른 파트가 반드시 봐야 할 곳**

- BE: §7 운영 제약, §7 whitelisted Pool DEEP 경고, §7 거래 수수료
- FE: §7 실행 흐름의 `DeepBookOrderExecuted` 필드, §7 거래 수수료의 `min_fiat_output` 의미 변경

작업 범위: `CONTRACT_WORK_SCOPE.md` · 설계 문서: `docs/vault-spec.md`, `docs/execution-flow.md`, `docs/threat-model.md`, `docs/failure-recovery.md`, `docs/decisions/001~003`

7/26 이전 문서(`HANDOFF_PROMPT.md`, 구 `PROGRESS.md`, `20260726변경점.md`, `AGENT_OWNER_GAS_WARNING.md`)는 8/2 회의로 전제가 바뀌어 삭제했다. 필요하면 `git checkout HEAD -- <파일명>`으로 되살린다.

---

## 1. 제품 정의

사용자는 Agent나 Crypto를 고르지 않는다. 회원가입 후 개인 Vault에 USDC를 예치하면 Agora가 검증한 Signal로 자동 운용되며, 자산의 최종 출금 권한은 사용자가 유지한다.

Agora가 푸는 문제는 **"이 Trading Agent의 Signal을 믿을 수 있는가"** 이다. 유료 Trading Agent API는 너무 많고, 백테스트는 재현이 어려우며, 수수료·슬리피지를 반영하면 성과가 유지되는지 확인하기 어렵다. Agora는 그 검증을 대신 수행하는 상위 Agent다.

## 2. Agent 2계층 구조

```text
Providing Agent (공용)                    User Agent (개인)
├─ Trading Agent API를 x402로 호출        ├─ 검증 완료 Signal 수신
├─ Historical Backtest                    ├─ 해당 사용자 Vault 한도·정책 확인
├─ Shadow Trading (상시)                  └─ 조건 만족 시 거래 실행
└─ Trust Score 산출 → 배포
```

검증은 공유하는 것이 효율적이므로 공용 Agent가 일괄 수행하고, 사용자별 epoch·한도·정책 계산은 개인 Agent가 담당한다.

## 3. 두 시계 (Latency 해법)

```text
느린 시계 — 전략/Agent 검증 (거래 경로 밖, 상시)
└─ Backtest + Shadow Trading → Trust Score 누적 갱신

빠른 시계 — 시그널 실행 (거래 경로)
└─ Trust Score 조회 + Vault 한도 확인 + Signal TTL 확인 → 즉시 실행
```

거래 시점에 무거운 검증을 다시 돌리지 않으므로 거래 경로에 Latency가 추가되지 않는다.

- **Shadow Trading**: Testnet은 실제 유동성·호가·슬리피지를 재현하지 못하므로, 실제 자금 없이 mainnet 시장 데이터와 실제 체결가·수수료·슬리피지를 반영해 "이 시그널대로 거래했다면 실제로 수익이었는가"를 계산한다. 개별 시그널 판정이 아니라 Agent Trust Score 갱신이 목적이다.
- **개별 시그널의 신선도**는 TTL로 처리하고, **Agent 신뢰도**는 Shadow 누적 점수로 처리한다.

## 4. 이중 스위치 (리스크 관리)

Trust Score는 완만하게 갱신되므로 급성 사고를 못 막는다. 성격이 다른 두 차단 장치를 둔다.

| 스위치 | 담당 | 역할 | 한계 |
| --- | --- | --- | --- |
| 소프트 — x402 결제 차단 | BE (형권) | Shadow 성과 악화 Agent의 시그널 수신 자체를 끊음 | 미래 시그널만. 이미 실행된 거래는 못 되돌림 |
| **하드 — Vault Kill Switch** | **Contract (진웅)** | 손실이 극단 임계치를 넘으면 온체인에서 즉시 정지 | in-flight 리스크 차단용 |

Vault에는 Trust Score와 무관하게 강제되는 하드 가드레일(최대 손실·거래 한도 등)을 둔다.

**이상 신호 판정 주의**: "다수 시그널과 방향이 다르다"는 사실만으로 자동 제거하지 않는다. 정상적인 역발상 전략을 오탐으로 손절할 수 있다. 방향성 이탈은 후보로만 표시하고 **실제 Shadow 성과 하락과 함께 나타날 때** 제거한다.

## 5. 팀 분담 (마감 2026-08-12)

| 담당 | 범위 | Repo |
| --- | --- | --- |
| 민성 | Providing Agent, FE | `TheZoneAgora/FE` |
| 형권 | Web2 Backend | `TheZoneAgora/BE` |
| 진웅 | Vault 수정, 거래 차단 | `TheZoneAgora/contract` |

완성된 것: 거래용 Vault, web3 계정 문제.

**팀 공통 미해결 3건**
1. AI-Agent 신뢰 문제 해결용 백엔드 서버 — 느린 시계/빠른 시계 구성
2. 각 테스트 시 위험도 계산 방향
3. Agora ↔ Providing Agent 사이 x402 구축

## 6. 자금 원칙

- Agora Agent 서버·Test Lab·시장 데이터·Trading Agent API 비용 → **사용자 구독료**(web2 PayPal 등)에서 충당
- Trading Agent API 이용료 → Agora 운영 예산에서 x402로 지급
- **사용자 Vault는 운영비·API 비용에 사용하지 않는다.** 검증 통과 Signal의 거래 실행에만 사용한다.
- **거래 수수료는 거래 원가이므로 사용자가 부담한다.** 운영비와는 구분한다. Agora는 체결 시점에 `trading_fee`가 고정한 요율만큼 FiatT로 징수하고, DeepBook에 낼 DEEP은 Agora가 선지불한 뒤 이 수수료로 회수한다. 요율·산정 근거는 §7 거래 수수료 참고.
- 거래 수익과 손실은 사용자 Vault에 귀속된다.
- 사용자는 언제든 AgoraAgent를 정지시키고 자산을 회수할 수 있다(§7 긴급 탈출).

---

## 7. Contract 현재 상태

### 파일 구조

읽는 순서: `investment_vault.move`(가드레일 전부가 여기 있다) → `deepbook_executor.move`
(그 사이에 스왑을 끼워 넣는 층) → `trading_fee.move`(수수료 산수) → x402 4종.

```text
sui-contract/
├─ sources/
│  ├─ vault/
│  │  ├─ investment_vault.move      ★ UserVault 본체. 자산 보관·권한·가드레일 전부
│  │  │                               take_*_for_execution / settle_*_execution 이 핵심
│  │  ├─ vault_policy.move           시간·가격편차·bps 계산 헬퍼
│  │  ├─ trading_fee.move            Agora 거래 수수료 산수 (순수 함수, 10bps)
│  │  └─ fee_vault.move              학습용 뼈대 (미사용)
│  ├─ execution/
│  │  ├─ deepbook_executor.move    ★ 유일한 실거래 경로. Vault 원시 함수 사이에
│  │  │                               DeepBook 스왑을 끼워 넣는다
│  │  └─ execution_record.move       stub (buy_side/sell_side 상수만)
│  ├─ marketplace/
│  │  ├─ payment_splitter.move       x402 결제를 Provider와 Treasury에 분배
│  │  └─ signal_provider_registry.move
│  ├─ Dex/
│  │  ├─ dex_registry.move           거래 장소 식별자 (venue_deepbook 하나)
│  │  ├─ Vault_Dex.js                Vault 생성·예치·출금·주문 실행 PTB 빌더
│  │  └─ x402_client.js              Agora signer 기반 x402 호출 (클라이언트측)
│  └─ x402/                          Provider 서버측 (JS)
│     ├─ provider_config.js          환경변수 → 설정, 주소·코인타입·u64 검사
│     ├─ payment_challenge.js        402 challenge 발급·영수증 검증·replay 차단
│     ├─ payment_receipt_reader.js   tx digest → 온체인 영수증 (GraphQL)
│     └─ signal_handler.js           HTTP 층 — 402 발급 / 검증 / 시그널 전달
├─ tests/
│  ├─ execution/
│  │  ├─ vault_harness.move        ★ DEX 없이 Vault 원시 함수를 직접 호출하는 하네스
│  │  ├─ vault_execution_tests.move  원자적 정산·중복 Signal·편차·최소 수령량·위험도 (18)
│  │  ├─ vault_limits_tests.move     권한·상태·한도 (14)
│  │  ├─ emergency_exit_tests.move   긴급 탈출 2경로 (10)
│  │  └─ kill_switch_tests.move      급락 Kill Switch (5)
│  ├─ vault/
│  │  ├─ investment_vault_tests.move 소유권·입출금·생성 파라미터 (8)
│  │  ├─ trading_fee_tests.move      요율 상한·내림·overflow·순액 보장 (10)
│  │  └─ fee_vault_tests.move        (2)
│  └─ marketplace/                   payment_splitter (2) · registry (1)
└─ scripts/
   ├─ demo.sh                        Testnet 라이브 시연 (체결 2종 + 가드레일 4종)
   ├─ agent-executor.mjs           ★ AgoraAgent 실행기 — 시그널을 받아 온체인 체결
   ├─ x402-server.mjs                Provider 서버 (node:http, 의존성 없음)
   └─ x402.test.mjs                  x402 순수 로직 + HTTP 핸들러 (37)
```

★ 표시가 먼저 읽어야 할 파일이다. 안전장치가 전부 `investment_vault`에 모여 있어서,
거래 장소가 바뀌어도 executor만 갈아 끼우면 된다는 것이 이 구조의 요점이다.

### 런타임 3개

파일만 봐서는 안 보이는 부분이다. 이 프로젝트는 서로 다른 세 곳에서 돈다.

```text
Providing Agent (MINT 등, 팀원 담당)      느린 시계 — 시그널 생산
        │  POST /signal  {signalId, side, price, riskScoreBps, timestampMs}
        ▼
scripts/agent-executor.mjs                빠른 시계 — 검증·실행 (Node)
        │  execute_buy / execute_sell     가격 역산·DEEP 분리·거부 해석
        ▼
sources/  (Sui Testnet)                   최종 방어 — 가드레일은 여기서만 강제된다
        │  DeepBookOrderExecuted 이벤트
        ▼
FE (별도 레포)                             체인에서 직접 읽는다. 실행기에 묻지 않는다.
```

Providing Agent는 Sui도 DeepBook도 몰라도 된다. JSON 한 건만 보내면 나머지는
실행기가 흡수한다 — 이게 이 분리의 목적이다.

실행기가 아직 안 하는 것: 시그널 검증(Trust Score), x402 사용료 결제.
둘 다 코드에 TODO로 자리만 있고 `/status`가 `not-implemented`로 알린다.

### UserVault 정책 필드

`UserVault<FiatT, CryptoT>`는 shared object이며 함수 내부 검사로 Owner와 AgoraAgent 역할을 구분한다.

| 그룹 | 필드 |
| --- | --- |
| 권한 | `owner`, `agora_agent_operator`, `agora_agent_status` |
| 자산 | `fiat_balance`, `crypto_balance`, `cost_basis_fiat` |
| 1회·epoch 한도 | `max_trade_amount`, `max_epoch_trade_amount`, `spent_this_epoch`, `max_crypto_sell_amount`, `max_epoch_crypto_sell_amount`, `spent_crypto_this_epoch`, `spending_epoch` |
| 실행 정책 | `allowed_pool`, `max_daily_fiat_volume`, `daily_fiat_volume`, `volume_day_utc`, `max_position_size`, `max_loss_amount`, `realized_loss_amount` |
| 시간·가격 | `trading_start_minute_utc`, `trading_end_minute_utc`, `max_signal_delay_ms`, `max_price_deviation_bps` |
| 위험도 | `max_risk_score_bps` (BUY 전용 상한) |
| Kill Switch | `loss_window_ms`, `max_window_loss_amount`, `window_loss_amount`, `window_started_at_ms` |
| 중복 차단 | `executed_signals: Table<vector<u8>, bool>` |

### 실행 흐름

실행 경로는 `deepbook_executor` 하나이고, 검사는 전부 Vault 원시 함수 안에 있다.
테스트도 같은 원시 함수를 직접 호출하므로(`vault_harness`) 아래 검사가 그대로 적용된다.

```text
execute_buy / execute_sell
→ deadline 확인                                  E_DEADLINE_EXPIRED
→ DEEP 수수료 규칙 (Pool 종류별)                  E_DEEP_FEE_REQUIRED, E_DEEP_FEE_NOT_ACCEPTED
→ Quote 가격 조회 (수수료 모드에 맞춰)             E_EMPTY_QUOTE
→ lot_size·min_size 사전 확인                    E_BELOW_MIN_SIZE
→ take_*_for_execution
   ├─ AgoraAgent 권한                            E_NOT_AGORA_AGENT
   ├─ ACTIVE / REDUCE_ONLY / PAUSED              E_AGORA_AGENT_INACTIVE, E_BUY_DISABLED_IN_REDUCE_ONLY
   ├─ Signal 위험도 (BUY만)                       E_RISK_SCORE_EXCEEDED, E_INVALID_RISK_SCORE
   ├─ Pool allowlist                             E_POOL_NOT_ALLOWED
   ├─ Signal 중복                                E_DUPLICATE_SIGNAL
   ├─ Signal TTL·거래 시간대                      E_SIGNAL_EXPIRED, E_OUTSIDE_TRADING_HOURS
   ├─ Signal가 vs Quote가 편차                    E_PRICE_DEVIATION_EXCEEDED
   ├─ 1회·epoch 한도, 일일 볼륨, 포지션 상한       E_TRADE_LIMIT_EXCEEDED, E_DAILY_VOLUME_EXCEEDED, E_POSITION_LIMIT_EXCEEDED
   └─ 잔액                                       E_INSUFFICIENT_BALANCE
→ (BUY) 거래 수수료를 요청액 기준으로 예약
→ DeepBook swap                                  E_SWAP_NOT_EXECUTED (체결 0건)
→ 실제 체결분에만 수수료 청구, 남은 예약분과 미체결 입력은 같은 Vault로 반환
→ 남은 DEEP은 실행자(AgoraAgent)에게 반환
→ settle_*_execution
   ├─ 최소 수령량 (SELL은 수수료 뗀 순액 기준)     E_MIN_OUTPUT_NOT_MET
   ├─ 누적 실현 손실 한도                         E_MAX_LOSS_EXCEEDED
   ├─ 급락 Kill Switch (창 내 손실 합계)
   └─ 성공 시에만 한도 사용량·cost basis·Signal 기록 갱신
→ DeepBookOrderExecuted 이벤트
   vault_id, user, signal_id, side, requested_input, consumed_input,
   actual_output, deep_consumed, paid_with_deep, fee_charged,
   signal_price_e9, dex_quote_price_e9, pool, transaction_digest,
   risk_score_bps, executed_at_ms
```

핵심: 스왑 결과는 Agent 지갑이 아니라 **같은 Vault로 즉시 정산**되고, 한도 사용량은 **거래 성공 후에만** 증가한다. 하나라도 실패하면 트랜잭션 전체가 롤백되어 잔액·한도·replay 상태가 모두 그대로 남는다.

Agent가 가져가는 것은 **남은 DEEP과 거래 수수료뿐**이고, 체결 결과물은 어느 경로로도
Agent 지갑에 닿지 않는다. 수수료 요율은 모듈 상수라 Agent가 트랜잭션마다 바꿀 수 없다.

### RFC 가드레일 대비 구현 현황

| RFC 요구 가드레일 | 상태 |
| --- | --- |
| 허용 DEX (단일 Pool) | ✅ `allowed_pool` |
| 거래당 최대 금액 | ✅ `max_trade_amount` |
| 일일 최대 거래액 | ✅ `max_daily_fiat_volume` (UTC 기준) |
| 최대 포지션 크기 | ✅ `max_position_size` |
| 최대 손실 한도 | ✅ `max_loss_amount` (누적 실현 손실) |
| 거래 가능 시간 | ✅ `trading_start/end_minute_utc` |
| Signal 최대 지연 | ✅ `max_signal_delay_ms` |
| 가격 편차 확인 | ✅ `max_price_deviation_bps` |
| 중복 주문 방지 | ✅ `executed_signals` Table, 키 = `(network, vault_id, signal_id)` |
| 긴급 중단 | ✅ `revoke_agent` → PAUSED (Owner 권한) |
| 긴급 전량 청산 | ✅ `emergency_liquidate_all` (Owner 전용) |
| 긴급 정지 + 회수 | ✅ `emergency_pause_and_withdraw_fiat` (원자적) |
| Signal 위험도 상한 | ✅ `max_risk_score_bps` (BUY 전용) |
| **급락률 기반 Kill Switch** | ✅ `apply_loss_kill_switch` |
| 허용 자산 목록 | ⚠️ 단일 `FiatT`/`CryptoT` 쌍으로 대체 |

### 위험도 강제 정책

느린 시계(Backtest·Shadow Trading)가 산출한 `risk_score_bps`를 AgoraAgent가 주문에 실어 보내면, 빠른 시계인 executor는 값을 재계산하지 않고 Vault 상한과 비교만 한다. 계산은 오프체인, 강제는 온체인이다.

```text
BUY   risk_score_bps <= vault.max_risk_score_bps  아니면 abort(22)
SELL  상한 미적용. 형식 검사(0~10000)만 수행
공통  risk_score_bps <= 10000  아니면 abort(23)
```

SELL에 상한을 걸지 않는 이유는 위험이 커진 순간 탈출 경로가 막히면 안전장치가 오히려 손실을 키우기 때문이다. 기존 `REDUCE_ONLY` 정책과 같은 방향이다.

상한은 Owner만 `configure_execution_policy`로 바꿀 수 있고, 낮추면 즉시 다음 주문부터 적용된다. 실행 이벤트에 적용된 위험도가 기록되므로 사후 감사가 가능하다.

### Kill Switch (하드 스위치)

`max_loss_amount`는 Vault 수명 전체의 누적 손실을 보므로 짧은 시간의 급락을 잡지 못한다. Kill Switch는 손실의 **속도**를 본다.

```text
매도로 실현 손실이 확정될 때마다
→ now_ms가 창을 벗어났으면 창을 새로 열고 누적을 0으로 초기화
→ window_loss_amount += loss
→ max_window_loss_amount 초과 시 agora_agent_status = PAUSED
→ KillSwitchTriggered 이벤트
```

**발동해도 진행 중인 매도는 abort하지 않는다.** 손실이 커지는 국면에서 포지션 축소를 되돌리면 손실이 오히려 커지기 때문이다. 이번 거래는 체결하고 다음 주문부터 차단한다.

복구는 Owner의 `reactivate_agent`로만 가능하다. AgoraAgent는 스스로 풀 수 없다. PAUSED 상태에서도 Owner 출금은 언제나 가능하다.

### 긴급 탈출 (Owner 전용)

거래 한도는 **AgoraAgent를 묶는 장치이지 Owner를 묶는 장치가 아니다.** 자산의 주인이 자기 자산을 회수하는 상황에 같은 한도를 적용하면 안전장치가 오히려 사용자를 가둔다. 두 경로 모두 `PAUSED` 상태에서도 동작한다.

**1. 전량 청산** — `emergency_liquidate_all`

보유 CryptoT를 시장가로 전부 팔아 FiatT로 바꾼다.

```text
건너뜀  AgoraAgent 권한, ACTIVE/REDUCE_ONLY/PAUSED, 1회·epoch·일일·포지션 한도,
        거래 시간대, Signal TTL, 가격 편차, Signal 중복, 누적 손실 한도, Kill Switch
유지    Owner 권한, allowed_pool, min_fiat_output, deadline
결과    crypto → 0, cost_basis → 0, 실현 손실 기록, 상태 → PAUSED
```

- **누적 손실 한도로 abort하지 않는다.** 긴급 청산은 이미 손실이 큰 국면에서 실행되므로, 손실 한도로 청산을 막으면 사용자가 포지션에 갇힌다. 손실은 기록만 한다.
- **`min_fiat_output`과 `deadline`은 유지한다.** 이 둘이 없으면 긴급 버튼 자체가 샌드위치 공격 경로가 된다. FE는 실제 시세를 반영한 값을 넣어야 하며 0을 넣으면 안 된다.
- **`allowed_pool`은 유지한다.** Owner가 직접 설정한 Pool이므로 유지 비용이 없고, 탈취된 프런트엔드가 악성 Pool로 자금을 흘리는 것을 막는다.
- **청산 후 자동 PAUSED.** Owner가 전량 탈출을 택한 직후 AgoraAgent가 재매수하면 탈출의 의미가 없다. 재개는 Owner의 `reactivate_agent`로만 한다.

**2. 정지 + USDC 회수** — `emergency_pause_and_withdraw_fiat`

AgoraAgent를 정지시키고 FiatT 잔액 전부를 Owner 지갑으로 보낸다. **정지와 회수를 한 트랜잭션으로 묶는다** — 따로 실행하면 그 사이에 AgoraAgent가 마지막 주문을 끼워 넣을 수 있다.

CryptoT 포지션은 건드리지 않는다. 시장가 매도가 필요하면 1번을 먼저 실행하고, 코인 그대로 받으려면 `withdraw_crypto_amount`를 쓴다.

실제 사용 순서는 **전량 청산 → USDC 회수**다.

### 거래 수수료

체결 시점에 Vault에서 FiatT(USDC)로 즉시 징수한다. 미수금이 없고 증빙이 트랜잭션 하나에 닫힌다.

| | 부과 대상 | 시점 |
| --- | --- | --- |
| BUY | 투입 fiat | 스왑 전 예약 → 실제 체결분만 청구, 잔여는 Vault 반환 |
| SELL | 매도 대금 | 스왑 후 총액에서 차감 → 순액만 Vault 입금 |

- **요율 10bps(0.1%)** — 원가는 DeepBook v3 taker 5bps(메이저 페어, Agora가 DEEP으로 선지불)이고 그 위에 5bps 마진을 얹었다. 아래 표 기준 Uniswap v3 메이저(5bps)와 일반 알트(30bps) 사이다.
- **요율과 상한은 모듈 상수다.** 호출 인자로 받으면 AgoraAgent가 매번 바꿔 넣을 수 있고, Vault 필드로 두면 Owner가 0으로 만들 수 있다. 변경하려면 패키지 업그레이드가 필요하다. 하드 상한 `MAX_TRADING_FEE_BPS = 100`(1%)을 둬서 상수를 잘못 고쳐도 과금이 튀지 않는다.
- **수령처는 실행자(AgoraAgent 운영 지갑)** — DEEP 잔여분과 같다. 사용자가 보호받아야 하는 것은 "얼마를 떼는가"이고 그건 상수가 고정한다. "어디로 가는가"는 Agora 내부 문제다.
- **부분 체결**: BUY는 요청액 기준으로 예약해 두고 실제 체결분에만 요율을 적용한다. 그러지 않으면 부분 체결일수록 실효 요율이 올라간다.
- **먼지 거래**: 내림이라 소액에서는 0이 나온다. 올림하면 실효 요율이 폭증하므로 의도한 동작이다.

⚠️ **`min_fiat_output` 의미가 바뀐다 (BE·FE 반영 필요).** 이제 "유저가 손에 쥐는 **순액** 최소치"다. 수수료는 DeepBook이 뱉은 총액에서 떼므로, executor가 `gross_min_output()`으로 요율만큼 올려 잡아 DeepBook에 넘긴다. 호출자는 지금까지처럼 받고 싶은 금액을 그대로 넣으면 된다.

#### 참고 — 주요 DEX 수수료 (요율 산정 벤치마크)

Shadow Trading이 실제 체결가·수수료를 반영할 때도 쓴다(§4).

| DEX | 페어 / 유형 | Maker | Taker / AMM |
| --- | --- | --- | --- |
| **DeepBook v3** (Sui) | 메이저 (SUI/USDC) | 0.005% | **0.05%** (DEEP 지불 시 할인) |
| | 스테이블 (USDC/USDT) | 0.000% | 0.02% |
| Uniswap v3 (Ethereum/L2) | 스테이블 | – | 0.01% |
| | 메이저 (ETH/USDC) | – | 0.05% |
| | 일반 알트코인 | – | 0.30% |
| | 고변동성 / 밈코인 | – | 1.00% |
| PancakeSwap v3 (BNB/L2) | 스테이블 | – | 0.01% |
| | 메이저 | – | 0.05% |
| | 일반 알트코인 | – | 0.25% |
| | 고변동성 | – | 1.00% |
| Raydium (Solana) | Standard AMM | – | 0.25% |
| | CLMM (집중유동성) | – | 0.01 / 0.05 / 0.25 / 1.00% |
| Hyperliquid (Appchain) | 선물·현물 기본 | 0.000% | 0.025% |
| dYdX v4 (Cosmos) | 선물 기본 티어 | 0.020% | 0.050% |
| Jupiter (Solana) | 애그리게이터 | 0% (자체 수수료 없음, 경유 DEX 수수료만 차감) | |

### DeepBook v3 연동

MVP 실거래 대상은 DeepBook v3다. `Move.toml`에서 리비전을 고정했다.

```toml
deepbook = { git = "...deepbookv3.git", subdir = "packages/deepbook", rev = "3ded560..." }
```

타입 대응과 호출 함수:

| 방향 | DeepBook 함수 | 타입 |
| --- | --- | --- |
| BUY (fiat→crypto) | `swap_exact_quote_for_base` | FiatT = QuoteAsset |
| SELL (crypto→fiat) | `swap_exact_base_for_quote` | CryptoT = BaseAsset |

- **가격 조회**: 중간가가 아니라 `get_base_quantity_out` / `get_quote_quantity_out`으로 이번 수량의 실제 체결 예상량을 구해 유효 가격을 계산한다. Order Book에서는 수량이 커질수록 체결가가 나빠지므로 이 쪽이 정확하고, 그 값이 그대로 가격 편차 검사에 쓰인다.
- **DEEP 수수료**: Agora 운영 예산이 부담한다. AgoraAgent 지갑의 `Coin<DEEP>`을 인자로 넣고 남은 DEEP은 실행자에게 반환한다. Vault 자산은 수수료로 쓰지 않는다(§6 자금 원칙). DeepBook은 `deep_in.value() > 0`으로 수수료 모드를 정하므로, 조회 함수도 같은 기준으로 `get_*_quantity_out` / `get_*_quantity_out_input_fee`를 갈라 써야 한다. 어긋나면 추정 체결량이 낙관적으로 나와 가격 편차 가드가 헐거워진다.
- **부분 체결**: Order Book은 유동성이 모자라면 입력을 다 쓰지 못한다. 남은 입력은 `return_fiat_remainder` / `return_crypto_remainder`로 반드시 같은 Vault에 돌려주고, 한도·원가 누적에는 **실제 소비량**만 반영한다.
- **min_size 미달 no-op**: DeepBook은 주문 수량을 `lot_size`로 내림한 뒤 `min_size`에 미달하면 **abort하지 않고 입력을 그대로 돌려준다**(`pool.move:443-445`). 이대로 정산하면 체결 0건인데 `signal_id`가 replay 테이블에 박혀 해당 Signal이 영구 소진된다. 사전 `E_BELOW_MIN_SIZE` 검사와 사후 `E_SWAP_NOT_EXECUTED` 검사로 전체를 abort시킨다. SELL의 사전 검사는 필요 조건일 뿐이고(DEEP 미사용 시 수수료만큼 수량이 줄어든 뒤 min_size와 비교됨) 최종 판정은 사후 검사가 한다.

#### 운영 제약 (BE 반영 필요)

1. **거래에는 DEEP이 필수다.** whitelisted Pool이 아니면 `deep_fee`가 0인 주문은 `execute_buy`/`execute_sell`이 `E_DEEP_FEE_REQUIRED(5)`로 차단한다. DeepBook 자체는 막지 않고 input-token 수수료 모드로 넘어가는데, 그 모드의 수수료는 **Vault가 넣은 입력 코인에서** 나가고 요율도 `taker_fee × 1.25`라 더 비싸다. 사용자 자금이 수수료를 내는 셈이라 RFC §6에 어긋나므로 우리가 끊는다. (`SUI_DBUSDC`는 DeepBook 내부에서도 code 8로 막혀 있었고, `DEEP_SUI`는 통과했다 — Pool별로 달라 진단이 어렵던 부분도 함께 해소된다.)
2. **거래 1건당 최소 1 SUI**(`min_size`)다. 현재가 기준 **약 0.69 DBUSDC 이상**이어야 주문이 성립한다. 그보다 작은 Signal은 BE가 미리 걸러야 한다.
3. **DEEP 소모량은 거래당 약 0.02 DEEP**(측정값)이다. 가스비보다 싸지만 **DEEP이 떨어지면 모든 거래가 멈춘다.** 잔고 모니터링과 보충 절차가 필요하다.

임계값은 진웅이 정한 초기값이며 튜닝 대상이다. 오프체인 위험도 산출식(신호 불일치도·변동성·신선도·집중도 가중합)은 BE와 합의 후 확정한다.

### 배포 이력과 온체인 검증

실행 경로는 Move 테스트로 덮을 수 없어(§ 테스트) 아래 기록이 사실상의 검증 근거다.

#### Testnet E2E 결과 (2026-08-15)

`SUI_DBUSDC` Pool에서 BUY → SELL 왕복을 실제로 체결했다.

| | fiat (DBUSDC) | crypto (SUI) |
| --- | --- | --- |
| 시작 | 1,360,000 | 0 |
| BUY | −960,400 | +1,400,000,000 |
| SELL | +952,000 | −1,400,000,000 |
| 종료 | 1,351,600 | 0 |

(위 표는 8/15 시점 값이다. 이후 추가 거래가 있어 8/26 실측 잔액은 1,334,800이다.)

체결가는 매수 0.686 / 매도 0.680으로 호가창 스프레드 그대로다. 실현 손실 8,400(0.62%)이 `realized_loss_amount`와 `window_loss_amount`에 기록되고, 포지션이 비면서 `cost_basis_fiat`이 0으로 초기화됐다. 손실이 한도 안이라 Vault는 `ACTIVE`를 유지했다.

- BUY 요청 1,000,000 중 960,400만 체결됐고 **미사용분 39,600이 실행자가 아니라 같은 Vault로 반환**됐다.
- 같은 `signal_id` 재사용 → `E_DUPLICATE_SIGNAL`(17), 6.7분 지난 signal → `E_SIGNAL_EXPIRED`(3)로 각각 차단됐다.
- `min_out` 미달 시 DeepBook code 11로 전액 롤백됐다.
- min_size 미달 no-op은 `DEEP_SUI` Pool에서 재현했다(0.2 SUI로 매수 시도 → abort 없이 가스만 소모, 체결 0건).

배포 자산:

```text
Package  0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26  (2026-08-26 재배포)
Vault    (재생성 필요 — 아래 마이그레이션 참고)
Pool     0x1c19362ca52b8ffd7a33cee805a67d40f31e6ba303753fd3a4cfdfacea7163a5  SUI_DBUSDC
DBUSDC   0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDC::DBUSDC
DEEP     0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP
DeepBook 0xfb28c4cbc6865bd1c897d26aecbe1f8792d1509a20ffec692c800660cbec6982  (testnet v20)
```

#### 2026-08-26 재배포 — 업그레이드가 불가능한 이유

수수료·이벤트 변경 때문에 **업그레이드가 아니라 신규 publish**를 했다. `DeepBookOrderExecuted`에 필드를 추가했는데 Sui의 compatible 정책은 기존 `public struct` 레이아웃 변경을 허용하지 않는다.

```text
구 Package   0x0f5a55d4768a22382295652b415c0df973db45e4ac1d65c8ceadc3a331c68bfa
구 Vault     0x4161c4f46e35990151856cd5c0b7fa14467985842afe28857108f5d35758b664  (DBUSDC 1,334,800 보유)
신 Package   0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26
신 UpgradeCap 0xb4dd36dc038f0a6ba96b7fb0c3f4020d676418225d7a48fa7a86ddcdf7839191
publish tx   7uY4NZSRGXJQ5XqbgitAoynynMfBku92WV6Ciiz9qhET
```

구 Vault는 신 Package 함수로 다룰 수 없다(타입이 구 Package에 묶여 있다). **다만 구 Package는 체인에 그대로 남아 있어 자금은 회수된다.**

구 Vault는 회수하지 못했다. owner가 `0x5d1815281a375a6d954afd88641a59a4e8b7e3dd8b19cbe51878ef61e563bab7`인데
현재 작업 기기 keystore에는 `0x141a93d0…` 하나뿐이라 `withdraw_all_assets`가 `E_NOT_OWNER`로 막힌다.
DBUSDC `TreasuryCap`(`0x13641879…`)도 제3의 주소(`0x754a4397…`)가 보유해 민팅도 불가능하다.
**자금은 안전하다** — 구 Package가 체인에 남아 있어 해당 키를 가진 사람이 언제든 회수할 수 있다.

그래서 재검증은 **자급 가능한 페어(SUI/DEEP)** 로 진행했다. SUI는 faucet, DEEP은 DeepBook에
직접 스왑해 조달했다(우리 컨트랙트 미경유).

#### SUI/DEEP 재검증 결과 (2026-08-26)

```text
Vault  0x5dc2a80f4a49736dbbf6228839a0f5eb7a86f6e5c65dd7b85b4f8f3cc0f7c4b5  UserVault<SUI, DEEP>
Pool   0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f  DEEP_SUI (whitelisted)
BUY    mte3wrsxZNCo1NhCHqu8HfmnQxeszCLgSjn2FsCNhRA
SELL   ZoogHX1Lu7u3yzLj5DQ5QsA8HAdPPPMfBW91ESdragw
```

**BUY** — 요청 0.4 SUI, 부분 체결(lot_size 반올림):

| 항목 | 값 | 확인 |
| --- | --- | --- |
| `consumed_input` | 384,834,450 | 체결분 384,450,000 + 수수료 384,450 |
| `fee_charged` | 384,450 | 체결분의 정확히 10bps |
| `actual_output` | 15,000,000 (15 DEEP) | |
| Vault fiat 잔액 | 415,165,550 | 계산과 1 MIST도 안 틀림 |

예약분 400,000 중 384,450만 청구하고 15,550을 미체결분과 함께 반환했다.
**부분 체결 시 예약분 전액을 청구했다면 실효 요율이 10.4bps로 올랐을 자리다.**

**SELL** — 요청 12 DEEP, 11 DEEP 체결:

| 항목 | 값 | 확인 |
| --- | --- | --- |
| `actual_output` | 298,021,680 | 총액 298,320,000 − 수수료 298,320 (순액) |
| `fee_charged` | 298,320 | 총액의 정확히 10bps |
| `paid_with_deep` | true | DEEP 수수료 모드 분기 |
| cost basis 잔액 | 102,622,520 | 비례 배분(11/15) 결과와 일치 |

`min_fiat_output`을 순액 기준으로 다루는 `gross_min_output()` 경로가 실제로 통과했다.

#### ⚠️ Whitelisted Pool에 DEEP을 넣으면 전액 잃는다 — BE 필수 반영

`DEEP_SUI`처럼 whitelisted인 Pool에 `deep_fee`를 넣으면 **투입량 전체가 소모된다.**
0.2 / 1.0 / 5.0 DEEP을 각각 넣어보면 그대로 0.2 / 1.0 / 5.0이 사라진다(실거래로도 확인: 13→12 DEEP).
수수료가 0인 Pool이라 원래 DEEP이 필요 없는데, 넣으면 돌려받지 못한다.

- **whitelisted Pool에는 반드시 잔액 0인 `Coin<DEEP>`을 넣어야 한다.**
- 비-whitelisted Pool(`SUI_DBUSDC`)에서는 실제 수수료분만 소모된다(§7 측정값 거래당 ~0.02 DEEP).
- AgoraAgent가 지갑의 DEEP 코인을 통째로 넘기는 구현이면 **첫 거래에 전 잔고가 날아간다.**
  거래마다 필요한 만큼만 split해서 넘겨야 한다.

**적용 완료.** `assert_deep_fee_not_wasted`가 whitelisted Pool에 DEEP을 넣는 것 자체를
`E_DEEP_FEE_NOT_ACCEPTED(6)`으로 끊는다. 이제 규칙은 **whitelisted면 반드시 0, 아니면 반드시 0 초과**다.

`emergency_liquidate_all`에도 이 검사만 건다. 잔액 0인 `Coin<DEEP>`은 언제든 만들 수 있어
탈출을 막지 않으면서 실수로 인한 DEEP 전액 손실만 걸러낸다. "DEEP 필수" 쪽은 걸지 않는다 —
그걸 걸면 DEEP 없는 Owner가 자기 자산에 갇힌다.

testnet 실측 (Vault `0x5dc2a80f…`):

| 케이스 | 결과 |
| --- | --- |
| whitelisted Pool + DEEP 1개 | `abort assert_deep_fee_not_wasted code 6` ✔ 차단 |
| whitelisted Pool + DEEP 0 | 정상 체결 (`CSgTJi4d7Rqau3xnxDGCfF9QiPR23HBdcEcGuyU18p4W`) |

정상 체결 건: `consumed_input` 282,211,930 / `fee_charged` 281,930 (체결분의 정확히 10bps) /
`deep_consumed` 0 / `paid_with_deep` false.

#### 구 Vault 회수 확인

`0x4ebeab17…`(직전 패키지 Vault, owner가 우리)는 **구 패키지 함수로 정상 회수됐다**
(0.328 SUI + 19 DEEP). 패키지를 새로 배포해도 이전 패키지가 체인에 남아 있어
자금이 묶이지 않는다는 것을 실제로 확인한 셈이다.

#### 미검증 항목

`E_DEEP_FEE_REQUIRED(5)` 자체는 아직 실측하지 못했다. 이 가드는 비-whitelisted Pool에서만
발동하는데, 유일한 비-whitelisted 대상인 `SUI_DBUSDC`는 DBUSDC를 구할 수 없어 접근 불가다.
whitelisted 예외 분기(0 DEEP 통과)는 위 BUY로 확인됐다.


### 테스트

```bash
sui move test
# Total tests: 70; passed: 70; failed: 0
```

| 모듈 | 개수 | 범위 |
| --- | --- | --- |
| `vault_execution_tests` | 18 | 원자적 정산, 중복 Signal, 편차, 최소 수령량, 위험도 8건 |
| `vault_limits_tests` | 14 | 권한·상태·한도를 실행 경로에서 검증 |
| `investment_vault_tests` | 8 | 소유권, 입출금, 생성 파라미터 검증 |
| `kill_switch_tests` | 5 | 발동, 다음 거래 차단, 미발동, 창 리셋, Owner 복구 |
| `emergency_exit_tests` | 10 | 전량 청산, PAUSED 중 동작, 한도 무시, 권한, 최소 수령량, 정지+회수 |
| `trading_fee_tests` | 10 | 요율 상한, 내림, u64 overflow, 예약분 충분성, 순액 보장 |
| `fee_vault_tests` | 2 | |
| `payment_splitter_tests` | 2 | |
| `signal_provider_registry_tests` | 1 | |

x402 서버측 로직은 별도 테스트다. 네트워크를 타지 않는 순수 로직만 검사하고, 체인 조회는 가짜 reader를 주입한다.

```bash
npm run test:x402
# tests 37; pass 37; fail 0
```

`signal_handler`는 네트워크 없이 검사한다. 체인 조회(`fetchReceipt`)와 시그널 생성
(`produceSignal`)을 주입받는 구조라, 402 발급 → 결제 → 검증 → 전달 전 구간과
실패 경로(조회 실패 502, 검증 실패 402, 결제 후 생성 실패 500)를 모두 재현할 수 있다.

**Mock DEX는 제거했다 (2026-08-26).** 예전에는 `mock_dex`(가짜 Pool)와 `order_executor`(그것을 쓰는 실행 경로)를 두고 가드레일 테스트를 걸었다. 그런데 실행 경로가 둘이면 갈라진다 — 실제로 거래 수수료를 DeepBook 경로에만 넣고 mock에는 빠뜨린 일이 있었다. 이제 실행 경로는 `deepbook_executor` 하나뿐이다.

가드레일은 전부 `investment_vault`의 `take_*_for_execution` / `settle_*_execution` 안에 있고 이들은 `public(package)`이므로, 테스트는 DEX 없이 이 원시 함수를 직접 호출한다(`tests/execution/vault_harness.move`). 체결량 계산은 구 `mock_dex`의 고정 가격 식을 그대로 옮겨 기존 기대값을 유지했다. **47건이 그대로 살아 있다.**

**테스트 공백**: DeepBook 고유 부분(스왑 호출, 부분 체결 잔여분 반환, DEEP 수수료 처리, 거래 수수료 차감)은 Move 테스트로 못 덮는다. Pool 픽스처(Registry, Pool 생성, 호가 배치) 구성 비용이 커서다. 그래서 **돈이 걸린 산수만 `trading_fee.move`로 떼어 내 유닛 테스트로 전부 검증한다.** 나머지 통합 부분은 Testnet E2E 수동 검증에 의존하며, 이는 회귀 테스트가 아니다.

---

## 8. 미구현

1. Pool allowlist 다중화 및 라우팅 (현재 단일 Pool)
2. 오프체인 위험도 산출식 확정 (BE 담당, Contract는 상한 강제만)
3. `execution_record.move` stub 구현
4. `fee_vault.move` 실사용 전환 — 성과 수수료용. 거래 수수료는 `trading_fee`로 별도 처리됨
5. Providing Agent 서버 — Backtest, Shadow Trading, Trust Score 산출
   (x402 핸들러의 `produceSignal`, 실행기의 검증 단계가 모두 자리표시자다)
6. x402 challenge·digest·전달 기록 저장소 Redis/DB 전환 (현재 프로세스 메모리)
7. 실행 레코드 DB — signal ID, payment digest, trade digest, Vault ID, gas effects
8. 운영 signer·KMS
9. AgoraAgent 지갑 DEEP 잔고 모니터링·보충 (없으면 전 거래 중단)
10. Dynamic Field/Bag 기반 다중 Crypto 확장 (`investment_vault.move`에 전환 지점 주석 있음)

## 9. 알려진 이슈

**DeepBook 경로에 자동 회귀 테스트가 없다.**
Testnet E2E로 1회 검증했지만(§7) 수동 절차다. 코드를 고쳐도 Move 테스트가 DeepBook 경로를 잡아주지 않는다.

**DEEP 수수료 조달 절차가 정해지지 않았다.**
컨트랙트는 `Coin<DEEP>`을 인자로 받기만 한다. AgoraAgent 지갑에 DEEP을 어떻게 충전하고 잔고 부족을 어떻게 감지할지는 실행 서버(BE) 몫이다. testnet에는 DEEP faucet이 없어 `DEEP_SUI` Pool에서 SUI를 팔아 조달했다.

**x402 저장소가 프로세스 메모리다.**
`createChallengeStore`와 `createPaymentDigestStore` 모두 Map 하나다. 서버를 재시작하면 발급 기록이 날아가 결제한 사용자가 신호를 못 받고, 여러 대로 늘리면 같은 결제 digest가 서버마다 한 번씩 통과한다.

**Move.lock이 format v4다.**
sui CLI 1.77.1이 재생성했다. 구버전 CLI로는 읽을 수 없으므로 Move 패키지를 빌드하는 팀원은 1.77.1 이상이 필요하다.

**공용 fullnode의 JSON-RPC가 폐기됐다.**
`SuiClient`로는 testnet 조회가 되지 않는다. x402 검증은 GraphQL(`https://graphql.testnet.sui.io/graphql`)을 쓴다. `Vault_Dex.js`는 트랜잭션을 만들기만 하고 `SuiClient`를 만들지 않아 영향이 없다.

**실행 시각을 Clock에 의존한다.**
Kill Switch 창과 Signal TTL 모두 `Clock`의 `timestamp_ms`를 쓴다. Validator 시계 오차 범위 안에서만 정확하다.

**Mock DEX는 신뢰 경계가 아니다.**
실자산 전환 전 Vault 보관 primitive, 패키지 업그레이드 권한, DEX Adapter, 가격/오라클 가정, 산술, replay 저장소, sponsored transaction, signer/KMS, 정산 서비스에 대한 감사가 필요하다.

## 10. 다음 작업 순서 (Contract)

2026-08-05에 완료한 항목:

- ~~위험도를 실행 경로에 연결~~ (A안: `agora_invest` 폐기)
- ~~급락률 기반 Kill Switch~~
- ~~`request_*` 고아 코드 제거 및 한도 테스트 이관~~
- ~~DeepBook v3 연동~~

2026-08-15에 완료한 항목:

- ~~DeepBook no-op·수수료 모드 버그 수정~~
- ~~Testnet publish~~
- ~~DeepBook Testnet E2E~~ — Pool 확정 → `configure_execution_policy` → BUY → SELL (§7 결과)
- ~~x402 Provider 서버측 결제 검증~~ — challenge 발급, 영수증 검증, replay 차단, GraphQL 조회

2026-08-26에 완료한 항목:

- ~~`deep_fee` 0 차단~~ — `E_DEEP_FEE_REQUIRED(5)`, whitelisted Pool만 예외 (§7 운영 제약 1)
- ~~x402 HTTP 핸들러 연결~~ — `signal_handler.js` + `scripts/x402-server.mjs`
- ~~challenge에 `treasury`·`platformFeeBps` 추가~~ — 없으면 클라이언트가 `pay_signal_provider_usage_fee`를 호출할 수 없었다
- ~~영수증의 Treasury 주소·수수료 몫 검증~~ — payer가 수수료를 가로채는 경로를 막는다
- ~~`deep_consumed`·`paid_with_deep` 이벤트 기록~~ — 거래당 수수료 원가를 온체인에서 집계할 수 있게 됨
- ~~Agora 거래 수수료 징수~~ — 체결 시 10bps FiatT 즉시 차감 (§7 거래 수수료)
- ~~Mock DEX 제거~~ — `mock_dex`·`order_executor` 삭제, 테스트 47건을 Vault 원시 함수 직접 호출로 이관
- ~~SUI/DEEP Testnet 재검증~~ — BUY/SELL 수수료 차감, 부분 체결 환급, 새 이벤트 필드 (§7)
- ~~whitelisted Pool DEEP 전액 손실 차단~~ — `E_DEEP_FEE_NOT_ACCEPTED(6)`, 실측 확인
- ~~AgoraAgent 최소 실행기~~ — 시그널 수신 → 온체인 체결. MINT 형태 시그널로 실거래 확인

남은 순서:

1. **BE와 인터페이스 동결** — `signal_id` 생성 규칙, `risk_score_bps` 산출식, DEEP 조달·모니터링, 최소 주문 크기 필터, `configure_execution_policy` 호출 주체
2. **FE와 인터페이스 동결** — `DeepBookOrderExecuted` 이벤트 필드, Vault 조회 스키마
3. Providing Agent 본체를 `produceSignal`에 연결 (지금은 자리표시자)
4. 3파트 통합 리허설

## 11. 검증

```bash
cd sui-contract
sui move test          # 70/70 PASS

node --check sources/Dex/Vault_Dex.js
node --check sources/Dex/x402_client.js

npm install
npm run test:x402      # 37/37 PASS

# Provider 서버 기동 (환경변수는 .env.example 참고)
node scripts/x402-server.mjs
curl -X POST localhost:8402/signal   # -> 402 + challenge
```

`build/`는 빌드 산출물이므로 직접 수정하지 않는다.

## 12. 보안 불변식

- Signal Provider는 Vault 권한이 없다.
- AgoraAgent는 Vault owner가 아니며 사용자 Wallet으로 출금할 수 없다.
- Owner만 Vault 자산을 출금할 수 있다.
- 거래 결과 수령자는 반드시 동일 Vault다.
- DEX 실행에는 Pool allowlist, 최소 수령량, deadline이 필요하다.
- x402 결제 payer는 설정된 AgoraAgent 주소여야 한다.
- 같은 Signal ID는 Vault당 한 번만 실행된다.
- 긴급 중단 최종 권한은 Vault owner에게 있다. 향후 플랫폼 guardian이 생기더라도 출금 권한이나 사용자 Vault 재활성화 권한을 가져서는 안 된다.
- 결과가 불명확한 주문은 자동 재제출하지 않는다. 트랜잭션 digest와 온체인 `signal_executed`를 먼저 조회한다.
