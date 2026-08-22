#!/usr/bin/env bash
# THE ZONE AGORA — Vault × DeepBook 라이브 시연
#
#   ./scripts/demo.sh state   Vault 상태 출력
#   ./scripts/demo.sh buy     DeepBook BUY 체결 (fiat → crypto)
#   ./scripts/demo.sh sell    DeepBook SELL 체결 (crypto → fiat)
#   ./scripts/demo.sh dup     직전 signal_id 재사용 → E_DUPLICATE_SIGNAL(17)로 차단
#   ./scripts/demo.sh stale   10분 지난 signal → E_SIGNAL_EXPIRED(3)로 차단
#   ./scripts/demo.sh over    한도 초과 금액 → E_TRADE_LIMIT_EXCEEDED로 차단
#
# 차단 시연은 --dry-run이라 가스도 쓰지 않는다. 온체인 판정은 실행과 동일하다.
set -uo pipefail

PKG=0x0f5a55d4768a22382295652b415c0df973db45e4ac1d65c8ceadc3a331c68bfa
VAULT=0x4161c4f46e35990151856cd5c0b7fa14467985842afe28857108f5d35758b664
POOL=0x1c19362ca52b8ffd7a33cee805a67d40f31e6ba303753fd3a4cfdfacea7163a5
FIAT=0xf7152c05930480cd740d7311b5b8b45c6f488e3a53a11c3f74a6fac36a52e0d7::DBUSDC::DBUSDC
CRYPTO=0x2::sui::SUI
TYPES="<$FIAT,$CRYPTO>"

BUY_FIAT=${BUY_FIAT:-1000000}          # 1.0 DBUSDC
BUY_MIN_OUT=${BUY_MIN_OUT:-1000000000} # 최소 1 SUI 수령
SELL_MIN_OUT=${SELL_MIN_OUT:-600000}   # 최소 0.6 DBUSDC 수령
PRICE_E9=${PRICE_E9:-686000}           # signal이 실어 보낸 가격 (편차 500bps 안이어야 통과)
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

  *) sed -n '2,14p' "$0" ;;
esac
