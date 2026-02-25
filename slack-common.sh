#!/usr/bin/env bash
# 공통 유틸리티 — source로 사용
# cwf: shell-strict-mode relax reason="sourced-lib" expires="2027-01-01"

# ~/.claude/.env 로드 (이미 설정된 변수는 덮어쓰지 않음)
load_env() {
    local f="$HOME/.claude/.env"
    [ -f "$f" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]] || continue
        local k="${BASH_REMATCH[1]}" v="${BASH_REMATCH[2]}"
        local orig_v="$v"
        v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
        # 인용 부호가 없는 값만 인라인 주석 제거 (e.g. "30 # comment" → "30")
        [ "$orig_v" = "$v" ] && v="${v%%[[:space:]]*#*}"
        [ -z "${!k:-}" ] && export "$k=$v"
    done < "$f"
}

session_hash() {
    echo -n "$1" | shasum -a 256 | cut -c1-12
}

state_file() {
    local hash="$1" suffix="$2"
    echo "/tmp/claude-notify-${hash:-default}-${suffix}"
}

json_escape() {
    local t="$1"
    t="${t//\\/\\\\}"; t="${t//\"/\\\"}"; t="${t//$'\n'/\\n}"; t="${t//$'\t'/\\t}"
    printf '%s' "$t"
}

# is_thread_fresh <hash> — 스레드가 만료되지 않았으면 0 반환
is_thread_fresh() {
    local hash="$1"
    local created_file; created_file=$(state_file "$hash" "thread-created")
    [ -f "$created_file" ] || return 1
    local created; created=$(cat "$created_file" 2>/dev/null) || return 1
    local now; now=$(date +%s)
    local max_age=$(( ${CLAUDE_THREAD_EXPIRY_HOURS:-8} * 3600 ))
    [ $(( now - created )) -lt "$max_age" ]
}

# clear_thread <hash> — 스레드 상태 파일 초기화
clear_thread() {
    local hash="$1"
    rm -f "$(state_file "$hash" "thread-ts")" "$(state_file "$hash" "thread-created")"
}

# slack_send_blocks <fallback_text> <blocks_json> [thread_ts] [hash]
# hash 있으면 새 메시지 전송 시 thread_ts + 생성 시간 저장
slack_send_blocks() {
    local fallback="$1" blocks="$2" thread_ts="${3:-}" hash="${4:-}"

    if [ -n "${SLACK_BOT_TOKEN:-}" ] && [ -n "${SLACK_CHANNEL_ID:-}" ]; then
        local payload
        payload=$(jq -n \
            --arg channel "$SLACK_CHANNEL_ID" \
            --arg text "$fallback" \
            --argjson blocks "$blocks" \
            --arg thread_ts "$thread_ts" \
            'if $thread_ts != "" then
                {channel: $channel, text: $text, blocks: $blocks, thread_ts: $thread_ts}
             else
                {channel: $channel, text: $text, blocks: $blocks}
             end')

        local resp
        resp=$(curl -s -X POST "https://slack.com/api/chat.postMessage" \
            -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
            -H "Content-Type: application/json" \
            -d "$payload" 2>/dev/null)

        if [ -z "$thread_ts" ] && [ -n "$hash" ]; then
            local ts; ts=$(echo "$resp" | jq -r '.ts // empty' 2>/dev/null)
            if [ -n "$ts" ]; then
                echo "$ts" > "$(state_file "$hash" "thread-ts")"
                date +%s > "$(state_file "$hash" "thread-created")"
            fi
        fi
        return 0
    fi

    # Webhook fallback (Block Kit 미지원, 텍스트만 전송)
    if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
        local escaped; escaped=$(json_escape "$fallback")
        curl -s -X POST "${SLACK_WEBHOOK_URL}" \
            -H "Content-Type: application/json" \
            -d "{\"text\":\"${escaped}\"}" > /dev/null 2>&1
        return 0
    fi
}
