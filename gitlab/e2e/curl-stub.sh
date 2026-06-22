#!/usr/bin/env bash
# A fake `curl` for the offline GitLab e2e harness. Placed first on PATH so the
# real gitlab/gather-context.sh and gitlab/post-review.sh run unmodified, but
# every API call is served from fixtures (GETs) or recorded (writes).
#
# Reproduces just enough of curl's surface for our scripts:
#   -o FILE          response body destination
#   -D FILE          response header destination (we emit X-Total for discussions)
#   -X METHOD        http method (default GET)
#   -w FORMAT        if present, print "200" (the only thing our scripts read off stdout)
#   --data-binary @F request body file (logged for write methods)
#   the URL is the trailing http(s) argument; routing keys off it.
#
# Env: E2E_FIXTURES (fixture dir), STUB_LOG (file to append write-requests to).

set -euo pipefail

method=GET
outfile=/dev/stdout
hdrfile=""
datafile=""
want_code=0
url=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -o) outfile="$2"; shift 2 ;;
    -D) hdrfile="$2"; shift 2 ;;
    -w) want_code=1; shift 2 ;;
    --data-binary) d="$2"; datafile="${d#@}"; shift 2 ;;
    -H) shift 2 ;;
    -sS|-s|-S|-L) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done

if [[ "$method" != GET ]]; then
  {
    echo "=== $method $url"
    [[ -n "$datafile" && -f "$datafile" ]] && cat "$datafile"
    echo
  } >> "$STUB_LOG"
  echo '{"id":999,"resolved":true}' > "$outfile"
else
  case "$url" in
    *"/changes"*)
      cat "$E2E_FIXTURES/mr-changes.json" > "$outfile" ;;
    *"/discussions"*)
      cat "$E2E_FIXTURES/discussions.json" > "$outfile"
      [[ -n "$hdrfile" ]] && echo "X-Total: $(jq 'length' "$E2E_FIXTURES/discussions.json")" > "$hdrfile" ;;
    *"/notes"*)
      # No pre-existing sticky summary note.
      echo '[]' > "$outfile" ;;
    *)
      echo '{}' > "$outfile" ;;
  esac
fi

[[ "$want_code" == 1 ]] && printf '200'
exit 0
