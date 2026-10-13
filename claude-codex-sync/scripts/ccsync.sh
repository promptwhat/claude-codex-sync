#!/usr/bin/env bash
# ccsync — Claude Code ↔ Codex 스킬·규칙 공유
#   install [--project DIR]  스킬은 링크로 잇고, 규칙은 AGENTS.md 하나를 원본으로 만든다
#   check   [--project DIR]  읽기만 한다. 어긋난 곳을 보여 준다
#   undo                     install이 만든 링크·불러오기를 전부 걷어 낸다(원본은 그대로)
# 원칙: 진짜 폴더·파일은 지우지 않는다. 바꾸는 파일(CLAUDE.md)은 먼저 백업한다.
# 종료 코드: 0 = 문제 없음 · 1 = 손볼 곳 있음(⚠️) · 2 = 쓰기·복원 실패(❌)
set -u

CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CODEX_DIR="${CODEX_HOME:-$HOME/.codex}"
abs() { case "$1" in /*) printf '%s' "$1" ;; *) printf '%s/%s' "$PWD" "$1" ;; esac; }
CLAUDE_DIR=$(abs "$CLAUDE_DIR")
CODEX_DIR=$(abs "$CODEX_DIR")
AGENTS_SKILLS="$HOME/.agents/skills"
MANIFEST="$CODEX_DIR/ccsync-manifest.txt"
IGNORE="$CLAUDE_DIR/ccsync-ignore"
MARK='<!-- ccsync: 아래 줄이 AGENTS.md를 불러옵니다. 공통 규칙은 AGENTS.md에, 클로드 전용 규칙은 이 줄 아래에 쓰세요 -->'
CLAUDE_ONLY='mcp__|SendUserFile|AskUserQuestion|TodoWrite|ExitPlanMode|allowed-tools'

problems=0
notes=0
errors=0
WARNED=""   # 첫 방향에서 이미 경고한 스킬 이름(줄마다 하나)
PASS2=0
short() { local m="$*"; printf '%s' "${m//$HOME/~}"; }   # 화면에는 홈 폴더를 ~로
say()  { printf '%s\n' "$(short "$*")"; }
warn() { printf '⚠️  %s\n' "$(short "$*")"; problems=$((problems+1)); }
note() { printf 'ℹ️  %s\n' "$(short "$*")"; notes=$((notes+1)); }
err()  { printf '❌ %s\n' "$(short "$*")"; errors=$((errors+1)); }
finish() { [ "$errors" -gt 0 ] && exit 2; [ "$problems" -gt 0 ] && exit 1; exit 0; }

usage() { say "사용법: ccsync.sh install|check|undo [--project 폴더]"; exit 2; }

# @불러오기 경로: 공백 앞에 \ (따옴표로 감싸면 불러오지 않는다)
esc() { printf '%s' "$1" | sed 's/ /\\ /g'; }

# SKILL.md 머리말(첫 줄 ---부터 다음 ---까지)의 한 칸 값. 빈 값이면 아무것도 안 나온다
fm_field() {
  awk -v q="'" -v k="$2" '{ sub(/\r$/, "") }
    NR==1 { if ($0 != "---") exit; next }
    /^---$/ { exit }
    index($0, k ":") == 1 { v = substr($0, length(k) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
      gsub(/"/, "", v); gsub(q, "", v); if (v != "" && v != "|" && v != ">") print v; else if (v == "|" || v == ">") print "(여러 줄)"; exit }' "$1"
}
fm_name() { fm_field "$1" name; }

ignored() { [ -f "$IGNORE" ] && grep -qxF "$1" "$IGNORE"; }
size_of() { wc -c < "$1" | tr -d ' '; }

record() { mkdir -p "$CODEX_DIR" 2>/dev/null && printf '%s\n' "$1" >> "$MANIFEST" 2>/dev/null; }
can_record() { mkdir -p "$CODEX_DIR" 2>/dev/null && { [ ! -e "$MANIFEST" ] || [ -f "$MANIFEST" ]; } && : >> "$MANIFEST" 2>/dev/null; }
# 이 도구가 건 링크인가: 기록에 같은 자리·같은 대상으로 남아 있을 때만
ours() { [ -f "$MANIFEST" ] && [ -L "$1" ] && awk -F'\t' -v p="$1" -v t="$(readlink "$1")" '$1=="link" && $2==p && $3==t {f=1} END {exit !f}' "$MANIFEST"; }

# CLAUDE.md 안의 @불러오기(코드블록·`코드` 밖, 문장 중간·"\ " 포함)
raw_imports() { # 클로드가 실제로 불러오는 @토큰만(코드블록·`코드` 안은 제외)
  awk '{ t=$0; sub(/^[ \t]+/, "", t) }
       t ~ /^(```|~~~)/ { fence = !fence; next }
       fence { next }
       { s = $0; gsub(/`[^`]*`/, "", s)
         while (match(s, /(^|[ \t(])@([^ \t\\]|\\ )+/)) {
           tok = substr(s, RSTART, RLENGTH); sub(/^[ \t(]/, "", tok); sub(/[),.;:]+$/, "", tok)
           print tok; s = substr(s, RSTART + RLENGTH) } }' "$1"
}
linked() { [ -f "$1" ] && raw_imports "$1" | grep -qxF "$2"; }   # <CLAUDE.md> <불러오기 줄>

imports_in() {
  local f="$1" base tok p
  base=$(dirname "$f")
  raw_imports "$f" |
  while IFS= read -r tok; do
    p="${tok#@}"; p="${p//\\ / }"
    case "$p" in '~/'*) p="$HOME/${p#\~/}" ;; /*) ;; *) p="$base/$p" ;; esac
    # 가리키는 파일이 있거나, 경로처럼 생겼으면(/ · ~ · 확장자) 불러오기로 본다. @계정명 같은 말은 통과
    case "${tok#@}" in */*|'~'*|*.[A-Za-z0-9]*) printf '%s\n' "$tok"; continue ;; esac
    [ -e "$p" ] && printf '%s\n' "$tok"
  done
}

# ── 규칙 ────────────────────────────────────────────
# link_rules <CLAUDE.md 경로> <AGENTS.md 경로> <불러오기 줄>
link_rules() {
  local cm="$1" am="$2" imp="$3" bak=""
  if [ -e "$cm" ] && [ -e "$am" ] && [ "$cm" -ef "$am" ]; then
    say "✅ 규칙: $cm 와 $am 이 이미 같은 파일"; return
  fi
  if linked "$cm" "$imp"; then
    say "✅ 규칙: 이미 연결됨 ($cm)"; return
  fi
  if [ -L "$cm" ]; then
    warn "$cm 이 링크라서 건드리지 않았어요(링크 너머 파일이 바뀌어요). 링크를 풀어 실제 파일로 둔 뒤 다시 install 하세요"; return
  fi
  if [ ! -f "$cm" ] && [ ! -s "$am" ]; then
    say "· 규칙 파일 없음, 건너뜀 ($cm)"; return
  fi
  local found=""
  [ -f "$cm" ] && found=$(imports_in "$cm" | tr '\n' ' ' | sed 's/ $//')
  if [ -n "$found" ]; then
    warn "$cm 이 다른 파일을 불러오고 있어 옮기지 않았어요($found). 옮기면 경로 기준이 바뀌고, 코덱스는 @불러오기를 못 읽어요. 불러온 내용을 본문으로 풀어 쓴 뒤 다시 install 하세요"
    return
  fi
  if [ -s "$cm" ] && [ -s "$am" ] && ! cmp -s "$cm" "$am"; then
    warn "$cm 와 $am 내용이 달라요. AGENTS.md 하나로 합친 뒤 다시 install 하세요(아무것도 안 바꿨어요)"
    return
  fi
  if [ -f "$cm" ]; then
    bak="$cm.ccsync-bak"
    [ -e "$bak" ] && bak="$cm.ccsync-bak.$(date +%Y%m%d%H%M%S)"
    cp -p "$cm" "$bak" 2>/dev/null || { err "백업 실패: $bak (아무것도 안 바꿨어요)"; return; }
    say "📦 백업: $bak"
    if [ ! -s "$am" ]; then
      mkdir -p "$(dirname "$am")" 2>/dev/null && cp "$cm" "$am" 2>/dev/null ||
        { err "복사 실패: $am (CLAUDE.md는 안 바꿨어요)"; return; }
    fi
  fi
  record "$(printf 'rules\t%s\t%s\t%s\t%s' "$cm" "$am" "$imp" "$bak")" ||
    { err "기록 저장 실패: $MANIFEST. $cm 은 바꾸지 않았어요"; return; }
  mkdir -p "$(dirname "$cm")" && printf '%s\n%s\n' "$MARK" "$imp" > "$cm" ||
    { err "쓰기 실패: $cm (백업 = $bak)"; return; }
  say "✅ 규칙: 원본 $am ← 불러오기 $cm"
}

check_rules() { # <CLAUDE.md> <AGENTS.md> <불러오기 줄> [project]
  local cm="$1" am="$2" imp="$3" scope="${4:-}"
  [ -n "$scope" ] && [ -s "$(dirname "$am")/AGENTS.override.md" ] &&
    warn "$(dirname "$am")/AGENTS.override.md 가 있어서 코덱스는 이 폴더에서 AGENTS.md 대신 그 파일을 읽어요. 클로드가 불러오는 AGENTS.md와 규칙이 달라져요"
  if [ -e "$cm" ] && [ -e "$am" ] && [ "$cm" -ef "$am" ]; then
    say "✅ 규칙: 같은 파일(링크). 데스크톱 코워크 세션은 링크된 전역 CLAUDE.md를 건너뛰어요"
  elif linked "$cm" "$imp"; then
    if [ -f "$am" ]; then say "✅ 규칙: 연결됨 ($cm → $am)"; else warn "규칙: $cm 이 불러오는 $am 이 없어요"; fi
  elif [ -f "$cm" ] && [ -f "$am" ]; then
    warn "규칙: $cm 와 $am 이 따로 놀아요. 둘 다 있으면 클로드 코드는 기본 설정에서 CLAUDE.md만 읽고, 코덱스는 AGENTS.md만 읽어요"
  elif [ -f "$cm" ]; then
    warn "규칙: $cm 만 있어요. 코덱스는 이 규칙을 못 읽어요"
  elif [ -f "$am" ] && [ -n "$scope" ] && claude_in_chain; then
    warn "규칙: $am 만 있어요. 이 폴더나 상위 폴더에 클로드 규칙 파일(CLAUDE.md·.claude/CLAUDE.md·CLAUDE.local.md)이 있어서 클로드는 이 AGENTS.md를 직접 읽지 않아요(install --project 로 불러오기 줄을 만드세요)"
  elif [ -f "$am" ] && [ -n "$scope" ]; then
    note "규칙: $am 만 있어요. 클로드 코드 v2.1.277 이상은 이 경우 AGENTS.md를 직접 읽어요. 낮은 버전·코워크 세션까지 확실히 하려면 install로 불러오기 줄을 만드세요"
  elif [ -f "$am" ]; then
    warn "규칙: $am 만 있어요. 클로드 코드는 이 전역 파일을 읽지 않아요(install로 불러오기를 만드세요)"
  fi
}

chain_dirs() { # 코덱스가 규칙을 찾는 폴더들: 저장소 맨 위부터 그 폴더까지
  local root d rest
  root=$(git -C "$PROJECT" rev-parse --show-toplevel 2>/dev/null) || root="$PROJECT"
  case "$PROJECT" in "$root"|"$root"/*) ;; *) root="$PROJECT" ;; esac
  d="$root"; rest="${PROJECT#"$root"}"
  while :; do
    printf '%s\n' "$d"
    rest="${rest#/}"; [ -z "$rest" ] && break
    d="$d/${rest%%/*}"; case "$rest" in */*) rest="${rest#*/}" ;; *) rest="" ;; esac
  done
}

claude_in_chain() { # 경로 어딘가에 클로드 규칙 파일이 있나(있으면 클로드는 상위 AGENTS.md를 안 읽는다)
  local d
  while IFS= read -r d; do
    { [ -f "$d/CLAUDE.md" ] || [ -f "$d/.claude/CLAUDE.md" ] || [ -f "$d/CLAUDE.local.md" ]; } && return 0
  done <<EOF
$(chain_dirs)
EOF
  return 1
}

check_chain() { # 상위 폴더의 override·따로 노는 규칙 (지정 폴더 자체는 check_rules가 본다)
  local d cl=1
  claude_in_chain && cl=0
  while IFS= read -r d; do
    [ -f "$d/CLAUDE.local.md" ] && note "$d/CLAUDE.local.md 는 개인용 클로드 규칙이라 코덱스에 넘기지 않아요. 둘 다 써야 하는 규칙이면 AGENTS.md로 옮기세요"
    if [ "$d" = "$PROJECT" ]; then   # 대상 폴더의 CLAUDE.md는 check_rules가 본다
      [ ! -f "$d/CLAUDE.md" ] && [ -f "$d/.claude/CLAUDE.md" ] &&
        warn "$d/.claude/CLAUDE.md 는 자동으로 안 다뤄요. 이 규칙은 클로드에만 적용돼요(맨 위 CLAUDE.md로 옮긴 뒤 install --project 하세요)"
      continue
    fi
    if [ ! -f "$d/CLAUDE.md" ] && [ -f "$d/.claude/CLAUDE.md" ]; then
      if [ -f "$d/AGENTS.md" ] && linked "$d/.claude/CLAUDE.md" "@../AGENTS.md"; then :
      else warn "상위 폴더 $d/.claude/CLAUDE.md 규칙은 클로드에만 적용되고 코덱스는 못 읽어요(맨 위 CLAUDE.md로 옮긴 뒤 그 폴더도 install --project 하세요)"; fi
    fi
    [ -s "$d/AGENTS.override.md" ] && warn "상위 폴더 $d/AGENTS.override.md 가 있어서 코덱스는 그 폴더에서 AGENTS.md 대신 그 파일을 읽어요. 클로드가 불러오는 규칙과 달라져요"
    if [ -f "$d/CLAUDE.md" ] && [ -f "$d/AGENTS.md" ]; then
      linked "$d/CLAUDE.md" "@AGENTS.md" || [ "$d/CLAUDE.md" -ef "$d/AGENTS.md" ] ||
        warn "상위 폴더 $d 의 CLAUDE.md와 AGENTS.md가 따로 놀아요(그 폴더도 install --project 로 잇세요)"
    elif [ -f "$d/CLAUDE.md" ]; then
      warn "상위 폴더 $d 에 CLAUDE.md만 있어요. 이 규칙은 클로드에만 적용되고 코덱스는 못 읽어요(그 폴더도 install --project 로 잇세요)"
    elif [ -s "$d/AGENTS.md" ] && [ "$cl" = 0 ]; then
      warn "상위 폴더 $d 에 AGENTS.md만 있어요. 아래쪽에 CLAUDE.md가 있으면 클로드는 이 파일을 읽지 않아요(그 폴더도 install --project 로 잇세요)"
    fi
  done <<EOF
$(chain_dirs)
EOF
}

check_size() {
  # 코덱스는 프로젝트 규칙을 project_doc_max_bytes(기본 32KiB)까지만 읽고 넘친 뒷부분은 말없이 버린다.
  # 실측(2026-10-13): 전역 AGENTS.md가 한도를 넘어도 프로젝트 AGENTS.md는 읽혔다 → 경고는 프로젝트 쪽, 전역은 참고로만.
  local limit g=0 f
  limit=$(sed -n 's/^[[:space:]]*project_doc_max_bytes[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CODEX_DIR/config.toml" 2>/dev/null | head -1)
  [ -n "$limit" ] || limit=32768
  if [ -s "$CODEX_DIR/AGENTS.override.md" ]; then
    warn "$CODEX_DIR/AGENTS.override.md 가 있어서 코덱스는 전역 AGENTS.md를 안 읽어요"
    f="$CODEX_DIR/AGENTS.override.md"
  else
    f="$CODEX_DIR/AGENTS.md"
  fi
  [ -f "$f" ] && g=$(size_of "$f")
  if [ "$g" -gt "$limit" ]; then
    note "전역 규칙이 ${g}바이트로 코덱스 한도 ${limit}바이트보다 커요. 끝부분이 빠질 수 있으니 줄이는 걸 권해요"
  else
    say "✅ 전역 규칙 크기 ${g}/${limit}바이트"
  fi
  if [ -n "$PROJECT" ]; then
    local pz=0 d pick
    while IFS= read -r d; do
      pick=""
      if [ -s "$d/AGENTS.override.md" ]; then pick="$d/AGENTS.override.md"; elif [ -s "$d/AGENTS.md" ]; then pick="$d/AGENTS.md"; fi
      [ -n "$pick" ] && pz=$((pz + $(size_of "$pick")))
    done <<EOF
$(chain_dirs)
EOF
    if [ "$pz" -gt "$limit" ]; then
      warn "프로젝트 규칙 ${pz}바이트 > 코덱스 한도 ${limit}바이트. 넘친 뒷부분은 코덱스가 못 읽어요(줄이거나 $CODEX_DIR/config.toml 에 project_doc_max_bytes 를 올리세요)"
    else
      say "✅ 프로젝트 규칙 크기 ${pz}/${limit}바이트"
    fi
  fi
}

# ── 스킬 ────────────────────────────────────────────
# 겹침 경고: 반대 방향에서 같은 이름을 이미 경고했으면 한 번만
pair_warn() { # <이름> <메시지>
  if [ "$PASS2" = 1 ] && printf '%s' "$WARNED" | grep -qxF "$1"; then return 0; fi
  warn "$2"; WARNED="$WARNED$1
"
}

# link_dir <원본 폴더> <링크 자리> [링크에 적을 경로]
link_dir() {
  local src="$1" dst="$2" target="${3:-$1}"
  [ -e "$dst" ] && [ "$dst" -ef "$src" ] && return 0   # 이미 같은 곳(폴더째 링크된 경우 포함)
  if [ -L "$dst" ]; then
    if [ -e "$dst" ]; then
      pair_warn "$(basename "$dst")" "이름 겹침: $(basename "$dst"), $dst 가 다른 곳을 가리켜요. 건드리지 않았어요"; return 1
    fi
    if ! ours "$dst"; then   # 사용자가 만든 끊긴 링크는 보존
      pair_warn "$(basename "$dst")" "이름 겹침: $(basename "$dst"), $dst 는 끊긴 링크인데 이 도구가 건 게 아니라 건드리지 않았어요. 직접 지운 뒤 다시 install 하세요"; return 1
    fi
    rm "$dst" 2>/dev/null || { err "끊긴 링크를 못 지웠어요: $dst"; return 1; }
  elif [ -e "$dst" ]; then
    pair_warn "$(basename "$dst")" "이름 겹침: $(basename "$dst"), 양쪽에 진짜 폴더가 있어요. 하나만 남기고 다시 install 하세요"; return 1
  fi
  mkdir -p "$(dirname "$dst")"
  ln -s "$target" "$dst" || { err "링크 실패: $dst"; return 1; }
  record "$(printf 'link\t%s\t%s' "$dst" "$target")" ||
    { rm -f "$dst"; err "기록 저장 실패: $MANIFEST. $dst 링크를 다시 거뒀어요"; return 1; }
  say "🔗 $(basename "$dst")  →  $dst"
}

# sync_side <원본 스킬 폴더> <반대쪽 스킬 폴더> [rel] — 진짜 폴더만 원본으로 본다
sync_side() {
  local from="$1" to="$2" rel="${3:-}" d name
  [ -d "$from" ] || return 0
  for d in "$from"/*/; do
    d="${d%/}"
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/SKILL.md" ] || continue
    name=$(basename "$d")
    ignored "$name" && continue
    if [ -n "$rel" ]; then link_dir "$d" "$to/$name" "$rel/$name"; else link_dir "$d" "$to/$name"; fi
  done
}

check_side() { # <이쪽> <반대쪽> <이쪽 이름>
  local here="$1" there="$2" label="$3" d name
  [ -d "$here" ] || return 0
  for d in "$here"/*; do
    if [ ! -e "$d" ] && [ -L "$d" ]; then
      if ours "$d"; then warn "끊긴 링크: $d (원본을 옮겼거나 지웠어요. 이 도구가 건 링크라 install 하면 정리돼요)"
      else warn "끊긴 링크: $d (이 도구가 건 링크가 아니라 건드리지 않아요. 직접 지우세요)"; fi
      continue
    fi
    [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/SKILL.md" ] || continue
    name=$(basename "$d")
    if ignored "$name"; then say "· $name: 제외 목록"; continue; fi
    if [ -e "$there/$name" ] && [ "$there/$name" -ef "$d" ]; then
      say "✅ $name ($label 원본)"
    elif [ -e "$there/$name" ]; then
      warn "이름 겹침: $name, 양쪽에 따로 있어요"
    else
      warn "$name: ${label}에만 있어요(install 하면 연결)"
    fi
    [ -n "$(fm_name "$d/SKILL.md")" ] || warn "$name: SKILL.md 머리말에 name 줄이 없어요. 클로드는 읽지만 코덱스는 못 읽어요"
    [ -n "$(fm_field "$d/SKILL.md" description)" ] || warn "$name: SKILL.md 머리말에 description이 없거나 비어 있어요. 코덱스는 둘 다 있어야 읽고, 클로드도 언제 쓸지 몰라요"
    grep -qE "$CLAUDE_ONLY" "$d/SKILL.md" 2>/dev/null &&
      note "$name: 클로드 쪽 도구 이름($(grep -oE "$CLAUDE_ONLY" "$d/SKILL.md" | sort -u | tr '\n' ' ' | sed 's/ $//'))을 써요. 코덱스에 같은 도구가 없으면 그 단계가 빠져요"
  done
}

check_dups() { # 코덱스는 같은 name 스킬을 합치지 않고 둘 다 띄운다
  local dir="$1" d dups
  [ -d "$dir" ] || return 0
  dups=$(for d in "$dir"/*; do [ -f "$d/SKILL.md" ] && fm_name "$d/SKILL.md"; done | sort | uniq -d)
  [ -z "$dups" ] || warn "같은 name 스킬이 여러 개($dir): $(printf '%s' "$dups" | tr '\n' ' ' | sed 's/ $//'). 백업·사본 폴더를 스킬 폴더 밖으로 빼세요"
}

# ── 명령 ────────────────────────────────────────────
global_import() {
  if [ "$CODEX_DIR" = "$HOME/.codex" ]; then printf '@~/.codex/AGENTS.md'; else printf '@%s' "$(esc "$CODEX_DIR/AGENTS.md")"; fi
}

prune_ours() { # 이 도구가 건 링크 중 원본이 사라진 것만 지운다
  [ -f "$MANIFEST" ] || return 0
  local kind a b
  while IFS="$(printf '\t')" read -r kind a b _; do
    [ "$kind" = link ] && [ -L "$a" ] && [ ! -e "$a" ] && [ "$(readlink "$a")" = "$b" ] || continue
    if rm "$a"; then say "🧹 끊긴 링크 정리: $a"; else err "끊긴 링크를 못 지웠어요: $a"; fi
  done < "$MANIFEST"
}

do_install() {
  can_record || { err "기록 파일을 쓸 수 없어요($MANIFEST). 아무것도 바꾸지 않았어요"; finish; }
  prune_ours
  [ -s "$CODEX_DIR/AGENTS.override.md" ] && warn "$CODEX_DIR/AGENTS.override.md 가 있어서 코덱스는 전역 AGENTS.md를 안 읽어요"
  say "== 전역 규칙"
  link_rules "$CLAUDE_DIR/CLAUDE.md" "$CODEX_DIR/AGENTS.md" "$(global_import)"
  say "== 전역 스킬"
  WARNED=""; PASS2=0; sync_side "$CLAUDE_DIR/skills" "$AGENTS_SKILLS"
  PASS2=1; sync_side "$AGENTS_SKILLS" "$CLAUDE_DIR/skills"
  if [ -n "$PROJECT" ]; then
    say "== 프로젝트 규칙 ($PROJECT)"
    [ -f "$PROJECT/.claude/CLAUDE.md" ] && warn "$PROJECT/.claude/CLAUDE.md 는 자동으로 안 다뤄요. 맨 위 CLAUDE.md로 옮긴 뒤 다시 install 하세요"
    link_rules "$PROJECT/CLAUDE.md" "$PROJECT/AGENTS.md" "@AGENTS.md"
    [ -s "$PROJECT/AGENTS.override.md" ] && warn "$PROJECT/AGENTS.override.md 가 있어서 코덱스는 이 폴더에서 그 파일을 먼저 읽어요. 내용을 AGENTS.md로 합치거나 지우세요"
    check_chain
    say "== 프로젝트 스킬"
    WARNED=""; PASS2=0; sync_side "$PROJECT/.claude/skills" "$PROJECT/.agents/skills" "../../.claude/skills"
    PASS2=1; sync_side "$PROJECT/.agents/skills" "$PROJECT/.claude/skills" "../../.agents/skills"
  fi
  say ""
  say "끝. 문제 ${problems}개 · 실패 ${errors}개. 클로드 코드와 코덱스를 새로 여세요."
  finish
}

do_check() {
  say "== 전역 규칙"
  check_rules "$CLAUDE_DIR/CLAUDE.md" "$CODEX_DIR/AGENTS.md" "$(global_import)"
  check_size
  say "== 전역 스킬"
  check_side "$CLAUDE_DIR/skills" "$AGENTS_SKILLS" "클로드"
  check_side "$AGENTS_SKILLS" "$CLAUDE_DIR/skills" "코덱스"
  check_dups "$AGENTS_SKILLS"
  if [ -n "$PROJECT" ]; then
    say "== 프로젝트 ($PROJECT)"
    check_rules "$PROJECT/CLAUDE.md" "$PROJECT/AGENTS.md" "@AGENTS.md" project
    check_chain
    check_side "$PROJECT/.claude/skills" "$PROJECT/.agents/skills" "클로드"
    check_side "$PROJECT/.agents/skills" "$PROJECT/.claude/skills" "코덱스"
    check_dups "$PROJECT/.agents/skills"
  fi
  say ""
  say "문제 ${problems}개 · 참고 ${notes}개"
  finish
}

do_undo() {
  [ -f "$MANIFEST" ] || { say "install 기록이 없어요. 걷어 낼 게 없어요."; finish; }
  local kind a b c d src tmp left="$MANIFEST.left" line
  : > "$left" 2>/dev/null || { err "기록 임시 파일을 못 만들어요($left). 아무것도 안 바꿨어요"; finish; }
  keep() { printf '%s\n' "$line" >> "$left" || err "남길 기록을 못 썼어요: $line"; }
  while IFS= read -r line; do
    IFS="$(printf '\t')" read -r kind a b c d <<EOF
$line
EOF
    case "$kind" in
      link)
        # 이 도구가 건 링크(같은 대상)일 때만 걷는다
        if [ -L "$a" ] && [ "$(readlink "$a")" = "$b" ]; then
          if rm "$a"; then say "🔗 걷어 냄: $a"; else err "링크를 못 걷었어요: $a"; keep; fi
        fi ;;
      rules)
        [ -n "$c" ] && linked "$a" "$c" || continue   # 이미 되돌려졌거나 사용자가 바꿈
        # 불러오기 줄 자리에 지금의 AGENTS.md를 풀어 넣는다(없으면 설치 때 백업)
        if [ -f "$b" ]; then src="$b"; elif [ -n "$d" ] && [ -f "$d" ]; then src="$d"
        else err "되돌릴 내용이 없어요: $b 도 백업도 없음. $a 는 그대로 둠"; keep; continue; fi
        tmp="$a.ccsync-tmp"
        if MARK="$MARK" IMP="$c" SRC="$src" awk '
             { t = $0; sub(/^[ \t]+/, "", t) }
             t ~ /^(```|~~~)/ { fence = !fence; print; next }
             !fence && $0 == ENVIRON["MARK"] { next }
             !fence && $0 == ENVIRON["IMP"]  { while ((getline l < ENVIRON["SRC"]) > 0) print l; next }
             { print }' "$a" > "$tmp" 2>/dev/null && ! linked "$tmp" "$c" && mv "$tmp" "$a" 2>/dev/null; then
          say "✅ 규칙 되돌림: $a ($src 내용으로, AGENTS.md는 그대로 둠)"
        else
          if [ -f "$tmp" ] && linked "$tmp" "$c"; then
            err "규칙을 못 되돌렸어요: $a 의 불러오기 줄 모양이 바뀌어(문장 안으로 옮김 등) 자동으로 못 바꿔요. 그 줄을 지우고 $src 내용을 붙여 넣은 뒤 undo를 다시 돌리세요(기록은 남겼어요)"
          else
            err "규칙을 못 되돌렸어요: $a (기록은 남겼어요)"
          fi
          rm -f "$tmp"; keep
        fi ;;
    esac
  done < "$MANIFEST"
  if [ -s "$left" ]; then
    mv "$left" "$MANIFEST" || err "기록을 못 고쳐 썼어요: $MANIFEST"
    say "못 되돌린 항목은 기록에 남겼어요. 고친 뒤 undo를 다시 돌리세요."
  else
    rm -f "$left"; mv "$MANIFEST" "$MANIFEST.done.$(date +%Y%m%d%H%M%S)" || err "기록을 못 옮겼어요: $MANIFEST"
  fi
  say "끝. 실패 ${errors}개. 클로드 코드와 코덱스를 새로 여세요."
  finish
}

cmd="${1:-}"; [ -n "$cmd" ] || usage; shift
PROJECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ -n "${2:-}" ] && [ -d "$2" ] || { say "프로젝트 폴더가 없어요: ${2:-}"; exit 2; }
               PROJECT=$(CDPATH= cd -- "$2" && pwd -P); shift 2 ;;
    *) usage ;;
  esac
done

case "$cmd" in
  install) do_install ;;
  check)   do_check ;;
  undo)    do_undo ;;
  *)       usage ;;
esac
