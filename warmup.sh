#!/usr/bin/env bash
#
# nginx-cache-warmup — prime Nginx FastCGI/proxy cache by crawling a sitemap.
#
# Fetches every URL in a sitemap (or sitemap index) with parallel curl workers
# so the first real visitor gets a cache HIT instead of a cold MISS.
#
# Usage:
#   ./warmup.sh --sitemap https://example.com/sitemap.xml [options]
#
# Options:
#   --sitemap URL        sitemap or sitemap-index URL (required)
#   --concurrency N      parallel fetch workers (default: 8)
#   --delay MS           milliseconds between requests per worker (default: 0)
#   --user-agent STR     User-Agent header (default: nginx-cache-warmup/1.0)
#   --timeout S          per-request timeout in seconds (default: 30)
#   --skip REGEX         skip URLs matching REGEX (repeatable)
#   --only REGEX         only warm URLs matching REGEX (repeatable)
#   --header "K: V"      extra request header (repeatable)
#   --dry-run            list URLs that would be warmed, then exit
#   --output FILE        append a Markdown summary report to FILE
#   -h, --help           show this help
#
# Example:
#   ./warmup.sh --sitemap https://example.com/sitemap.xml --concurrency 10 \
#       --skip '/cart|/checkout|/my-account' --output warmup-report.md

set -euo pipefail

SITEMAP=""
CONCURRENCY=8
DELAY_MS=0
UA="nginx-cache-warmup/1.0"
TIMEOUT=30
SKIP=()
ONLY=()
HEADERS=()
DRY_RUN=0
OUTPUT=""

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --sitemap)     SITEMAP="$2"; shift 2 ;;
        --concurrency) CONCURRENCY="$2"; shift 2 ;;
        --delay)       DELAY_MS="$2"; shift 2 ;;
        --user-agent)  UA="$2"; shift 2 ;;
        --timeout)     TIMEOUT="$2"; shift 2 ;;
        --skip)        SKIP+=("$2"); shift 2 ;;
        --only)        ONLY+=("$2"); shift 2 ;;
        --header)      HEADERS+=("$2"); shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        --output)      OUTPUT="$2"; shift 2 ;;
        -h|--help)     usage 0 ;;
        *) echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

[[ -z "$SITEMAP" ]] && { echo "Error: --sitemap is required" >&2; exit 1; }
command -v curl >/dev/null || { echo "Error: curl is required" >&2; exit 1; }

TMPDIR_WORK=$(mktemp -d)
trap 'rm -rf "$TMPDIR_WORK"' EXIT

# ---------------------------------------------------------------------------
# Collect URLs from a sitemap or sitemap index (recursive, one level).
# ---------------------------------------------------------------------------
fetch_urls() {
    local url="$1"
    curl -sS --max-time "$TIMEOUT" -A "$UA" "$url" | grep -oE '<loc>[^<]+</loc>' | sed -E 's#</?loc>##g'
}

mapfile -t raw_urls < <(fetch_urls "$SITEMAP")
urls=()
for u in "${raw_urls[@]}"; do
    if [[ "$u" == *.xml || "$u" == *.xml.gz ]]; then
        # Sitemap index child — recurse once.
        while IFS= read -r child; do urls+=("$child"); done < <(fetch_urls "$u" || true)
    else
        urls+=("$u")
    fi
done

# Dedupe + filters.
declare -A seen
filtered=()
for u in "${urls[@]}"; do
    [[ -n "${seen[$u]:-}" ]] && continue
    seen[$u]=1
    skip=0
    for re in "${SKIP[@]}"; do [[ "$u" =~ $re ]] && skip=1 && break; done
    (( skip )) && continue
    if (( ${#ONLY[@]} )); then
        keep=0
        for re in "${ONLY[@]}"; do [[ "$u" =~ $re ]] && keep=1 && break; done
        (( keep )) || continue
    fi
    filtered+=("$u")
done

echo "Found ${#filtered[@]} URL(s) to warm."

if (( DRY_RUN )); then
    printf '%s\n' "${filtered[@]}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Warm: N parallel workers, each with optional per-request delay.
# Result lines: "<http_code> <seconds> <url>"
# (curl args are rebuilt inside the worker: bash cannot export arrays.)
# ---------------------------------------------------------------------------
HEADERS_STR=$(printf '%s\n' "${HEADERS[@]}")
export UA TIMEOUT DELAY_MS HEADERS_STR

worker() {
    local url="$1"
    local args=(-sS --max-time "$TIMEOUT" -A "$UA" -o /dev/null -w '%{http_code} %{time_total} %{url_effective}\n')
    while IFS= read -r h; do
        [[ -n "$h" ]] && args+=(-H "$h")
    done <<< "$HEADERS_STR"
    if (( DELAY_MS > 0 )); then
        sleep "$(awk "BEGIN{printf \"%.3f\", $DELAY_MS/1000}")"
    fi
    curl "${args[@]}" "$url" 2>/dev/null || echo "000 0 $url"
}
export -f worker

results_file="$TMPDIR_WORK/results.txt"
: > "$results_file"
printf '%s\n' "${filtered[@]}" | xargs -P "$CONCURRENCY" -I{} bash -c 'worker "$@"' _ {} >> "$results_file"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
total=$(wc -l < "$results_file")
ok2xx=$(awk '$1 ~ /^2/ {c++} END{print c+0}' "$results_file")
ok3xx=$(awk '$1 ~ /^3/ {c++} END{print c+0}' "$results_file")
fail=$(awk '$1 !~ /^[23]/ {c++} END{print c+0}' "$results_file")
avg_time=$(awk '{s+=$2; c++} END{if(c) printf "%.2f", s/c; else print "0"}' "$results_file")

echo "Warmed: $total | 2xx: $ok2xx | 3xx: $ok3xx | failed/other: $fail | avg ${avg_time}s"

if (( fail > 0 )); then
    echo "Failed URLs:"
    awk '$1 !~ /^[23]/' "$results_file" | head -20
fi

if [[ -n "$OUTPUT" ]]; then
    {
        echo "# Cache warmup report — $(date -u +%FT%TZ)"
        echo
        echo "- Sitemap: $SITEMAP"
        echo "- URLs warmed: $total (2xx: $ok2xx, 3xx: $ok3xx, failed: $fail)"
        echo "- Average response: ${avg_time}s, concurrency: $CONCURRENCY"
        if (( fail > 0 )); then
            echo; echo "## Failed URLs"
            awk '$1 !~ /^[23]/ {print "- [" $1 "](" $3 ")"}' "$results_file" | head -50
        fi
    } >> "$OUTPUT"
    echo "Report appended to $OUTPUT"
fi
