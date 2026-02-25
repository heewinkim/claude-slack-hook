#!/usr/bin/env bash
# notify-slack.sh — Notification/idle_prompt 훅
# Claude가 60초 이상 대기 시 Slack Block Kit 알림 전송
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=plugins/cwf/hooks/slack_notification_hook/slack-common.sh
source "$SCRIPT_DIR/slack-common.sh"

load_env

TRUNCATE_LINES="${CLAUDE_ATTENTION_TRUNCATE:-10}"

# === 입력 ===
INPUT=$(cat)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
HASH=""
[ -n "$SESSION_ID" ] && HASH=$(session_hash "$SESSION_ID")

# === 텍스트 정규화 + 길이 제한 ===
normalize_truncate() {
    local text="$1" max="${2:-0}"
    [ -z "$text" ] && return
    local normalized
    normalized=$(printf '%s\n' "$text" | awk '
        { if ($0 ~ /^[[:space:]]*$/) { if (s) b=1; next }
          if (b && s) print ""; print; s=1; b=0 }
    ')
    if [[ "$max" =~ ^[0-9]+$ ]] && [ "$max" -gt 0 ]; then
        local lines; lines=$(printf '%s\n' "$normalized" | wc -l | tr -d ' ')
        if [ "$lines" -gt "$max" ]; then
            local h=$(( max / 2 )); [ "$h" -eq 0 ] && h=1
            local t=$(( max - h ))
            printf '%s\n' "$normalized" | head -n "$h"
            echo "...(생략)..."
            [ "$t" -gt 0 ] && printf '%s\n' "$normalized" | tail -n "$t"
            return
        fi
    fi
    printf '%s\n' "$normalized"
}

# === 트랜스크립트 파싱 ===
HUMAN_TEXT="" ASSISTANT_TEXT="" TODOS_JSON="[]"
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    HUMAN_TEXT=$(jq -rs '[.[] | select(.type == "user" and (.isMeta | not)) |
        select((.message.content | type == "string") or
               (.message.content | type == "array" and any(.[]; .type == "text" or type == "string")))] |
        last | .message.content |
        if type == "string" then .
        elif type == "array" then [.[] | if .type == "text" then .text elif type == "string" then . else empty end] | join("\n")
        else "" end // ""' "$TRANSCRIPT_PATH" 2>/dev/null || echo "")

    ASSISTANT_TEXT=$(jq -rs '
        . as $all |
        ([range(length) | . as $i | $all[$i] | select(.type == "user" and (.isMeta | not)) | $i] | last // -1) as $idx |
        [$all[($idx+1):][] | select(.type == "assistant") |
         .message.content | if type == "array" then [.[] | select(.type == "text") | .text] else [.] end] |
        flatten | map(select(. != "")) | join("\n") |
        gsub("^[\\s\\n]+|[\\s\\n]+$"; "") | gsub("\\n{3,}"; "\n\n")
        ' "$TRANSCRIPT_PATH" 2>/dev/null || echo "")

    TODOS_JSON=$(jq -rs '[.[] | select(.type == "assistant") | .message.content[]? |
        select(.type == "tool_use" and .name == "TodoWrite") | .input.todos] | last // []' \
        "$TRANSCRIPT_PATH" 2>/dev/null || echo "[]")
fi

# === 텍스트 정규화 ===
HUMAN_TRIMMED=$(normalize_truncate "$HUMAN_TEXT" "$TRUNCATE_LINES")
ASSISTANT_TRIMMED=$(normalize_truncate "$ASSISTANT_TEXT" "$TRUNCATE_LINES")

# === 중복 방지 ===
CACHE_FILE=$(state_file "$HASH" "last-hash")
MSG_HASH=$(printf '%s%s%s' "$HUMAN_TRIMMED" "$ASSISTANT_TRIMMED" "$TODOS_JSON" | shasum -a 256 | cut -d' ' -f1)
if [ -f "$CACHE_FILE" ] && [ "$(cat "$CACHE_FILE" 2>/dev/null)" = "$MSG_HASH" ]; then
    exit 0
fi
echo "$MSG_HASH" > "$CACHE_FILE"

# === Block Kit 빌드 ===
BLOCKS=$(jq -n \
    --arg host "$(hostname)" \
    --arg human "$HUMAN_TRIMMED" \
    --arg assistant "$ASSISTANT_TRIMMED" \
    --argjson todos "$TODOS_JSON" \
    '
    def todo_text:
        if ($todos | length) == 0 then ""
        else
            ($todos | map(select(.status == "completed")) | length) as $done |
            ($todos | length) as $total |
            ($todos | map(select(.status != "completed"))) as $rem |
            "*🔧 진행 현황:* \($done)/\($total) 완료" +
            if ($rem | length) > 0 then
                "\n*다음 작업:*\n" + ($rem | map(
                    (if .status == "in_progress" then "▶ " else "○ " end) + .content
                ) | join("\n"))
            else
                "\n✅ 모든 작업 완료"
            end
        end;

    [
        {"type": "header", "text": {"type": "plain_text", "text": ("🐿️ Claude @ " + $host), "emoji": true}},
        if $human != "" then
            {"type": "section", "text": {"type": "mrkdwn", "text": ("*📝 요청*\n" + $human)}}
        else empty end,
        if $human != "" and $assistant != "" then {"type": "divider"} else empty end,
        if $assistant != "" then
            {"type": "section", "text": {"type": "mrkdwn", "text": ("*🤖 응답*\n" + $assistant)}}
        else empty end,
        if todo_text != "" then {"type": "divider"} else empty end,
        if todo_text != "" then
            {"type": "section", "text": {"type": "mrkdwn", "text": todo_text}}
        else empty end
    ]
    ')

FALLBACK="Claude @ $(hostname)"
[ -n "$HUMAN_TRIMMED" ] && FALLBACK+=" | 요청: $(printf '%s' "$HUMAN_TRIMMED" | head -1)"

# === 스레드 신선도 확인 후 전송 ===
THREAD_TS_FILE=$(state_file "$HASH" "thread-ts")
if [ -f "$THREAD_TS_FILE" ] && is_thread_fresh "$HASH"; then
    THREAD_TS=$(cat "$THREAD_TS_FILE")
    slack_send_blocks "$FALLBACK" "$BLOCKS" "$THREAD_TS" ""
else
    clear_thread "$HASH"
    slack_send_blocks "$FALLBACK" "$BLOCKS" "" "$HASH"
fi

exit 0
