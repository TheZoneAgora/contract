# Sui Contract 테스트 구조

최종 갱신: 2026-07-26

## 실행

```bash
cd sui-contract
sui move test
```

현재 결과:

```text
30 passed
0 failed
```

## 테스트 모듈

### `investment_vault_tests.move`

- Vault 생성·추가 입금·일부/전체 출금
- Owner가 아닌 주소의 출금·설정 변경 차단
- AgoraAgent 외 주소의 BUY/SELL 차단
- BUY/SELL 자산 역할 분리
- 1회 및 epoch 누적 한도
- epoch 변경 시 누적량 초기화
- Agent 주소 교체·중지·재활성화
- REDUCE_ONLY BUY 차단·SELL 허용

기존 테스트 함수 일부에는 공개 함수 호환 이름 때문에 `agent` 표현이 남아 있지만 실행 권한의 의미는 AgoraAgent다.

### `agora_invest_tests.move`

- 신호 digest와 위험 점수를 포함한 BUY 요청
- 기존 Vault 권한·한도 검사 재사용
- `risk_score_bps > 10_000` 차단

### `signal_provider_registry_tests.move`

- Follow fee 없이 Signal Provider 생성
- x402 결제 수령 주소
- Provider 활성 상태

### `payment_splitter_tests.move`

- AgoraAgent의 x402 신호 사용료 분배
- Provider 80%, Treasury 20% 예시
- 플랫폼 수수료 100% 초과 차단

### `fee_vault_tests.move`

- FeeVault 생성 및 수령 주소
- 성과 수수료 bps 계산

## 다음 테스트

1. 빈 `signal_digest` 차단
2. AgoraInvest SELL과 REDUCE_ONLY 조합
3. Mock DEX BUY/SELL 원자적 정산
4. `min_amount_out`, deadline, Pool allowlist
5. 실제 거래 실패 시 epoch 사용량 롤백
6. Testnet USDC/SUI E2E
