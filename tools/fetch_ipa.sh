#!/bin/bash
set -u
url="$1"
out="$2"
ua="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"

case "$url" in
  *dropbox.com*)
    url="${url/dl=0/dl=1}"
    [[ "$url" != *dl=1* ]] && url="$url$([[ "$url" == *\?* ]] && echo '&' || echo '?')dl=1"
    ;;
  *drive.google.com/file/d/*)
    id="${url#*file/d/}"; id="${id%%/*}"; id="${id%%\?*}"
    url="https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    ;;
  *drive.google.com/*id=*|*drive.usercontent.google.com/*id=*)
    id="${url#*id=}"; id="${id%%&*}"
    url="https://drive.usercontent.google.com/download?id=$id&export=download&confirm=t"
    ;;
  *pixeldrain.com/u/*)
    id="${url#*pixeldrain.com/u/}"; id="${id%%[/?#]*}"
    url="https://pixeldrain.com/api/file/$id?download"
    ;;
  *github.com/*/blob/*)
    url="${url/\/blob\//\/raw\/}"
    ;;
esac

jar="$(mktemp)"

google_confirm_url() {
  python3 - "$1" <<'PY'
import html, re, sys, urllib.parse
page = open(sys.argv[1], encoding="utf-8", errors="ignore").read()
form = re.search(r'<form[^>]*id="download-form"[^>]*action="([^"]+)"[^>]*>(.*?)</form>', page, re.S) or re.search(r'<form[^>]*action="([^"]*drive\.usercontent\.google\.com[^"]*)"[^>]*>(.*?)</form>', page, re.S)
if not form:
    sys.exit(1)
fields = dict((html.unescape(n), html.unescape(v)) for n, v in re.findall(r'<input[^>]*name="([^"]+)"[^>]*value="([^"]*)"', form.group(2)))
print(html.unescape(form.group(1)) + "?" + urllib.parse.urlencode(fields))
PY
}

attempt_curl() {
  curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors --connect-timeout 30 -A "$ua" -H "Accept: */*" -b "$jar" -c "$jar" -o "$out" "$url" || return 1
  if [ "$(head -c 2 "$out" 2>/dev/null)" != "PK" ] && grep -qiE 'download-form|drive\.usercontent\.google\.com' "$out" 2>/dev/null; then
    confirm="$(google_confirm_url "$out")" || return 0
    echo "Google Drive large file warning, confirming download"
    url="$confirm"
    curl -fsSL --retry 3 --retry-delay 3 --retry-all-errors --connect-timeout 30 -A "$ua" -b "$jar" -c "$jar" -o "$out" "$url"
  fi
}

attempt_curl_plain() {
  curl -fsSL --retry 2 --retry-delay 3 --connect-timeout 30 -o "$out" "$url"
}

attempt_wget() {
  wget --no-verbose --tries=3 --user-agent="$ua" -O "$out" "$url"
}

for method in attempt_curl attempt_curl_plain attempt_wget; do
  command -v "${method#attempt_}" >/dev/null 2>&1 || [ "$method" != "attempt_wget" ] || continue
  rm -f "$out"
  if $method; then
    if [ "$(head -c 2 "$out" 2>/dev/null)" = "PK" ]; then
      exit 0
    fi
    echo "Downloaded file is not an IPA (got $(file -b "$out" 2>/dev/null | cut -c1-60)), trying another method"
  fi
done

code=$(curl -s -o /dev/null -w '%{http_code}' -L -A "$ua" "$url")
echo "IPA download failed (HTTP $code)."
case "$code" in
  401|403) [[ "$url" == *pixeldrain.com* ]] && echo "Pixeldrain refuses the download: the free download limit of this file is reached or GitHub servers are blocked. Upload the IPA somewhere else (Dropbox with dl=1, Google Drive shared publicly, or a GitHub release)."
    echo "The server refuses the download. Use a direct, public link (no login, not expired): e.g. a GitHub release asset, Dropbox with dl=1, or a fresh link from your host." ;;
  404) echo "The file was not found at this address." ;;
  200)
    if [[ "$url" == *google* ]] && grep -qiE 'accounts\.google\.com|ServiceLogin|Request access|Demander l' "$out" 2>/dev/null; then
      echo "Google Drive asks to sign in: share the file as 'Anyone with the link' (Tous les utilisateurs disposant du lien)."
    else
      echo "The link opens a web page instead of the file. Use the direct download link of the IPA."
    fi ;;
esac
exit 1
