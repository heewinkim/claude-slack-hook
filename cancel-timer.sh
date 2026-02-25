#!/usr/bin/env bash
# cancel-timer.sh — PostToolUse/AskUserQuestion 훅
# 사용자 응답 시 ask-timer.sh의 백그라운드 타이머 취소
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/cwf/hooks/slack_notification_hook/slack-common.sh
source "$SCRIPT_DIR/slack-common.sh"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
HASH=""
[ -n "$SESSION_ID" ] && HASH=$(session_hash "$SESSION_ID")

PID_FILE=$(state_file "$HASH" "ask-pid")
[ -f "$PID_FILE" ] || exit 0

PID=$(cat "$PID_FILE" 2>/dev/null) || true

# PID 파일 먼저 삭제 (백그라운드 프로세스가 확인하는 조건)
rm -f "$PID_FILE"

# sleep 프로세스 종료
if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
fi

exit 0
