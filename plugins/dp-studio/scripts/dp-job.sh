#!/bin/sh
# dp-job.sh — 상세페이지 스튜디오 작업 스크립트 (macOS·Linux, 추가 설치 없음: curl·tar·shasum)
# 서버 도구(dp_project_create · dp_render · dp_lint_copy)가 돌려준 명령을 그대로 실행합니다.
#   sh dp-job.sh init|render|lint|merge|catalog <서버 주소> <작업표> <폴더>
#   init   : 새 상세페이지 작업 폴더 만들기
#   render : page.html·theme.css·assets 를 올리고, 렌더 결과를 output/ 에 합친 뒤 자동검수 요약 출력
#   lint   : 03_copy.md 카피 점검 결과 출력
#   merge  : 마지막 전체 렌더를 통이미지(긴 JPG)로 합쳐 output/merged/ 에 받기
#   catalog: 견본 묶음(완성 견본·컴포넌트·프리셋 미리보기)을 받아 폴더에 풀기
set -eu
[ $# -eq 4 ] || { echo "사용: sh dp-job.sh init|render|lint|merge|catalog <서버 주소> <작업표> <폴더>"; exit 1; }
CMD="$1"; API="${2%/}"; TICKET="$3"; DIR="$4"
export COPYFILE_DISABLE=1   # macOS tar 가 ._ 파일을 끼워 넣지 않게
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ASSETS_MAX=31457280
IMAGE_RE='^assets/[A-Za-z0-9._/-]+\.(png|jpe?g|webp|gif|svg|avif)$'

fail() { echo "❌ $1"; exit 1; }
val() { sed -n "s/^$1=//p" "$2" | head -n 1; }   # key=value 줄에서 값 꺼내기
sha256() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

# api <방법> <경로> <응답 파일> [curl 추가 인자...]
api() {
  m="$1"; p="$2"; o="$3"; shift 3
  code=$(curl -sS -X "$m" -o "$o" -w '%{http_code}' "$@" "$API$p") || fail "서버에 연결하지 못했어요. 인터넷 연결을 확인해 주세요."
  if [ "$code" -ge 400 ]; then e=$(val error "$o"); fail "${e:-서버 오류 ($code)}"; fi
}

# 작업이 끝날 때까지 기다린다 (상태는 $TMP/status.txt)
wait_done() {
  sleep 4; status=""; i=0
  while [ $i -lt 140 ]; do
    api GET "/jobs/status?t=$TICKET" "$TMP/status.txt"
    status=$(val status "$TMP/status.txt")
    if [ "$status" = "done" ] || [ "$status" = "failed" ]; then break; fi
    sleep 3; i=$((i + 1))
  done
  [ "$status" != "failed" ] || fail "$1 실패: $(val error "$TMP/status.txt")"
  [ "$status" = "done" ] || fail "$1 시간이 너무 오래 걸려요. 잠시 뒤 다시 해 주세요."
}

# 결과 묶음을 받아 $TMP/out 에 푼다
get_result() {
  code=$(curl -sS -o "$TMP/result.tgz" -w '%{http_code}' "$(val resultUrl "$TMP/status.txt")") || fail "결과를 받지 못했어요"
  [ "$code" = "200" ] || fail "결과를 받지 못했어요 ($code)"
  mkdir -p "$TMP/out" && tar -xzf "$TMP/result.tgz" -C "$TMP/out" || fail "결과를 풀지 못했어요"
}

write_preview() {
  out="$1"; name=$(basename "$DIR")
  items=""
  for f in $(cd "$out/1000" 2>/dev/null && ls *.png 2>/dev/null | LC_ALL=C sort); do items="$items<div class=\"cap\">$f</div><img src=\"1000/$f\">"; done
  printf '%s' "<!doctype html><meta charset=\"utf-8\"><title>미리보기 · $name</title><style>body{margin:0;background:#2b2b2b;font-family:sans-serif}main{width:500px;margin:0 auto}img{display:block;width:500px}.cap{color:#aaa;font-size:12px;padding:6px 0}</style><main>$items</main>" > "$out/preview.html"
}

case "$CMD" in
init)
  if [ -d "$DIR" ] && [ -n "$(ls -A "$DIR" 2>/dev/null)" ]; then fail "작업 폴더가 비어 있지 않아요: $DIR"; fi
  mkdir -p "$DIR"
  code=$(curl -sS -o "$TMP/starter.tgz" -w '%{http_code}' "$API/starter?t=$TICKET") || fail "서버에 연결하지 못했어요."
  [ "$code" = "200" ] || fail "시작 파일을 받지 못했어요: $(sed 's/^error=//' "$TMP/starter.tgz")"
  tar -xzf "$TMP/starter.tgz" -C "$DIR" || fail "시작 파일을 풀지 못했어요"
  find "$DIR" -name .keep -type f -delete
  echo "✅ 작업 폴더를 만들었어요: $DIR"; ls "$DIR" | sed 's/^/   /'
  ;;
lint)
  [ -f "$DIR/03_copy.md" ] || fail "03_copy.md 가 없어요: $DIR"
  api POST "/lint?t=$TICKET" "$TMP/lint.txt" -H 'Content-Type: text/markdown; charset=utf-8' --data-binary "@$DIR/03_copy.md"
  cat "$TMP/lint.txt"
  ;;
render)
  [ -f "$DIR/page.html" ] || fail "page.html 이 없어요: $DIR"
  # 렌더에 쓸 이미지 목록 — 이름 규칙에 안 맞는 이미지가 있으면 멈춘다
  : > "$TMP/assets.txt"
  if [ -d "$DIR/assets" ]; then
    (cd "$DIR" && find assets -type f | LC_ALL=C sort) | grep -Ei '\.(png|jpe?g|webp|gif|svg|avif)$' > "$TMP/images.txt" || true
    bad=$(grep -Eiv "$IMAGE_RE" "$TMP/images.txt" || true)
    [ -z "$bad" ] || fail "이미지 파일 이름은 영문·숫자·하이픈(-)·밑줄(_)만 쓸 수 있어요. 이름을 바꾼 뒤 page.html 의 경로도 고쳐 주세요: $(echo $bad)"
    cp "$TMP/images.txt" "$TMP/assets.txt"
  fi
  if [ -s "$TMP/assets.txt" ]; then
    hash=$( (cd "$DIR" && while IFS= read -r f; do printf '%s %s\n' "$f" "$(sha256 "$f" | cut -d' ' -f1)"; done < "$TMP/assets.txt") | sha256 | cut -d' ' -f1)
  else hash=none; fi
  printf '%s' "$hash" > "$TMP/hash.txt"
  api POST "/jobs/prepare?t=$TICKET" "$TMP/prep.txt" -H 'Content-Type: text/plain' --data-binary "@$TMP/hash.txt"
  if [ "$(val needAssets "$TMP/prep.txt")" = "1" ]; then
    tar -czf "$TMP/assets.tgz" -C "$DIR" -T "$TMP/assets.txt" || fail "이미지 묶음을 만들지 못했어요"
    size=$(wc -c < "$TMP/assets.tgz" | tr -d ' ')
    [ "$size" -le "$ASSETS_MAX" ] || fail "이미지 묶음이 30MB를 넘어요. 큰 이미지를 줄여 주세요."
    code=$(curl -sS -X PUT -H "x-goog-content-length-range: $(val range "$TMP/prep.txt")" -H 'Content-Type: application/gzip' \
      --upload-file "$TMP/assets.tgz" -o "$TMP/put.txt" -w '%{http_code}' "$(val putUrl "$TMP/prep.txt")") || fail "이미지를 올리지 못했어요"
    [ "$code" -lt 300 ] || fail "이미지를 올리지 못했어요 ($code)"
    echo "📤 이미지 $(wc -l < "$TMP/assets.txt" | tr -d ' ')개 올림"
  fi
  set -- page.html; if [ -f "$DIR/theme.css" ]; then set -- page.html theme.css; fi
  tar -czf "$TMP/text.tgz" -C "$DIR" "$@" || fail "page.html 묶음을 만들지 못했어요"
  api POST "/jobs/start?t=$TICKET" "$TMP/start.txt" -H 'Content-Type: application/gzip' -H "X-Assets-Hash: $hash" --data-binary "@$TMP/text.tgz"
  echo "⏳ 렌더 중… (보통 10~60초)"
  wait_done "렌더"
  get_result

  # output/ 에 합치기: 부분 렌더면 그 섹션 파일만 바꾸고, 전체 렌더면 해당 폴더를 새로
  out="$DIR/output"; mkdir -p "$out"
  only=$(val only "$TMP/status.txt")
  for sub in 1000 2000 review; do
    [ -d "$TMP/out/$sub" ] || continue
    mkdir -p "$out/$sub"
    if [ -n "$only" ]; then
      for id in $(echo "$only" | tr ',' ' '); do rm -f "$out/$sub/${id}_"*.png "$out/$sub/$id.png"; done
    else rm -f "$out/$sub/"*.png; fi
    cp "$TMP/out/$sub/"* "$out/$sub/"
  done
  for f in qa-report.md qa-report.json page-text.md; do if [ -f "$TMP/out/$f" ]; then cp "$TMP/out/$f" "$out/"; fi; done
  write_preview "$out"
  n=$(ls "$out/1000/"*.png 2>/dev/null | wc -l | tr -d ' ')
  echo "✅ 렌더 완료 ($(val mode "$TMP/status.txt") · ${only:-전체}, 서버 $(val seconds "$TMP/status.txt")초) — output/1000 에 ${n}장, 미리보기 output/preview.html"
  if [ -f "$out/qa-report.md" ]; then
    grep -E '^- 오류\(error\)' "$out/qa-report.md" | sed 's/^- /   /'
    awk '/^## /{h=substr($0,4)} /❌|⚠️/ && n<40 {print "   [" h "] " substr($0,3); n++}' "$out/qa-report.md"
    echo "   전체 보고서: output/qa-report.md · 섹션별 확인용 조각: output/review/"
  fi
  ;;
merge)
  api POST "/jobs/start?t=$TICKET" "$TMP/start.txt" -H 'Content-Type: text/plain' --data-binary "merge"
  echo "⏳ 통이미지 만드는 중…"
  wait_done "통이미지"
  get_result
  mkdir -p "$DIR/output/merged" && rm -f "$DIR/output/merged/"*
  cp "$TMP/out/merged/"* "$DIR/output/merged/"
  echo "✅ 통이미지 $(ls "$DIR/output/merged" | wc -l | tr -d ' ')장 — output/merged/"
  ls -l "$DIR/output/merged" | awk 'NR>1 {printf "   %s (%.1fMB)\n", $NF, $5/1048576}'
  ;;
catalog)
  api GET "/catalog?t=$TICKET" "$TMP/catalog.txt"
  mkdir -p "$DIR"
  code=$(curl -sS -o "$TMP/catalog.tgz" -w '%{http_code}' "$(val url "$TMP/catalog.txt")") || fail "견본을 받지 못했어요"
  [ "$code" = "200" ] || fail "견본을 받지 못했어요 ($code)"
  tar -xzf "$TMP/catalog.tgz" -C "$DIR" || fail "견본을 풀지 못했어요"
  echo "✅ 견본을 받았어요: $DIR"; ls "$DIR" | sed 's/^/   /'
  ;;
*) fail "알 수 없는 명령: $CMD" ;;
esac
