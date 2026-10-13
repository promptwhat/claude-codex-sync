# claude-codex-sync

<sub>[English README](README.en.md)</sub>

**클로드에 쌓아 둔 스킬과 규칙을 코덱스도 그대로 읽게 이어 주는 스킬입니다.** 한쪽에서 고치면 다른 쪽에도 바로 들어갑니다.

- **스킬**: 복사하지 않고 링크로 양쪽에 겁니다. 파일은 한 벌뿐이라 버전이 어긋날 일이 없습니다.
- **규칙**: `AGENTS.md` 하나가 원본이고, `CLAUDE.md`는 `@AGENTS.md` 한 줄로 그걸 불러옵니다.
- **안전장치**: 점검(`check`), 설치(`install`), 되돌리기(`undo`) 세 명령. 원본 파일은 지우지 않고, 바꾸는 파일은 먼저 백업합니다.

![같은 질문을 두 앱에 던졌더니 답이 같음](docs/same-answer.jpg)

<sub>임시 프로젝트를 이 스킬로 이은 뒤, 실제 클로드와 코덱스에 같은 질문을 했을 때의 답 그대로입니다. 클로드 쪽에만 만든 스킬과 코덱스 쪽에만 만든 스킬을 두 앱이 모두 찾았습니다.</sub>

<br>

## ⬇️ 다운로드

### **[👉 최신 버전 내려받기 (Releases)](../../releases/latest)**

`.skill` 파일과 `.zip` 파일을 같이 올려 두었고, 내용은 같습니다.

<br>

## 설치법

### 제일 쉬운 방법: AI야, 해줘

클로드에 이 한 줄만 보내면 됩니다.

```
https://github.com/promptwhat/claude-codex-sync 이 스킬 설치하고 클로드랑 코덱스 연결해줘
```

에이전트가 저장소에서 최신 파일을 받아 `~/.claude/skills/`에 넣고, 점검 → 설치 → 다시 점검까지 이어서 합니다. 손댈 곳이 있으면 그 자리에서 물어봅니다.

<details>
<summary><b>손으로 넣고 싶다면 (펼치기)</b></summary>

<br>

**1. 두 앱 설치와 로그인** (이미 쓰고 있다면 건너뛰세요)

```bash
curl -fsSL https://claude.ai/install.sh | bash
```
설치가 끝나면 새 터미널에서 `claude`를 실행하고 브라우저로 로그인합니다.

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```
`codex`를 실행하고 **Sign in with ChatGPT**를 고릅니다. ChatGPT 데스크톱 앱의 코덱스를 써도 됩니다.

**2. 스킬 넣기**: Releases에서 받은 zip을 클로드 스킬 폴더에 풉니다.

```bash
mkdir -p ~/.claude/skills && unzip ~/Downloads/claude-codex-sync-v1.4.zip -d ~/.claude/skills
```

**3. 점검부터, 그다음 설치**

```bash
bash ~/.claude/skills/claude-codex-sync/scripts/ccsync.sh check
```
```bash
bash ~/.claude/skills/claude-codex-sync/scripts/ccsync.sh install
```

프로젝트 폴더까지 이으려면 명령 뒤에 `--project 폴더경로`를 붙입니다.

</details>

<br>

## 연결됐는지 확인하기

`check`는 파일이 이어졌는지만 봅니다. 실제로 읽히는지는 앱에 물어봐야 압니다. 클로드와 코덱스를 **둘 다 새로 연 뒤**, 각각 새 창에 이 문장을 보내세요.

```
파일은 열지 말고, 지금 너에게 주어진 지침과 스킬 목록만 보고 답해. 1) 내 규칙에서 맨 처음 나오는 규칙 한 줄 2) 사용할 수 있는 스킬 이름 전부
```

두 앱이 같은 규칙과 같은 스킬 이름을 말하면 연결이 끝난 겁니다.

<br>

## 무엇이 이어지나

| 무엇 | 클로드가 읽는 곳 | 코덱스가 읽는 곳 | 잇는 방식 |
|---|---|---|---|
| 스킬 | `~/.claude/skills` | `~/.agents/skills` | 폴더 링크, 진짜 폴더가 있는 쪽이 원본 |
| 전역 규칙 | `~/.claude/CLAUDE.md` | `~/.codex/AGENTS.md` | `CLAUDE.md`가 `@~/.codex/AGENTS.md`를 불러옴 |
| 프로젝트 규칙 | `프로젝트/CLAUDE.md` | `프로젝트/AGENTS.md` | 같은 폴더에 나란히, `@AGENTS.md` |
| 프로젝트 스킬 | `.claude/skills` | `.agents/skills` | 상대 경로 링크(저장소째 옮겨도 유지) |

<br>

## 알아 둘 것

- **모델 차이는 그대로입니다.** 코덱스는 GPT 모델로 돕니다. 이 스킬이 맞추는 건 스킬과 규칙까지입니다.
- **대화 기록이나 기억은 나누지 않습니다.** 하던 일을 다른 앱에 넘겨주는 기능도 아닙니다.
- **claude.ai 웹 채팅용 스킬이 아닙니다.** 내 컴퓨터에 설치한 클로드(터미널, 데스크톱 앱의 코드 탭)에서 돌아갑니다. 앱 채팅 스킬, 클라우드 세션, 데스크톱 코워크 세션에는 닿지 않습니다.
- **맥·리눅스(WSL 포함)만 지원합니다.** 윈도우는 링크에 관리자 권한이 필요해서 아직 지원하지 않습니다.
- 점검이 잡아내는 경우(규칙 크기 한도, `AGENTS.override.md`, 상위 폴더 규칙, `name`·`description` 누락, 클로드 전용 도구를 쓰는 스킬 등)와 각각의 처방은 [SKILL.md](claude-codex-sync/SKILL.md) 「알고 쓸 조건과 한계」 표에 정리해 두었습니다.

<br>

## 되돌리기

```bash
bash ~/.claude/skills/claude-codex-sync/scripts/ccsync.sh undo
```

이 스킬이 건 링크만 걷어 내고, `CLAUDE.md`는 불러오기 줄 자리에 지금의 `AGENTS.md` 내용을 풀어 넣어 원래 모양으로 돌려놓습니다. 설치한 뒤에 고친 내용도 그대로 남습니다. 되돌리다 실패한 항목은 기록에 남아 있어서, 원인을 고친 뒤 다시 돌리면 이어서 처리합니다.

종료 코드는 `0` 문제 없음 · `1` 손볼 곳 있음(⚠️) · `2` 쓰기·복원 실패(❌)입니다.

<br>

## 검증

```bash
bash ~/.claude/skills/claude-codex-sync/scripts/test_ccsync.sh
```

가짜 홈 폴더에서 설치 → 재설치 → 점검 → 되돌리기와 예외 경우들을 돌려 보고 `PASS`를 냅니다. 실제 설정은 건드리지 않습니다. 배포 전 외부 검수 4회에서 나온 15건을 모두 이 테스트에 넣었고, 맥 기본 bash(3.2)에서 통과합니다.

<br>

## 만든 곳

[프롬왓 (@prompt_what)](https://www.instagram.com/prompt_what/). 클로드와 코덱스를 매일 같이 쓰면서 겪은 문제(복사해 둔 스킬이 옛 버전으로 덮이는 일)를 막으려고 만들었습니다.

버그나 안 맞는 경우가 있으면 [이슈](../../issues)로 알려 주세요.

<br>

## 라이선스

[MIT](LICENSE)
