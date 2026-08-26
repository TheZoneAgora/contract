#!/usr/bin/env bash
# THE ZONE AGORA — Vault × DeepBook 라이브 시연
#
#   ./scripts/demo.sh state   Vault 상태 출력
#   ./scripts/demo.sh buy     DeepBook BUY 체결 (fiat → crypto)
#   ./scripts/demo.sh sell    DeepBook SELL 체결 (crypto → fiat)
#   ./scripts/demo.sh dup     직전 signal_id 재사용 → E_DUPLICATE_SIGNAL(17)로 차단
#   ./scripts/demo.sh stale   10분 지난 signal → E_SIGNAL_EXPIRED(3)로 차단
#   ./scripts/demo.sh over    한도 초과 금액 → E_TRADE_LIMIT_EXCEEDED로 차단
#   ./scripts/demo.sh nodeep  DEEP 0으로 매수 → E_DEEP_FEE_REQUIRED(5)로 차단
#
# 차단 시연은 --dry-run이라 가스도 쓰지 않는다. 온체인 판정은 실행과 동일하다.
set -uo pipefail

PKG=0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26
VAULT=0x5dc2a80f4a49736dbbf6228839a0f5eb7a86f6e5c65dd7b85b4f8f3cc0f7c4b5
POOL=0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f  # DEEP_SUI (whitelisted)
FIAT=0x2::sui::SUI
CRYPTO=0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP
DEEPT=0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP
TYPES="<$FIAT,$CRYPTO>"

BUY_FIAT=${BUY_FIAT:-400000000}          # 0.4 SUI (min_size 10 DEEP ≈ 0.28 SUI 위)
BUY_MIN_OUT=${BUY_MIN_OUT:-0}            # 부분 체결 허용
SELL_MIN_OUT=${SELL_MIN_OUT:-200000000}  # 최소 0.2 SUI 수령 (순액 기준)
# 이 Pool은 매수·매도 스프레드가 ~9%라 방향별로 가격이 다르다. 편차 가드는 500bps다.
PRICE_E9=${PRICE_E9:-26666666666}        # 매수 호가. SELL은 PRICE_E9=24221000000로 실행
RISK=${RISK:-100}
SIGFILE=.demo_last_signal

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
dim()  { printf '\033[2m%s\033[0m\n' "$*"; }

chain_now() {
  sui client object 0x6 --json 2>/dev/null | grep timestamp_ms | tr -dc '0-9'
}

deep_coin() {
  sui client balance --with-coins 2>/dev/null \
    | grep -A4 'DeepBook Token' | grep -oE '0x[0-9a-f]{64}' | head -1
}

state() {
  sui client object "$VAULT" --json 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)["content"]
S={"0":"ACTIVE","0.0":"ACTIVE","1":"REDUCE_ONLY","1.0":"REDUCE_ONLY","2":"PAUSED","2.0":"PAUSED"}
st=S.get(str(d["agora_agent_status"]),str(d["agora_agent_status"]))
print(f"""  상태            {st}
  fiat  (DBUSDC)  {int(d["fiat_balance"])/1e6:>14,.4f}
  crypto (SUI)    {int(d["crypto_balance"])/1e9:>14,.4f}
  cost basis      {int(d["cost_basis_fiat"])/1e6:>14,.4f}
  누적 실현손실   {int(d["realized_loss_amount"])/1e6:>14,.4f}  / 한도 {int(d["max_loss_amount"])/1e6:,.2f}
  Kill Switch 창  {int(d["window_loss_amount"])/1e6:>14,.4f}  / 임계 {int(d["max_window_loss_amount"])/1e6:,.2f}
  오늘 거래량     {int(d["daily_fiat_volume"])/1e6:>14,.4f}  / 한도 {int(d["max_daily_fiat_volume"])/1e6:,.2f}
  기록된 signal   {d["executed_signals"]["size"]:>14}건 (중복 차단용)""")'
}

trade() { # $1=execute_buy|execute_sell  $2=amount  $3=min_out  $4=signal_id  $5=signal_ts  $6=deadline  $7=extra flags
  sui client ptb $7 \
    --assign deep @"$(deep_coin)" \
    --move-call "$PKG::deepbook_executor::$1" "$TYPES" \
      @"$VAULT" @"$POOL" deep "$2" "$3" "$4" "$5" "$PRICE_E9" "$RISK" "$6" @0x6 \
    --gas-budget 60000000 2>&1
}

sigid() { python3 -c "
import random
b=[random.randrange(1,255) for _ in range(8)]
print('vector['+','.join(f'{x}u8' for x in b)+']')"; }

abort_of() { grep -oE '\}, [0-9]+\) in command' <<<"$1" | head -1 | tr -dc '0-9'; }

# abort_of는 숫자만 준다. 어느 모듈의 몇 번인지가 중요할 때는 이걸 쓴다.
# MoveLocation 안에 Some("...") 괄호가 들어 있어 [^)]* 로는 못 끊는다.
abort_where() {
  sed -n 's/.*name: Identifier("\([^"]*\)").*function_name: Some("\([^"]*\)").*}, \([0-9]*\)) in command.*/\1::\2  abort \3/p' \
    <<<"$1" | head -1
}

case "${1:-state}" in
  state)
    bold "── Vault $VAULT"; state ;;

  buy|sell)
    DIR=$1
    NOW=$(chain_now); TS=$((NOW-60000)); DL=$((NOW+600000))
    SID=$(sigid); echo "$SID" > "$SIGFILE"
    if [ "$DIR" = buy ]; then FN=execute_buy; AMT=$BUY_FIAT; MIN=$BUY_MIN_OUT
      bold "── BUY  ${AMT} DBUSDC → SUI   (DeepBook $POOL)"
    else FN=execute_sell
      AMT=$(sui client object "$VAULT" --json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["content"]["crypto_balance"])')
      MIN=$SELL_MIN_OUT
      bold "── SELL ${AMT} MIST(SUI) → DBUSDC"
    fi
    dim "   signal_id=$SID  risk=${RISK}bps  price=${PRICE_E9}e-9  TTL 5분"
    bold "── 실행 전"; state
    OUT=$(trade "$FN" "$AMT" "$MIN" "$SID" "$TS" "$DL" "")
    if grep -q "Status.*Success\|Transaction executed" <<<"$OUT" && ! grep -q "MoveAbort" <<<"$OUT"; then
      DIGEST=$(grep -oE '│ Digest.*' <<<"$OUT" | grep -oE '[A-HJ-NP-Za-km-z1-9]{43,45}' | head -1)
      printf '\033[32m   ✔ 체결\033[0m  %s\n' "$DIGEST"
      dim "   https://suiscan.xyz/testnet/tx/$DIGEST"
    else
      printf '\033[31m   ✘ 실패  abort code %s\033[0m\n' "$(abort_of "$OUT")"
      grep -E "MoveAbort|Error" <<<"$OUT" | head -3
    fi
    bold "── 실행 후"; state ;;

  dup)
    NOW=$(chain_now); SID=$(cat "$SIGFILE" 2>/dev/null || sigid)
    bold "── 가드레일 ①  같은 signal_id 재사용 (replay)"
    dim "   $SID — 직전 거래에서 이미 소진된 signal"
    OUT=$(trade execute_buy "$BUY_FIAT" "$BUY_MIN_OUT" "$SID" "$((NOW-60000))" "$((NOW+600000))" "--dry-run")
    printf '\033[33m   → abort %s  E_DUPLICATE_SIGNAL — 자금 이동 없음\033[0m\n' "$(abort_of "$OUT")" ;;

  stale)
    NOW=$(chain_now)
    bold "── 가드레일 ②  10분 지난 signal (TTL 5분)"
    OUT=$(trade execute_buy "$BUY_FIAT" "$BUY_MIN_OUT" "$(sigid)" "$((NOW-600000))" "$((NOW+600000))" "--dry-run")
    printf '\033[33m   → abort %s  E_SIGNAL_EXPIRED — 낡은 시그널은 실행되지 않는다\033[0m\n' "$(abort_of "$OUT")" ;;

  over)
    NOW=$(chain_now)
    bold "── 가드레일 ③  1회 한도(1.0 DBUSDC) 초과 주문 5.0 DBUSDC"
    OUT=$(trade execute_buy 5000000 "$BUY_MIN_OUT" "$(sigid)" "$((NOW-60000))" "$((NOW+600000))" "--dry-run")
    printf '\033[33m   → abort %s  한도 초과 — Agent가 마음대로 키울 수 없다\033[0m\n' "$(abort_of "$OUT")" ;;

  nodeep)
    # ⚠️ 현재 POOL(DEEP_SUI)은 whitelisted라 이 케이스는 abort하지 않는다.
    #    가드가 발동하려면 비-whitelisted Pool(SUI_DBUSDC 등)이어야 한다.
    # DeepBook은 deep_in이 0이면 막지 않고 input-token 수수료 모드로 그냥 넘어간다
    # (고정 리비전 pool.move swap_exact_quantity에서 확인). 그 모드의 수수료는 Vault가
    # 넣은 입력 코인에서 나가므로 사용자 자금이 거래 수수료를 내게 되고, 요율도
    # taker_fee × 1.25라 더 비싸다. 그래서 우리가 먼저 끊는다.
    # dry-run이라 가스도 자금도 움직이지 않는다.
    NOW=$(chain_now)
    bold "── 가드레일 ④  DEEP 0으로 매수 (수수료를 Vault에 떠넘기는 경로)"
    dim "   Pool $POOL — abort 위치를 모듈 이름까지 출력한다"
    OUT=$(sui client ptb --dry-run \
      --move-call 0x2::coin::zero "<$DEEPT>" \
      --assign deep \
      --move-call "$PKG::deepbook_executor::execute_buy" "$TYPES" \
        @"$VAULT" @"$POOL" deep "$BUY_FIAT" "$BUY_MIN_OUT" "$(sigid)" \
        "$((NOW-60000))" "$PRICE_E9" "$RISK" "$((NOW+600000))" @0x6 \
      --gas-budget 60000000 2>&1)
    W=$(abort_where "$OUT")
    if [ -n "$W" ]; then
      printf '\033[33m   → %s  E_DEEP_FEE_REQUIRED — 수수료는 운영 예산이 낸다\033[0m\n' "$W"
    else
      printf '\033[31m   ✘ MoveAbort 없음 — 가드가 동작하지 않았다\033[0m\n'
      grep -E "MoveAbort|Error|Failure" <<<"$OUT" | head -5
    fi ;;

  *) sed -n '2,15p' "$0" ;;
esac
