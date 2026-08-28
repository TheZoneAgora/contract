#!/usr/bin/env bash
# AgoraAgent 실행기 기동 스크립트.
#
#   ./scripts/run-agent.sh
#
# 운영자 개인키는 매번 keystore에서 꺼내 프로세스에만 넘긴다. 파일에도 화면에도
# 남기지 않는다 — export를 따로 실행하면 터미널 스크롤백에 평문으로 남는다.
#
# 값을 바꾸고 싶으면 앞에 붙여 덮어쓰면 된다:
#   AGENT_VAULT_ID=0x... ./scripts/run-agent.sh
set -euo pipefail

cd "$(dirname "$0")/.."

# --- 배포 상수 (PROGRESS.md §7 배포 이력과 같아야 한다) ----------------------
export AGENT_PACKAGE_ID="${AGENT_PACKAGE_ID:-0x7dcf1c6495682131bcf3a41d4723f7422ca4d49aadaed5d8bc9c2e4a683deb26}"
export AGENT_VAULT_ID="${AGENT_VAULT_ID:-0x5dc2a80f4a49736dbbf6228839a0f5eb7a86f6e5c65dd7b85b4f8f3cc0f7c4b5}"
export AGENT_POOL_ID="${AGENT_POOL_ID:-0x48c95963e9eac37a316b7ae04a0deb761bcdcc2b67912374d6036e7f0e9bae9f}"

# DEEP_SUI는 whitelisted다 — DEEP을 넣으면 전액 소모되므로 반드시 0을 넣어야 한다.
# 비-whitelisted Pool로 바꾸면 false로 두고 AGENT_DEEP_COIN_ID도 지정해야 한다.
export AGENT_POOL_WHITELISTED="${AGENT_POOL_WHITELISTED:-true}"

DEEP_TYPE=0x36dbef866a1d62bf7328989a10fb2f07d769f4ee587c0de4a0a256e57e0a58a8::deep::DEEP
export AGENT_FIAT_TYPE="${AGENT_FIAT_TYPE:-0x2::sui::SUI}"
export AGENT_CRYPTO_TYPE="${AGENT_CRYPTO_TYPE:-$DEEP_TYPE}"
export AGENT_DEEP_TYPE="${AGENT_DEEP_TYPE:-$DEEP_TYPE}"

# 코인마다 decimals가 다르다. 틀리면 signal_price_e9이 어긋나 전부 거부된다.
export AGENT_FIAT_DECIMALS="${AGENT_FIAT_DECIMALS:-9}"    # SUI
export AGENT_CRYPTO_DECIMALS="${AGENT_CRYPTO_DECIMALS:-6}" # DEEP

# Providing Agent가 보내야 할 페어 기호. 지정하지 않으면 코인 타입에서 유도한다
# (Pool<CryptoT, FiatT> -> "DEEP/SUI"). 다른 페어의 시그널은 400으로 끊는다 —
# price를 엉뚱한 페어 기준으로 읽어 온체인 편차 가드에 걸리는 것을 막기 위해서다.
# export AGENT_SYMBOL="DEEP/SUI"

# Pool 최소 주문(DEEP_SUI 기준 약 0.28 SUI / 10 DEEP)보다 커야 한다.
# 작게 잡으면 한도 가드가 아니라 E_BELOW_MIN_SIZE가 먼저 나온다.
export AGENT_BUY_FIAT_AMOUNT="${AGENT_BUY_FIAT_AMOUNT:-300000000}"
export AGENT_SELL_CRYPTO_AMOUNT="${AGENT_SELL_CRYPTO_AMOUNT:-11000000}"

# --- 공유 비밀 (요청 인증) ---------------------------------------------------
# :8500은 사용자 자금을 움직인다. 서명 없는 요청은 401로 끊는다.
# 재시작해도 같은 값이어야 Providing Agent 설정을 다시 안 바꾼다 — 파일에 둔다.
SECRET_FILE="${AGENT_SECRET_FILE:-.agent-secret}"

if [ -z "${AGENT_SHARED_SECRET:-}" ]; then
  if [ ! -f "$SECRET_FILE" ]; then
    (umask 077 && openssl rand -hex 32 > "$SECRET_FILE")
    echo "새 공유 비밀을 만들었습니다: $SECRET_FILE" >&2
    echo "  이 값을 Providing Agent(MINT)에게 전달하세요." >&2
    echo >&2
  fi
  AGENT_SHARED_SECRET=$(cat "$SECRET_FILE")
fi
export AGENT_SHARED_SECRET

# --- 운영자 키 ---------------------------------------------------------------
# Vault의 agora_agent_operator와 같은 주소여야 한다. 다르면 E_NOT_AGORA_AGENT다.
OPERATOR_ADDRESS="${AGENT_OPERATOR_ADDRESS:-0x141a93d0f4799b196c67103975af1b1420579781a69bd923b3c9005d88e8251d}"

if [ -z "${AGENT_OPERATOR_SECRET_KEY:-}" ]; then
  AGENT_OPERATOR_SECRET_KEY=$(
    sui keytool export --key-identity "$OPERATOR_ADDRESS" --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin)["exportedPrivateKey"])'
  ) || {
    echo "키를 꺼내지 못했습니다. keystore에 $OPERATOR_ADDRESS 가 있는지 확인하세요:" >&2
    echo "  sui client addresses" >&2
    exit 1
  }
fi
export AGENT_OPERATOR_SECRET_KEY

# --- 기동 --------------------------------------------------------------------
echo "Vault  $AGENT_VAULT_ID"
echo "Pool   $AGENT_POOL_ID (whitelisted=$AGENT_POOL_WHITELISTED)"
echo
echo "시그널 보내기 (서명 포함):"
echo "  ./scripts/send-signal.sh BUY 0.0272"
echo

exec node scripts/agent-executor.mjs
