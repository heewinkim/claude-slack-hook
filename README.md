# claude-slack-hook

Claude Code가 대기 상태일 때 Slack으로 알림을 보내는 훅.

작업을 맡겨두고 자리를 비웠을 때, Claude가 완료했거나 답변을 기다리고 있으면 Slack으로 알림이 옵니다.

## 알림 종류

| 상황 | 알림 내용 |
|------|----------|
| Claude가 작업 완료 후 60초 대기 | 📝 요청 / 🤖 응답 / 🔧 다음 작업 목록 |
| Claude가 질문 후 30초 내 응답 없음 | ❓ 질문 내용 + 선택지 |
| 30초 내 응답 | 알림 없음 (자동 취소) |

## 설치

### 1단계 — 클론

```bash
git clone https://github.com/heewinkim/claude-slack-hook ~/.claude/hooks/slack_notification_hook
```

### 2단계 — 설치 스크립트 실행

```bash
bash ~/.claude/hooks/slack_notification_hook/install.sh
```

설치 스크립트가 자동으로 처리합니다:
- 의존성 확인 (jq, curl, shasum)
- Slack Bot Token / Channel ID 입력받아 `~/.claude/.env`에 저장
- `~/.claude/settings.json`에 훅 등록
- 전송 테스트

---

## 수동 설치

### 의존성

```bash
# Ubuntu/Debian
sudo apt install jq curl

# macOS
brew install jq
```

### Slack Bot Token 발급

1. https://api.slack.com/apps → **Create New App**
2. **OAuth & Permissions** → Bot Token Scopes → `chat:write` 추가
3. **Install to Workspace** → `xoxb-...` 토큰 복사
4. 알림 받을 채널에서 `/invite @봇이름`
5. 채널 우클릭 → 채널 세부정보 → 맨 아래 채널 ID (`C...`) 복사

### 환경변수 설정

`~/.claude/.env`:
```bash
SLACK_BOT_TOKEN=xoxb-...
SLACK_CHANNEL_ID=C...
```

선택 옵션:
```bash
CLAUDE_ATTENTION_DELAY=30       # 질문 알림 딜레이(초), 기본 30
CLAUDE_ATTENTION_TRUNCATE=10    # 메시지 최대 줄 수, 기본 10
CLAUDE_THREAD_EXPIRY_HOURS=8    # 스레드 유지 시간, 기본 8시간
```

### settings.json 등록

`~/.claude/settings.json`:
```json
{
  "hooks": {
    "Notification": [
      {
        "matcher": "idle_prompt",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/slack_notification_hook/notify-slack.sh", "async": true}]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/slack_notification_hook/ask-timer.sh"}]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "AskUserQuestion",
        "hooks": [{"type": "command", "command": "~/.claude/hooks/slack_notification_hook/cancel-timer.sh"}]
      }
    ]
  }
}
```

---

## 파일 구조

```
slack_notification_hook/
  install.sh        # 자동 설치 스크립트
  slack-common.sh   # 공통 유틸리티 (env 로딩, Block Kit 전송, 스레드 관리)
  notify-slack.sh   # idle_prompt 훅
  ask-timer.sh      # AskUserQuestion 훅 (타이머 시작)
  cancel-timer.sh   # AskUserQuestion 훅 (타이머 취소)
```

## 의존성

- `jq` — 트랜스크립트 파싱 + Block Kit JSON 생성
- `curl` — Slack API 호출
- `shasum` — 세션 해시 / 중복 방지 (기본 내장)
