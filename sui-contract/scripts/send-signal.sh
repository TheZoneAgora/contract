#!/usr/bin/env bash
# 서명된 시그널을 실행기에 보낸다.
#
#   ./scripts/send-signal.sh BUY 0.0272
#   ./scripts/send-signal.sh SELL 0.0272 DEEP/SUI
#
# 로컬 확인용이자 Providing Agent가 구현해야 할 서명 방식의 참고 구현이다.
# 핵심은 두 줄이다 — 보낼 본문 바이트 그대로 HMAC을 걸고, 헤더에 담는다.
set -euo pipefail

cd "$(dirname "$0")/.."

SIDE="${1:-}"
PRICE="${2:-}"
SYMBOL="${3:-DEEP/SUI}"

if [ -z "$SIDE" ] || [ -z "$PRICE" ]; then
  echo "사용법: $0 <BUY|SELL> <price> [symbol]" >&2
  echo "  price는 fiat per crypto다. DEEP/SUI라면 DEEP 1개당 SUI 가격(예: 0.0272)." >&2
  exit 1
fi

URL="${AGENT_URL:-http://localhost:8500/signal}"
SECRET_FILE="${AGENT_SECRET_FILE:-.agent-secret}"
SECRET="${AGENT_SHARED_SECRET:-}"

if [ -z "$SECRET" ]; then
  if [ ! -f "$SECRET_FILE" ]; then
    echo "공유 비밀이 없습니다. 실행기를 먼저 띄우면 $SECRET_FILE 이 만들어집니다." >&2
    exit 1
  fi
  SECRET=$(cat "$SECRET_FILE")
fi

# 밀리초 정수여야 한다. 초 단위로 보내면 TTL에 걸려 거부된다.
BODY=$(printf '{"agent_id":"mint","side":"%s","symbol":"%s","price":%s,"timestamp_ms":%s}' \
  "$SIDE" "$SYMBOL" "$PRICE" "$(date +%s)000")

# 서명은 **보내는 본문 바이트 그대로**에 건다. 다시 직렬화하면 어긋난다.
SIGNATURE=$(printf '%s' "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -r | cut -d' ' -f1)

echo "-> $BODY"
curl -sS -X POST "$URL" \
  -H 'content-type: application/json' \
  -H "x-agora-signature: sha256=$SIGNATURE" \
  -d "$BODY"
echo
