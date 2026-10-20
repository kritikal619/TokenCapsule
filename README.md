# TokenCapsule

macOS용 토큰 오버레이. [TokenOverlay](https://github.com/igayowai/TokenOverlay)(Windows)와 비슷하게 Claude·Codex·DeepSeek(Qoder)의 마지막 턴 토큰·시간·속도를 화면 위 캡슐로 보여 준다.

- 캡슐: 마지막 턴의 합계 토큰, 걸린 시간, 모델 속도(도구 실행 제외), 생성 속도(첫 토큰 대기 제외)
- 여러 모델을 함께 쓸 때: 기본은 최근 15분 안에 쓴 모델마다 한 줄씩 표시. 메뉴에서 "최근 턴 하나만 보기"로 바꿀 수 있다.
- 캡슐 클릭: 이번 턴 입력/캐시/출력/생각 토큰과 시간 내역
- Ctrl을 누른 채 캡슐 위에 마우스: 최근 턴 8개와 주간 사용량(Codex 5시간·주간 한도 %, Claude 7일·오늘 토큰)
- 메뉴 막대 아이콘: 표시 방식(항상 / Claude·Codex·Qoder 사용 중일 때), 모델별·하나만 보기, 속도 줄 표시, 로그인 시 자동 실행, 위치 초기화
- 캡슐은 드래그로 옮길 수 있고 위치를 기억한다.

## 데이터

로컬 로그만 읽는다. 외부 전송 없음. 대화 내용·도구 입력/출력·답변 텍스트는 읽지 않고, 숫자 사용량·시각·ID만 쓴다.

- Claude Code: `~/.claude/projects/**/*.jsonl` (assistant 메시지의 usage, 같은 메시지 id는 중복 제거)
- Codex: `~/.codex/sessions/**/rollout-*.jsonl` (`token_usage_record`, `task_complete`의 duration/첫 토큰, `token_count`의 rate_limits)
- DeepSeek(Qoder 워커): `~/.codex/skills/qoder-delegate/usage.jsonl` — qoder-delegate 브리지가 호출마다 숫자만 남기는 기록. 토큰 0인 호출(대기열·취소)은 제외
- DeepSeek(Qoder CLI 직접 사용): `~/.qoder/projects/**/*.jsonl` (Claude Code와 같은 형식)

Claude·DeepSeek는 로그에 한도 비율이 없어 토큰 합계만 보여 준다. Claude의 첫 토큰·속도는 메시지 기록 시각 기준 추정값이다.

## 빌드

```
./build.sh
```

`~/Applications/TokenCapsule.app`에 설치된다(ad-hoc 서명, Apple Silicon, macOS 14+). Xcode 없이 Command Line Tools의 `swiftc`만 있으면 된다.

처음 열 때 Gatekeeper가 막으면 Finder에서 앱을 우클릭 → 열기.

## 개발용 도구

- `Tools/check`: 로그를 읽어 최근 턴·한도를 숫자로 출력
- `Tools/render`: 화면을 PNG로 렌더링 (`swiftc ... Sources/Logs.swift Sources/UI.swift Tools/render/main.swift`)

[TokenOverlay](https://github.com/igayowai/TokenOverlay)(MIT)의 기능 구성을 참고했으며 코드는 새로 작성했다.
