#!/usr/bin/env bash
# ask-timer.sh — PreToolUse/AskUserQuestion 훅
# 에이전트 질문 후 CLAUDE_ATTENTION_DELAY초 대기 → Slack Block Kit 알림
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/cwf/hooks/slack_notification_hook/slack-common.sh
source "$SCRIPT_DIR/slack-common.sh"

load_env

DELAY="${CLAUDE_ATTENTION_DELAY:-30}"

# === 입력 ===
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')

HASH=""
[ -n "$SESSION_ID" ] && HASH=$(session_hash "$SESSION_ID")
PID_FILE=$(state_file "$HASH" "ask-pid")

# === 질문 내용 추출 ===
QUESTIONS_JSON=$(echo "$TOOL_INPUT" | jq -c '.questions // []' 2>/dev/null || echo "[]")

# === 백그라운드 타이머 시작 ===
(
    sleep "$DELAY"
    [ -f "$PID_FILE" ] || exit 0

    # Block Kit 빌드
    BLOCKS=$(jq -n \
        --arg host "$(hostname)" \
        --argjson questions "$QUESTIONS_JSON" \
        '
        def format_q($q):
            "*[" + ($q.header // "질문") + "]* " + $q.question + "\n" +
            ($q.options | to_entries | map(
                "  " + ((.key + 1) | tostring) + ". *" + .value.label + "*" +
                if .value.description != "" and .value.description != null
                    then " — " + .value.description
                    else ""
                end
            ) | join("\n"));

        [
            {"type": "header", "text": {"type": "plain_text", "text": "❓ Claude가 답변을 기다리고 있습니다", "emoji": true}},
            {"type": "context", "elements": [{"type": "mrkdwn", "text": ("_" + $host + "_")}]},
            if ($questions | length) > 0 then {"type": "divider"} else empty end,
            if ($questions | length) > 0 then
                {"type": "section", "text": {"type": "mrkdwn", "text": ($questions | map(format_q(.)) | join("\n\n"))}}
            else empty end
        ]
        ')

    FALLBACK="Claude @ $(hostname): 답변을 기다리고 있습니다"

    THREAD_TS_FILE=$(state_file "$HASH" "thread-ts")
    if [ -f "$THREAD_TS_FILE" ] && is_thread_fresh "$HASH"; then
        THREAD_TS=$(cat "$THREAD_TS_FILE")
        slack_send_blocks "$FALLBACK" "$BLOCKS" "$THREAD_TS" ""
    else
        clear_thread "$HASH"
        slack_send_blocks "$FALLBACK" "$BLOCKS" "" "$HASH"
    fi
) &

echo $! > "$PID_FILE"

exit 0
