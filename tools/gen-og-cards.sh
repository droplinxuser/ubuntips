#!/usr/bin/env bash
# Render a 1200x630 Open Graph card for every post.
#
# Input : public/index.json (produced by a Hugo build)
# Output: assets/og/<slug>.png (Hugo derives a 320x168 thumbnail at build time)
#
# Runs on ubuntu-latest, which ships google-chrome. Hugo resizes the card to a
# 320x168 PNG thumbnail at build time; no ImageMagick is required.
# Locally the templates fall back to /img/og-default.png when cards are absent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

INDEX="${1:-public/index.json}"
OUT_DIR="assets/og"
mkdir -p "$OUT_DIR"

CHROME="${CHROME_BIN:-}"
if [ -z "$CHROME" ]; then
  for candidate in google-chrome google-chrome-stable chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then CHROME="$candidate"; break; fi
  done
fi
if [ -z "$CHROME" ]; then
  echo "gen-og-cards: no Chrome/Chromium found; leaving cards alone." >&2
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "gen-og-cards: jq is required." >&2
  exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

html_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

# $1 = output file, $2 = extra CSS (thumbnail scaling)
write_card() {
  local out="$1" extra="$2" title="$3" date="$4" size="$5"
  cat > "$out" <<HTML
<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><style>
  *{box-sizing:border-box;margin:0}
  html,body{background:#0d1117}
  #card{position:relative;width:1200px;height:630px;padding:56px 64px;background:#0d1117;color:#e6edf3;
        font-family:-apple-system,BlinkMacSystemFont,"Segoe UI","Noto Sans",Helvetica,Arial,sans-serif;
        display:flex;flex-direction:column;justify-content:space-between;overflow:hidden}
  #card::before{content:"";position:absolute;inset:0;
        background:radial-gradient(600px 320px at 88% 6%,rgba(31,111,235,.28),transparent 70%),
                   radial-gradient(520px 300px at 8% 96%,rgba(35,134,54,.20),transparent 70%)}
  .top{position:relative;display:flex;align-items:center;gap:16px}
  .mark{display:grid;place-items:center;width:56px;height:56px;border:1px solid #30363d;border-radius:12px;background:#161b22;color:#3fb950}
  .brand{font-size:26px;font-weight:600}
  .brand span{color:#8d96a0;font-weight:400}
  .mid{position:relative}
  h1{font-size:${size}px;line-height:1.06;letter-spacing:-.03em;font-weight:700;max-width:1040px}
  .meta{margin-top:20px;font-size:24px;color:#8d96a0}
  .bottom{position:relative;display:flex;align-items:center;gap:12px}
  .label{font-size:20px;line-height:36px;padding:0 18px;color:#4493f8;background:rgba(56,139,253,.15);
         border:1px solid rgba(56,139,253,.4);border-radius:2em}
  .label.green{color:#3fb950;background:rgba(46,160,67,.15);border-color:rgba(46,160,67,.4)}
  .url{margin-left:auto;font-size:22px;color:#6e7681}
  ${extra}
</style></head>
<body><div id="card">
  <div class="top">
    <div class="mark"><svg width="30" height="30" viewBox="0 0 16 16" fill="currentColor"><path d="M0 2.75C0 1.784.784 1 1.75 1h12.5c.966 0 1.75.784 1.75 1.75v10.5A1.75 1.75 0 0 1 14.25 15H1.75A1.75 1.75 0 0 1 0 13.25Zm1.75-.25a.25.25 0 0 0-.25.25v10.5c0 .138.112.25.25.25h12.5a.25.25 0 0 0 .25-.25V2.75a.25.25 0 0 0-.25-.25Zm7.25 8a.75.75 0 0 1 .75-.75h2a.75.75 0 0 1 0 1.5h-2a.75.75 0 0 1-.75-.75ZM3.72 4.72a.75.75 0 0 1 1.06 0l3 3a.75.75 0 0 1 0 1.06l-3 3a.75.75 0 1 1-1.06-1.06L6.19 8 3.72 5.53a.75.75 0 0 1 0-1.06Z"/></svg></div>
    <div class="brand">ubuntips<span>.com</span></div>
  </div>
  <div class="mid">
    <h1>${title}</h1>
    <div class="meta">${date}</div>
  </div>
  <div class="bottom">
    <span class="label">Ubuntu</span>
    <span class="label">servers</span>
    <span class="label">tuning</span>
    <span class="label green">static · no database</span>
    <span class="url">ubuntips.com</span>
  </div>
</div></body></html>
HTML
}

shoot() {
  local html="$1" png="$2" w="$3" h="$4"
  "$CHROME" --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --hide-scrollbars \
    --force-device-scale-factor=1 --window-size="$w,$h" \
    --virtual-time-budget=2000 --screenshot="$png" "file://$html" >/dev/null 2>&1
}

count=0
while IFS=$'\t' read -r title url date; do
  [ -n "${url:-}" ] || continue
  slug="${url%/}"
  slug="${slug##*/}"
  case "$slug" in
    ""|*[!A-Za-z0-9._-]*) echo "gen-og-cards: skipping odd slug '$slug'" >&2; continue ;;
  esac

  escaped="$(html_escape "$title")"
  n=${#title}
  if   [ "$n" -le 42 ]; then size=82
  elif [ "$n" -le 62 ]; then size=68
  elif [ "$n" -le 85 ]; then size=56
  else size=46
  fi

  full="$TMP/$slug.html"
  write_card "$full" "" "$escaped" "$date" "$size"

  shoot "$full" "$OUT_DIR/$slug.png" 1200 630
  count=$((count + 1))
done < <(jq -r '.[] | [.title, .url, .date] | @tsv' "$INDEX")

echo "gen-og-cards: generated $count card(s) in $OUT_DIR"
