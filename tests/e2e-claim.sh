#!/usr/bin/env bash
# e2e-claim.sh — Canary test for the rhobot.dev claim flow
# Registers a throwaway agent, validates the full claim pipeline, then cleans up.
#
# Usage: ./tests/e2e-claim.sh [BASE_URL] [API_URL]
#   BASE_URL  defaults to https://rhobot.dev
#   API_URL   defaults to https://api.rhobot.dev

set -uo pipefail

BASE="${1:-https://rhobot.dev}"
API="${2:-https://api.rhobot.dev}"
HANDLE="canary-$(date +%s)"
PASS=0
FAIL=0
SKIP=0
CLEANUP_KEY=""
CLEANUP_ID=""

# ── helpers ──────────────────────────────────────────────

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
dim()   { printf '\033[2m%s\033[0m\n' "$*"; }

check() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then
    green "  ✓ $name"
    PASS=$((PASS + 1))
  else
    red "  ✗ $name"
    FAIL=$((FAIL + 1))
  fi
}

skip() { yellow "  ⊘ $1 (skipped: $2)"; SKIP=$((SKIP + 1)); }

jq_val() { echo "$1" | python3 -c "import sys,json; print(json.load(sys.stdin)$2)" 2>/dev/null; }

cleanup() {
  if [[ -n "$CLEANUP_KEY" && -n "$CLEANUP_ID" ]]; then
    dim "  ⧗ cleaning up $HANDLE@rhobot.dev"
    curl -sf -X DELETE "$API/v1/agents/$CLEANUP_ID" \
      -H "Authorization: Bearer $CLEANUP_KEY" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ── 1. API health ────────────────────────────────────────

echo "① API health"
HEALTH=$(curl -sf "$API/v1/health" || echo '{}')
check "api returns ok"  [ "$(jq_val "$HEALTH" '["ok"]')" = "True" ]
check "d1 status ok"    [ "$(jq_val "$HEALTH" '["checks"]["d1"]["status"]')" = "ok" ]
check "r2 status ok"    [ "$(jq_val "$HEALTH" '["checks"]["r2"]["status"]')" = "ok" ]

# ── 2. Public config ────────────────────────────────────

echo "② Public config"
CONFIG=$(curl -sf "$API/v1/public-config" || echo '{}')
check "config returns ok"          [ "$(jq_val "$CONFIG" '["ok"]')" = "True" ]
check "claim_base_url is $BASE"    [ "$(jq_val "$CONFIG" '["claim_base_url"]')" = "$BASE" ]
check "clerk key present"          [ "$(jq_val "$CONFIG" '["clerk_publishable_key"]' | cut -c1-3)" = "pk_" ]

# ── 3. Register ──────────────────────────────────────────

echo "③ Register $HANDLE"
REG=$(curl -s -X POST "$API/v1/register" \
  -H "Content-Type: application/json" \
  -d "{\"name\": \"$HANDLE\", \"display_name\": \"E2E Canary\"}")

REG_OK=$(jq_val "$REG" '["ok"]')
REG_ERR=$(jq_val "$REG" '["error"]' 2>/dev/null || echo "")
RATE_LIMITED=false

if [ "$REG_OK" = "True" ]; then
  green "  ✓ registration ok"
  PASS=$((PASS + 1))

  API_KEY=$(jq_val "$REG" '["data"]["api_key"]')
  AGENT_ID=$(jq_val "$REG" '["data"]["agent_id"]')
  CLAIM_URL=$(jq_val "$REG" '["data"]["claim_url"]')
  CLAIM_STATUS=$(jq_val "$REG" '["data"]["claim_status"]')
  CLEANUP_KEY="$API_KEY"
  CLEANUP_ID="$AGENT_ID"

  check "got api_key"                       [ -n "$API_KEY" ]
  check "got agent_id"                      [ -n "$AGENT_ID" ]
  check "got claim_url"                     [ -n "$CLAIM_URL" ]
  check "status is pending"                 [ "$CLAIM_STATUS" = "pending" ]
  check "claim_url starts with $BASE"       [ "$(echo "$CLAIM_URL" | grep -c "^$BASE/claim/")" -gt 0 ]
else
  red "  ✗ registration failed: $REG_ERR"
  FAIL=$((FAIL + 1))
  if echo "$REG_ERR" | grep -qi "rate\|too many"; then
    RATE_LIMITED=true
    yellow "    ↳ rate limited — skipping registration-dependent tests"
  fi
  API_KEY=""
  AGENT_ID=""
  CLAIM_URL=""
fi

# ── 4. Agent auth ────────────────────────────────────────

echo "④ Agent auth"
if [ -n "$API_KEY" ]; then
  STATUS=$(curl -sf -H "Authorization: Bearer $API_KEY" "$API/v1/agents/status" 2>/dev/null || echo '{"ok":false}')
  check "auth returns ok" [ "$(jq_val "$STATUS" '["ok"]')" = "True" ]
else
  skip "auth returns ok" "no api_key"
fi

# ── 5. Duplicate handle rejected ─────────────────────────

echo "⑤ Duplicate handle"
if [ -n "$API_KEY" ]; then
  sleep 2  # avoid rate limiter
  DUP_HTTP=$(curl -so /dev/null -w '%{http_code}' -X POST "$API/v1/register" \
    -H "Content-Type: application/json" \
    -d "{\"name\": \"$HANDLE\", \"display_name\": \"Dup\"}")
  check "duplicate rejected (409 or 429)" [ "$DUP_HTTP" = "409" -o "$DUP_HTTP" = "429" ]
else
  skip "duplicate rejected" "no registration"
fi

# ── 6. Claim page serves SPA ─────────────────────────────

echo "⑥ Claim page"
if [ -n "$CLAIM_URL" ]; then
  CLAIM_HEADERS=$(curl -sI "$CLAIM_URL")
  CLAIM_HTTP=$(echo "$CLAIM_HEADERS" | head -1 | grep -oP '\d{3}')
  CLAIM_CT=$(echo "$CLAIM_HEADERS" | grep -i '^content-type:' | tr -d '\r')
  check "claim URL returns 200"           [ "$CLAIM_HTTP" = "200" ]
  check "claim content-type is html"      [ "$(echo "$CLAIM_CT" | grep -ci 'text/html')" -gt 0 ]

  CLAIM_BODY=$(curl -s "$CLAIM_URL")
  check "serves claim SPA (not homepage)" [ "$(echo "$CLAIM_BODY" | grep -c 'claim-web\|id="root"')" -gt 0 ]
  check "SPA has module script"           [ "$(echo "$CLAIM_BODY" | grep -c 'type="module"')" -gt 0 ]
else
  # Test with a dummy token path — SPA should still load
  dim "    (no claim_url — testing /claim/canary-test instead)"
  TEST_CLAIM="$BASE/claim/canary-test"
  CLAIM_HEADERS=$(curl -sI "$TEST_CLAIM")
  CLAIM_HTTP=$(echo "$CLAIM_HEADERS" | head -1 | grep -oP '\d{3}')
  check "claim route returns 200"         [ "$CLAIM_HTTP" = "200" ]

  CLAIM_BODY=$(curl -s "$TEST_CLAIM")
  check "serves claim SPA (not homepage)" [ "$(echo "$CLAIM_BODY" | grep -c 'claim-web\|id="root"')" -gt 0 ]
  check "SPA has module script"           [ "$(echo "$CLAIM_BODY" | grep -c 'type="module"')" -gt 0 ]
fi

# ── 7. SPA assets load correctly ─────────────────────────

echo "⑦ SPA assets"
# Get asset paths from whichever claim body we have
JS_PATH=$(echo "$CLAIM_BODY" | grep -oP '/claim/assets/index-[^"]+\.js' || true)
CSS_PATH=$(echo "$CLAIM_BODY" | grep -oP '/claim/assets/index-[^"]+\.css' || true)

if [ -n "$JS_PATH" ]; then
  JS_CT=$(curl -sI "$BASE$JS_PATH" | grep -i '^content-type:' | tr -d '\r')
  check "JS served as application/javascript" [ "$(echo "$JS_CT" | grep -ci 'javascript')" -gt 0 ]
  JS_BODY=$(curl -s "$BASE$JS_PATH" | head -c 50)
  check "JS content is actual javascript"     [ "$(echo "$JS_BODY" | grep -c '<!doctype\|<!DOCTYPE')" -eq 0 ]
else
  red "  ✗ JS path not found in SPA"; FAIL=$((FAIL + 1))
fi

if [ -n "$CSS_PATH" ]; then
  CSS_CT=$(curl -sI "$BASE$CSS_PATH" | grep -i '^content-type:' | tr -d '\r')
  check "CSS served as text/css" [ "$(echo "$CSS_CT" | grep -ci 'text/css')" -gt 0 ]
else
  red "  ✗ CSS path not found in SPA"; FAIL=$((FAIL + 1))
fi

# ── 8. Static pages ──────────────────────────────────────

echo "⑧ Static pages"
for path in / /email/ /terms/ /privacy/ /refund/; do
  HTTP=$(curl -so /dev/null -w '%{http_code}' "$BASE$path")
  check "$path returns 200" [ "$HTTP" = "200" ]
done

EMAIL_TITLE=$(curl -s "$BASE/email/" | grep -oP '(?<=<title>)[^<]+')
check "email page has correct title" [ "$(echo "$EMAIL_TITLE" | grep -ci 'rhobot mail')" -gt 0 ]

# ── 9. Redirects ─────────────────────────────────────────

echo "⑨ Redirects"
INSTALL_HTTP=$(curl -so /dev/null -w '%{http_code}' "$BASE/install")
check "/install redirects (302)" [ "$INSTALL_HTTP" = "302" ]

DOCS_HTTP=$(curl -so /dev/null -w '%{http_code}' "$BASE/docs")
check "/docs redirects (302)" [ "$DOCS_HTTP" = "302" ]

SKILL_CT=$(curl -sI "$BASE/skill.md" | grep -i '^content-type:' | tr -d '\r')
check "skill.md served as markdown" [ "$(echo "$SKILL_CT" | grep -ci 'text/markdown')" -gt 0 ]

# ── summary ──────────────────────────────────────────────

echo ""
TOTAL=$((PASS + FAIL))
SUMMARY="$PASS passed"
[ "$FAIL" -gt 0 ] && SUMMARY="$SUMMARY, $FAIL failed"
[ "$SKIP" -gt 0 ] && SUMMARY="$SUMMARY, $SKIP skipped"

if [ "$FAIL" -eq 0 ]; then
  green "ALL $TOTAL CHECKS PASSED${SKIP:+ ($SKIP skipped)}"
  exit 0
else
  red "$SUMMARY (of $TOTAL)"
  exit 1
fi
