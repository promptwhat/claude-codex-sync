#!/usr/bin/env bash
# ccsync 회귀 테스트 — 가짜 HOME에서만 돈다(진짜 설정은 안 건드림). 통과하면 PASS.
set -u
S="$(cd "$(dirname "$0")" && pwd)/ccsync.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; unset CLAUDE_CONFIG_DIR CODEX_HOME
fail() { echo "FAIL: $*"; exit 1; }
run() { "$BASH" "$S" "$@" > "$T/out" 2>&1; }

mk() { mkdir -p "$1"; printf -- '---\n%s\ndescription: test\n---\n%s\n' "$2" "${3:-본문}" > "$1/SKILL.md"; }
mk "$HOME/.claude/skills/alpha" "name: alpha"
mk "$HOME/.claude/skills/no name" "" "mcp__chrome 쓰는 단계"     # 공백 이름 + name 없음 + 클로드 도구
mk "$HOME/.agents/skills/gamma" "name: gamma"                     # 코덱스에만 있는 스킬
mk "$HOME/.claude/skills/both" "name: both"; mk "$HOME/.agents/skills/both" "name: both"   # 양쪽 진짜 폴더
mkdir -p "$HOME/.codex"
printf '# 내 규칙\n- 한국어로 답한다\n' > "$HOME/.claude/CLAUDE.md"
cp "$HOME/.claude/CLAUDE.md" "$T/orig"

P="$T/proj"; mkdir -p "$P"; printf '# 프로젝트 규칙\n' > "$P/CLAUDE.md"; mk "$P/.claude/skills/ps" "name: ps"

# 1) install
run install --project "$P"; [ $? -eq 1 ] || fail "install 종료 코드(겹침이 있으니 1)"
[ "$HOME/.agents/skills/alpha" -ef "$HOME/.claude/skills/alpha" ] || fail "alpha 링크"
[ "$HOME/.agents/skills/no name" -ef "$HOME/.claude/skills/no name" ] || fail "공백 이름 링크"
[ "$HOME/.claude/skills/gamma" -ef "$HOME/.agents/skills/gamma" ] || fail "코덱스→클로드 링크"
[ ! -L "$HOME/.agents/skills/both" ] && [ ! -L "$HOME/.claude/skills/both" ] || fail "겹침 폴더를 건드림"
grep -q "이름 겹침: both" "$T/out" || fail "겹침 경고 없음"
cmp -s "$HOME/.codex/AGENTS.md" "$T/orig" || fail "AGENTS.md 내용"
cmp -s "$HOME/.claude/CLAUDE.md.ccsync-bak" "$T/orig" || fail "백업"
grep -qxF '@~/.codex/AGENTS.md' "$HOME/.claude/CLAUDE.md" || fail "전역 불러오기 줄"
grep -qxF '@AGENTS.md' "$P/CLAUDE.md" || fail "프로젝트 불러오기 줄"
[ "$P/.agents/skills/ps" -ef "$P/.claude/skills/ps" ] || fail "프로젝트 스킬 링크"
[ "$(readlink "$P/.agents/skills/ps")" = "../../.claude/skills/ps" ] || fail "프로젝트 링크가 상대 경로가 아님"

# 2) 다시 install = 아무것도 안 바뀜
cp "$HOME/.claude/CLAUDE.md" "$T/after1"
run install --project "$P"; [ $? -le 1 ] || fail "재설치"
cmp -s "$HOME/.claude/CLAUDE.md" "$T/after1" || fail "재설치가 CLAUDE.md를 바꿈"
grep -q "🔗" "$T/out" && fail "재설치가 링크를 또 만듦"

# 3) check
run check --project "$P"
grep -q "name 줄이 없어요" "$T/out" || fail "name 누락 못 잡음"
grep -q "클로드 쪽 도구" "$T/out" || fail "클로드 전용 도구 못 잡음"
grep -q "이름 겹침: both" "$T/out" || fail "check 겹침"
grep -q "✅ 규칙: 연결됨" "$T/out" || fail "check 규칙 연결"

# 3-1) 크기 초과 + 끊긴 링크 + 같은 name 사본
head -c 40000 /dev/zero | tr '\0' 'a' >> "$P/AGENTS.md"
head -c 40000 /dev/zero | tr '\0' 'a' >> "$HOME/.codex/AGENTS.md"
mk "$HOME/.agents/skills/alpha.prev" "name: alpha"
ln -s "$T/없는곳" "$HOME/.agents/skills/dead"
run check --project "$P"
grep -q "프로젝트 규칙 .*코덱스 한도 32768" "$T/out" || fail "프로젝트 크기 초과 못 잡음"
grep -q "ℹ️  전역 규칙이" "$T/out" || fail "전역 크기 참고 없음"
grep -q "끊긴 링크" "$T/out" || fail "끊긴 링크 못 잡음"
grep -q "같은 name 스킬이 여러 개" "$T/out" || fail "중복 name 못 잡음"
printf 'project_doc_max_bytes = 65536\n' > "$HOME/.codex/config.toml"
run check; grep -q "코덱스 한도 65536" "$T/out" || grep -q "/65536바이트" "$T/out" || fail "config 한도 못 읽음"
rm -rf "$HOME/.agents/skills/alpha.prev" "$HOME/.agents/skills/dead"

# 4) 서로 다른 두 규칙 = 손대지 않음
Q="$T/q"; mkdir -p "$Q"; echo A > "$Q/CLAUDE.md"; echo B > "$Q/AGENTS.md"
run install --project "$Q"; grep -q "내용이 달라요" "$T/out" || fail "충돌 경고"
[ "$(cat "$Q/CLAUDE.md")" = A ] || fail "충돌인데 CLAUDE.md를 바꿈"

# 5) @불러오기가 든 CLAUDE.md = 옮기지 않음
R="$T/r"; mkdir -p "$R"; printf '@docs/x.md\n' > "$R/CLAUDE.md"
run install --project "$R"; grep -q "다른 파일을 불러오고 있어" "$T/out" || fail "@불러오기 경고"
[ ! -e "$R/AGENTS.md" ] || fail "@불러오기인데 옮김"

# 6) undo = 링크만 걷고, 그동안 고친 AGENTS.md 내용으로 CLAUDE.md 복원
printf '# 내 규칙\n- 한국어로 답한다\n- 새로 추가\n' > "$HOME/.codex/AGENTS.md"
printf '%s\n' '- 클로드 전용' >> "$HOME/.claude/CLAUDE.md"
run undo || { cat "$T/out"; fail "undo"; }
[ ! -L "$HOME/.agents/skills/alpha" ] && [ -d "$HOME/.claude/skills/alpha" ] || fail "undo 링크/원본"
[ ! -L "$HOME/.claude/skills/gamma" ] && [ -d "$HOME/.agents/skills/gamma" ] || fail "undo 반대쪽"
printf '# 내 규칙\n- 한국어로 답한다\n- 새로 추가\n- 클로드 전용\n' | cmp -s - "$HOME/.claude/CLAUDE.md" || { cat "$HOME/.claude/CLAUDE.md"; fail "undo 규칙 복원"; }
[ -f "$HOME/.codex/AGENTS.md" ] || fail "undo가 AGENTS.md를 지움"
[ -d "$HOME/.claude/skills/both" ] && [ -d "$HOME/.agents/skills/both" ] || fail "undo가 진짜 폴더를 지움"

# 7) 검증에서 나온 경우들 — 새 가짜 HOME
export HOME="$T/home2"; mkdir -p "$HOME/.codex" "$HOME/dot" "$HOME/.claude"
printf 'x\n' > "$HOME/dot/CLAUDE.md"; ln -s "$HOME/dot/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
run install; grep -q "링크라서 건드리지 않았어요" "$T/out" || fail "링크 CLAUDE.md 경고"
[ "$(cat "$HOME/dot/CLAUDE.md")" = x ] || fail "링크 너머 파일을 바꿈"
rm "$HOME/.claude/CLAUDE.md"

mkdir -p "$HOME/.agents/skills"; ln -s "$HOME/.agents/skills" "$HOME/.claude/skills"   # 폴더째 링크
mk "$HOME/.agents/skills/s1" "name: s1"
run install; grep -q "이름 겹침" "$T/out" && fail "폴더째 링크인데 겹침 경고"
rm "$HOME/.claude/skills"; mkdir -p "$HOME/.claude/skills"

mkdir -p "$HOME/.claude/skills/crlf"; printf -- '---\r\nname: crlf\r\ndescription: t\r\n---\r\n' > "$HOME/.claude/skills/crlf/SKILL.md"
printf '@handle 로 연락\n' > "$HOME/.claude/CLAUDE.md"           # 불러오기 아닌 @ 줄
run install; grep -q "다른 파일을 불러오고 있어" "$T/out" && fail "@handle을 불러오기로 오판"
grep -qxF '@~/.codex/AGENTS.md' "$HOME/.claude/CLAUDE.md" || fail "@handle 파일 연결 안 됨"
run check; grep -q "crlf: SKILL.md 머리말에 name" "$T/out" && fail "CRLF name 오판"

# 내가 바꿔 단 링크는 undo가 안 지움 + AGENTS.md가 사라져도 백업으로 되돌림
rm "$HOME/.agents/skills/crlf"; mkdir -p "$HOME/mine"; ln -s "$HOME/mine" "$HOME/.agents/skills/crlf"
rm "$HOME/.codex/AGENTS.md"
run undo
[ -L "$HOME/.agents/skills/crlf" ] || fail "사용자 링크를 undo가 지움"
[ "$(cat "$HOME/.claude/CLAUDE.md")" = '@handle 로 연락' ] || { cat "$HOME/.claude/CLAUDE.md"; fail "AGENTS.md 없을 때 백업 복원"; }

# 빈 CLAUDE.md + 내용 있는 AGENTS.md = 연결
export HOME="$T/home3"; mkdir -p "$HOME/.codex" "$HOME/.claude"; : > "$HOME/.claude/CLAUDE.md"; echo B > "$HOME/.codex/AGENTS.md"
run install; grep -qxF '@~/.codex/AGENTS.md' "$HOME/.claude/CLAUDE.md" || fail "빈 CLAUDE.md 연결"
[ "$(cat "$HOME/.codex/AGENTS.md")" = B ] || fail "AGENTS.md를 바꿈"

# 상대 경로 CLAUDE_CONFIG_DIR
export HOME="$T/home4"; mkdir -p "$HOME/rel/skills/r1"; printf -- '---\nname: r1\n---\n' > "$HOME/rel/skills/r1/SKILL.md"
( cd "$HOME" && CLAUDE_CONFIG_DIR=rel "$BASH" "$S" install > "$T/out" 2>&1 )
[ -f "$HOME/.agents/skills/r1/SKILL.md" ] || fail "상대 경로 설정에서 링크가 끊김"

# 8) 2차 검수 지적 5종
export HOME="$T/home5"; mkdir -p "$HOME/.codex" "$HOME/.claude"
R2="$T/r2"; mkdir -p "$R2/docs"
printf '규칙\n' > "$R2/docs/my rules.md"; printf '규칙\n' > "$R2/docs/rules.md"
printf '@docs/my\\ rules.md\n' > "$R2/CLAUDE.md"                     # 공백 경로 불러오기
run install --project "$R2"; grep -q "다른 파일을 불러오고 있어" "$T/out" || fail "공백 경로 불러오기 놓침"
[ ! -e "$R2/AGENTS.md" ] || fail "공백 경로 불러오기인데 옮김"
printf '규칙은 @docs/rules.md 참고\n' > "$R2/CLAUDE.md"               # 문장 안 불러오기
run install --project "$R2"; grep -q "다른 파일을 불러오고 있어" "$T/out" || fail "문장 안 불러오기 놓침"
[ ! -e "$R2/AGENTS.md" ] || fail "문장 안 불러오기인데 옮김"
printf '예시는 `@docs/rules.md` 처럼 쓴다\n' > "$R2/CLAUDE.md"         # 코드 표시 안은 불러오기 아님
run install --project "$R2"; grep -qxF '@AGENTS.md' "$R2/CLAUDE.md" || fail "코드 표시 안 @를 불러오기로 오판"

export HOME="$T/home6"; mkdir -p "$HOME/.claude" "$HOME/.codex/ccsync-manifest.txt"   # 기록 자리를 폴더로 막음
printf 'x\n' > "$HOME/.claude/CLAUDE.md"
run install; [ $? -eq 2 ] || fail "기록 실패인데 종료 코드가 2가 아님"
[ "$(cat "$HOME/.claude/CLAUDE.md")" = x ] || fail "기록 실패인데 CLAUDE.md를 바꿈"
rmdir "$HOME/.codex/ccsync-manifest.txt"
run install; [ $? -eq 0 ] || fail "막힘 푼 뒤 설치"
mkdir "$HOME/.claude/CLAUDE.md.ccsync-tmp"                                           # 되돌리기 임시 자리를 막음
run undo; [ $? -eq 2 ] || fail "되돌리기 실패인데 종료 코드가 2가 아님"
grep -q "^rules" "$HOME/.codex/ccsync-manifest.txt" || fail "되돌리기 실패인데 기록을 치움"
rmdir "$HOME/.claude/CLAUDE.md.ccsync-tmp"
run undo; [ $? -eq 0 ] || fail "막힘 푼 뒤 되돌리기"
[ "$(cat "$HOME/.claude/CLAUDE.md")" = x ] || fail "다시 되돌리기 결과"

O="$T/o"; mkdir -p "$O"; printf '한국어로\n' > "$O/CLAUDE.md"                       # 프로젝트 override
export HOME="$T/home7"; mkdir -p "$HOME/.codex"
run install --project "$O"; printf 'English only\n' > "$O/AGENTS.override.md"
run check --project "$O"; [ $? -eq 1 ] || fail "override 있는데 check 통과"
grep -q "AGENTS.override.md 가 있어서 코덱스는 이 폴더에서" "$T/out" || fail "override 경고 없음"

export HOME="$T/home8"; mkdir -p "$HOME/.codex"                                    # 끊긴 링크: 우리 것만 정리
mk "$HOME/.claude/skills/gone" "name: gone"; run install
mv "$HOME/.claude/skills/gone" "$T/gone-moved"
ln -s "$T/어디에도없음" "$HOME/.agents/skills/usermade"
run check; grep -q "gone (원본을 옮겼거나 지웠어요. 이 도구가 건 링크라" "$T/out" || fail "우리 끊긴 링크 안내"
grep -q "usermade (이 도구가 건 링크가 아니라" "$T/out" || fail "사용자 끊긴 링크 안내"
run install
[ ! -L "$HOME/.agents/skills/gone" ] || fail "우리 끊긴 링크가 install 뒤에도 남음"
[ -L "$HOME/.agents/skills/usermade" ] || fail "사용자 링크를 지움"

# 9) 3차 검수 지적 5종
export HOME="$T/h9"; mkdir -p "$HOME/.codex"                                       # 사용자 끊긴 링크 + 같은 이름 원본
mk "$HOME/.claude/skills/alpha" "name: alpha"
mkdir -p "$HOME/.agents/skills"; ln -s "$T/사용자대상" "$HOME/.agents/skills/alpha"
run install
[ "$(readlink "$HOME/.agents/skills/alpha")" = "$T/사용자대상" ] || fail "사용자 끊긴 링크를 덮어씀"
grep -q "끊긴 링크인데 이 도구가 건 게 아니라" "$T/out" || fail "사용자 끊긴 링크 경고 없음"

export HOME="$T/h10"; mkdir -p "$HOME/.claude" "$HOME/.codex"                       # 코드블록 속 예시는 연결 아님
printf '# 규칙\n- 한국어\n```\n@~/.codex/AGENTS.md\n```\n' > "$HOME/.claude/CLAUDE.md"; echo 'English only' > "$HOME/.codex/AGENTS.md"
run check; [ $? -eq 1 ] || fail "코드블록 예시를 연결로 판정"
grep -q "따로 놀아요" "$T/out" || fail "코드블록 예시 경고 없음"
run install; grep -q "내용이 달라요" "$T/out" || fail "코드블록 예시인데 install이 연결됨으로 넘어감"

G="$T/g"; mkdir -p "$G/sub"; git -C "$G" init -q 2>/dev/null || mkdir -p "$G/.git"       # 상위 폴더 override
printf '@AGENTS.md\n' > "$G/CLAUDE.md"; echo '한국어' > "$G/AGENTS.md"; echo 'English only' > "$G/AGENTS.override.md"
echo '하위 규칙' > "$G/sub/CLAUDE.md"
export HOME="$T/h11"; mkdir -p "$HOME/.codex"
run install --project "$G/sub"; run check --project "$G/sub"; [ $? -eq 1 ] || fail "상위 override 놓침"
grep -q "상위 폴더 .*AGENTS.override.md" "$T/out" || fail "상위 override 경고 없음"

export HOME="$T/h12"; mkdir -p "$HOME/.claude" "$HOME/.codex"                       # 백업 실패 = 2
echo x > "$HOME/.claude/CLAUDE.md"; ln -s "$T/없는부모/파일" "$HOME/.claude/CLAUDE.md.ccsync-bak"
run install; [ $? -eq 2 ] || fail "백업 실패 종료 코드가 2가 아님"
[ "$(cat "$HOME/.claude/CLAUDE.md")" = x ] || fail "백업 실패인데 CLAUDE.md를 바꿈"

export HOME="$T/h13"; mkdir -p "$HOME/.codex" "$HOME/.claude/skills/nodesc"              # description 없음
printf -- '---\nname: nodesc\n---\n본문\n' > "$HOME/.claude/skills/nodesc/SKILL.md"
run install; run check; [ $? -eq 1 ] || fail "description 없는데 통과"
grep -q "nodesc: SKILL.md 머리말에 description" "$T/out" || fail "description 경고 없음"

# 10) 4차 검수 지적 3종
export HOME="$T/h14"; mkdir -p "$HOME/.claude" "$HOME/.codex"                      # 문장 안으로 옮긴 불러오기 되돌리기
echo 'original rule' > "$HOME/.claude/CLAUDE.md"; run install
CM="$HOME/.claude/CLAUDE.md"
awk '{ if ($0 == "@~/.codex/AGENTS.md") print "共通規則 @~/.codex/AGENTS.md"; else print }' "$CM" > "$CM.t" && mv "$CM.t" "$CM"
run undo; [ $? -eq 2 ] || fail "문장 안 불러오기 되돌리기를 성공으로 보고"
grep -q "^rules" "$HOME/.codex/ccsync-manifest.txt" || fail "되돌리기 실패인데 기록을 치움"
grep -q "共通規則 @~/.codex/AGENTS.md" "$CM" || fail "실패인데 파일을 바꿈"

export HOME="$T/h15"; mkdir -p "$HOME/.codex"                                      # 코덱스→클로드 연결 충돌 경고
mk "$HOME/.agents/skills/gamma" "name: gamma"
mkdir -p "$HOME/.claude/skills"; ln -s "$T/사용자대상2" "$HOME/.claude/skills/gamma"
run install; [ $? -eq 1 ] || fail "코덱스→클로드 충돌인데 문제 0개"
grep -q "gamma 는 끊긴 링크인데" "$T/out" || fail "코덱스→클로드 충돌 경고 없음"
[ "$(readlink "$HOME/.claude/skills/gamma")" = "$T/사용자대상2" ] || fail "사용자 링크를 바꿈"

G2="$T/g2"; mkdir -p "$G2/sub"; git -C "$G2" init -q 2>/dev/null || mkdir -p "$G2/.git"    # 상위에 CLAUDE.md만
echo '한국어로 답한다' > "$G2/CLAUDE.md"
printf '@AGENTS.md\n' > "$G2/sub/CLAUDE.md"; echo '짧게 답한다' > "$G2/sub/AGENTS.md"
export HOME="$T/h16"; mkdir -p "$HOME/.codex"
run check --project "$G2/sub"; [ $? -eq 1 ] || fail "상위 CLAUDE.md만 있는데 통과"
grep -q "CLAUDE.md만 있어요. 이 규칙은 클로드에만" "$T/out" || fail "상위 CLAUDE.md만 경고 없음"
rm "$G2/CLAUDE.md"; echo '한국어로 답한다' > "$G2/AGENTS.md"
run check --project "$G2/sub"; grep -q "AGENTS.md만 있어요. 아래쪽에 CLAUDE.md가 있으면" "$T/out" || fail "상위 AGENTS.md만 경고 없음"

# 11) 5차 검수 지적 2종 + CLAUDE.local.md 정책
G3="$T/g3"; mkdir -p "$G3/sub"; git -C "$G3" init -q 2>/dev/null || mkdir -p "$G3/.git"   # 상위 CLAUDE.md + 하위 AGENTS.md만
printf '@AGENTS.md\n' > "$G3/CLAUDE.md"; echo '짧게 답한다' > "$G3/AGENTS.md"; echo 'English only' > "$G3/sub/AGENTS.md"
export HOME="$T/h17"; mkdir -p "$HOME/.codex"
run check --project "$G3/sub"; [ $? -eq 1 ] || fail "상위 CLAUDE.md가 있는데 하위 AGENTS.md 직접 로드로 판정"
grep -q "클로드는 이 AGENTS.md를 직접 읽지 않아요" "$T/out" || fail "하위 AGENTS.md 경고 없음"

G4="$T/g4"; mkdir -p "$G4/sub" "$G4/.claude"; git -C "$G4" init -q 2>/dev/null || mkdir -p "$G4/.git"   # 상위 .claude/CLAUDE.md만
echo '한국어로 답한다' > "$G4/.claude/CLAUDE.md"
printf '@AGENTS.md\n' > "$G4/sub/CLAUDE.md"; echo '짧게 답한다' > "$G4/sub/AGENTS.md"
export HOME="$T/h18"; mkdir -p "$HOME/.codex"
run check --project "$G4/sub"; [ $? -eq 1 ] || fail "상위 .claude/CLAUDE.md만 있는데 통과"
grep -q ".claude/CLAUDE.md 규칙은 클로드에만" "$T/out" || fail "상위 .claude/CLAUDE.md 경고 없음"
echo '짧게' > "$G4/AGENTS.md"; printf '@../AGENTS.md\n' > "$G4/.claude/CLAUDE.md"                  # 제대로 이어 두면 통과
run check --project "$G4/sub"; grep -q ".claude/CLAUDE.md 규칙은 클로드에만" "$T/out" && fail "이어 둔 .claude/CLAUDE.md를 경고"

echo '내 취향' > "$G4/sub/CLAUDE.local.md"                                                      # 개인용은 참고만
run check --project "$G4/sub"; grep -q "CLAUDE.local.md 는 개인용" "$T/out" || fail "CLAUDE.local.md 참고 없음"

echo PASS
