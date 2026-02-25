#!/usr/bin/env bash
# install.sh — Claude Slack Notification Hook 설치 스크립트
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$HOME/.claude/.env"
SETTINGS_FILE="$HOME/.claude/settings.json"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()    { echo -e "${GREEN}[+]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[x]${NC} $*"; exit 1; }

echo ""
echo "  Claude Slack Notification Hook 설치"
echo "  ====================================="
echo ""

# === 의존성 확인 ===
info "의존성 확인..."
for cmd in jq curl shasum; do
    command -v "$cmd" &>/dev/null || error "$cmd 가 없습니다. 설치 후 다시 시도하세요."
done
info "의존성 OK (jq, curl, shasum)"

# === Slack 설정 ===
echo ""
mkdir -p "$HOME/.claude"

# .env에서 기존 값 확인
load_existing() {
    local key="$1"
    [ -f "$ENV_FILE" ] || return
    local val
    val=$(grep -E "^${key}=" "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '"'"'") || true
    # 인라인 주석 제거
    val="${val%%[[:space:]]*#*}"
    echo "$val"
}

EXISTING_TOKEN=$(load_existing "SLACK_BOT_TOKEN")
EXISTING_CHANNEL=$(load_existing "SLACK_CHANNEL_ID")

if [ -n "$EXISTING_TOKEN" ] && [ -n "$EXISTING_CHANNEL" ]; then
    warn "기존 설정 발견:"
    warn "  SLACK_BOT_TOKEN = ${EXISTING_TOKEN:0:12}..."
    warn "  SLACK_CHANNEL_ID = $EXISTING_CHANNEL"
    read -rp "  기존 설정을 유지할까요? [Y/n] " keep
    if [[ "${keep:-Y}" =~ ^[Yy]$ ]]; then
        info "기존 설정 유지"
        SLACK_BOT_TOKEN="$EXISTING_TOKEN"
        SLACK_CHANNEL_ID="$EXISTING_CHANNEL"
    else
        EXISTING_TOKEN=""
        EXISTING_CHANNEL=""
    fi
fi

if [ -z "$EXISTING_TOKEN" ] || [ -z "$EXISTING_CHANNEL" ]; then
    echo ""
    echo "  Slack Bot Token 발급: https://api.slack.com/apps"
    echo "  → Create New App → OAuth & Permissions → chat:write 스코프 추가 → Install to Workspace"
    echo ""
    read -rp "  SLACK_BOT_TOKEN (xoxb-...): " SLACK_BOT_TOKEN
    [ -z "$SLACK_BOT_TOKEN" ] && error "SLACK_BOT_TOKEN을 입력해주세요."

    echo ""
    echo "  채널 ID: 채널 우클릭 → 채널 세부정보 → 맨 아래 ID (C로 시작)"
    read -rp "  SLACK_CHANNEL_ID (C...): " SLACK_CHANNEL_ID
    [ -z "$SLACK_CHANNEL_ID" ] && error "SLACK_CHANNEL_ID를 입력해주세요."

    # .env에 저장
    touch "$ENV_FILE"
    # 기존 항목 제거 후 재추가
    grep -v -E "^(SLACK_BOT_TOKEN|SLACK_CHANNEL_ID)=" "$ENV_FILE" > "${ENV_FILE}.tmp" 2>/dev/null || true
    {
        cat "${ENV_FILE}.tmp"
        echo "SLACK_BOT_TOKEN=$SLACK_BOT_TOKEN"
        echo "SLACK_CHANNEL_ID=$SLACK_CHANNEL_ID"
    } > "$ENV_FILE"
    rm -f "${ENV_FILE}.tmp"
    info ".env 저장 완료: $ENV_FILE"
fi

# === 실행 권한 ===
echo ""
info "실행 권한 설정..."
chmod +x "$SCRIPT_DIR/notify-slack.sh" "$SCRIPT_DIR/ask-timer.sh" "$SCRIPT_DIR/cancel-timer.sh"

# === settings.json에 hooks 등록 ===
echo ""
info "Claude settings.json에 훅 등록..."

HOOK_DIR="$SCRIPT_DIR"

# settings.json 생성 또는 업데이트
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{}' > "$SETTINGS_FILE"
fi

# 기존 hooks에 병합 (덮어쓰지 않음)
UPDATED=$(jq \
    --arg notify "$HOOK_DIR/notify-slack.sh" \
    --arg ask    "$HOOK_DIR/ask-timer.sh" \
    --arg cancel "$HOOK_DIR/cancel-timer.sh" \
    '
    # 이미 동일한 command가 등록되어 있는지 확인하는 함수
    def has_cmd($section; $matcher; $cmd):
        (.hooks[$section] // [])[] |
        select(.matcher == $matcher) |
        .hooks[]? | select(.command == $cmd) | true;

    # Notification/idle_prompt — notify
    if (try (has_cmd("Notification"; "idle_prompt"; $notify)) catch false) then .
    else .hooks.Notification = ((.hooks.Notification // []) + [{
        "matcher": "idle_prompt",
        "hooks": [{"type": "command", "command": $notify, "async": true}]
    }]) end |

    # PreToolUse/AskUserQuestion — ask
    if (try (has_cmd("PreToolUse"; "AskUserQuestion"; $ask)) catch false) then .
    else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + [{
        "matcher": "AskUserQuestion",
        "hooks": [{"type": "command", "command": $ask}]
    }]) end |

    # PostToolUse/AskUserQuestion — cancel
    if (try (has_cmd("PostToolUse"; "AskUserQuestion"; $cancel)) catch false) then .
    else .hooks.PostToolUse = ((.hooks.PostToolUse // []) + [{
        "matcher": "AskUserQuestion",
        "hooks": [{"type": "command", "command": $cancel}]
    }]) end
    ' "$SETTINGS_FILE")

echo "$UPDATED" > "$SETTINGS_FILE"
info "settings.json 업데이트 완료: $SETTINGS_FILE"

# === 전송 테스트 ===
echo ""
read -rp "  Slack 전송 테스트를 실행할까요? [Y/n] " do_test
if [[ "${do_test:-Y}" =~ ^[Yy]$ ]]; then
    info "테스트 전송 중..."
    result=$(printf '{"transcript_path":"","session_id":"install-test"}' \
        | bash "$SCRIPT_DIR/notify-slack.sh" 2>&1 && echo "ok" || echo "fail")
    if [ "$result" = "ok" ]; then
        info "Slack 전송 성공! 채널을 확인하세요."
    else
        warn "전송 실패. SLACK_BOT_TOKEN / SLACK_CHANNEL_ID를 다시 확인하세요."
    fi
fi

echo ""
echo "  ✅ 설치 완료!"
echo ""
echo "  동작 방식:"
echo "    • Claude가 60초 이상 대기 시 → 요청/응답/진행상황 알림"
echo "    • Claude가 질문 후 30초 내 응답 없으면 → 질문 내용 알림"
echo ""
