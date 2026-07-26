# Sui Contract 파일 구조

최종 갱신: 2026-07-26

```text
sui-contract/
├─ Move.toml
├─ .env.example
├─ sources/
│  ├─ vault/
│  │  ├─ investment_vault.move
│  │  └─ fee_vault.move
│  ├─ AgoraAgent/
│  │  └─ AgoraInvest.move
│  ├─ marketplace/
│  │  ├─ signal_provider_registry.move
│  │  └─ payment_splitter.move
│  └─ Dex/
│     ├─ Vault_Dex.js
│     └─ x402_client.js
└─ tests/
   ├─ vault/
   │  ├─ investment_vault_tests.move
   │  └─ fee_vault_tests.move
   ├─ AgoraAgent/
   │  └─ agora_invest_tests.move
   └─ marketplace/
      ├─ signal_provider_registry_tests.move
      └─ payment_splitter_tests.move
```

## 파일 역할

### `investment_vault.move`

- 사용자 USDC 및 투자 결과 자산 보관
- Owner 입금·출금
- AgoraAgent 주소 인증
- ACTIVE/REDUCE_ONLY/PAUSED
- BUY/SELL 1회·epoch 한도

### `AgoraInvest.move`

- AgoraAgent의 신호 기반 BUY/SELL 요청
- `signal_digest` 기록
- `risk_score_bps` 검증·기록
- Vault 검사 재사용

### `signal_provider_registry.move`

- 외부 Signal Provider 등록 정보
- x402 수령 주소와 활성 상태
- 사용자 Follow 및 Vault 권한 없음

### `payment_splitter.move`

- AgoraAgent가 지불하는 x402 신호 사용료 분배
- Provider/Treasury 분배
- `SignalPaymentReceiptEvent`

### `Vault_Dex.js`

- 사용자 Vault 생성·USDC 예치·출금 PTB 생성
- 자산 타입과 AgoraAgent 주소는 배포 환경에서 읽음
- 사용자의 Crypto·Agent 선택 입력 없음

### `x402_client.js`

- AgoraAgent signer 기반 Signal Provider x402 요청
- 사용자 연결 지갑을 결제에 사용하지 않음

## 제거된 파일

- `marketplace/agent_registry.move`
- `marketplace/follow.move`
- `tests/marketplace/agent_registry_tests.move`
- `tests/marketplace/follow_tests.move`

## 생성 파일 주의

`build/`는 `sui move test` 또는 build 과정에서 만들어지는 산출물이다. 직접 수정하지 않는다.
