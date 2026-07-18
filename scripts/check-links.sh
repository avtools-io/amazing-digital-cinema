#!/bin/sh

# Check HTTP and HTTPS links in a Markdown file with curl.
# Restricted (401/403) and rate-limited (429) responses are reported as
# warnings because they prove the server is reachable but cannot be verified.

set -u

check_url() {
    url=$1
    timeout=${LINK_CHECK_TIMEOUT:-20}
    retries=${LINK_CHECK_RETRIES:-2}
    user_agent='Amazing-Digital-Cinema-Link-Checker/1.0'

    code=$(curl \
        --head \
        --location \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        --retry "$retries" \
        --retry-delay 1 \
        --retry-max-time "$timeout" \
        --user-agent "$user_agent" \
        "$url" 2>/dev/null)
    curl_status=$?

    # Some servers reject HEAD requests. Retry with a one-byte GET request.
    case "$curl_status:$code" in
        0:000|0:405|0:501) ;;
        0:*) classify_result "$code" "$url"; return ;;
    esac

    code=$(curl \
        --location \
        --silent \
        --output /dev/null \
        --write-out '%{http_code}' \
        --range 0-0 \
        --connect-timeout "$timeout" \
        --max-time "$timeout" \
        --retry "$retries" \
        --retry-delay 1 \
        --retry-max-time "$timeout" \
        --user-agent "$user_agent" \
        "$url" 2>/dev/null)
    curl_status=$?

    if [ "$curl_status" -ne 0 ]; then
        printf 'DEAD  [curl %s] %s\n' "$curl_status" "$url"
        return 1
    fi

    classify_result "$code" "$url"
}

classify_result() {
    code=$1
    url=$2

    case "$code" in
        2??|3??)
            printf 'OK    [%s] %s\n' "$code" "$url"
            return 0
            ;;
        401|403|429)
            printf 'WARN  [%s] %s\n' "$code" "$url"
            return 0
            ;;
        *)
            printf 'DEAD  [%s] %s\n' "$code" "$url"
            return 1
            ;;
    esac
}

if [ "${1:-}" = '--check-url' ]; then
    [ "$#" -eq 2 ] || exit 2
    check_url "$2"
    exit $?
fi

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [MARKDOWN_FILE]\n' "$0" >&2
    exit 2
fi

markdown_file=${1:-README.md}
jobs=${LINK_CHECK_JOBS:-8}

if [ ! -r "$markdown_file" ]; then
    printf 'Cannot read Markdown file: %s\n' "$markdown_file" >&2
    exit 2
fi

case "$jobs" in
    ''|*[!0-9]*|0)
        printf 'LINK_CHECK_JOBS must be a positive integer.\n' >&2
        exit 2
        ;;
esac

tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/adc-link-check.XXXXXX") || exit 2
trap 'rm -rf "$tmp_dir"' 0 1 2 3 15
urls_file=$tmp_dir/urls
results_file=$tmp_dir/results

# README links use ordinary Markdown syntax. Extract unique web URLs while
# excluding surrounding Markdown delimiters and whitespace.
LC_ALL=C grep -Eo 'https?://[^][()<>[:space:]]+' "$markdown_file" \
    | LC_ALL=C sort -u > "$urls_file"

url_count=$(wc -l < "$urls_file" | tr -d ' ')
if [ "$url_count" -eq 0 ]; then
    printf 'No HTTP or HTTPS links found in %s.\n' "$markdown_file"
    exit 0
fi

printf 'Checking %s unique links in %s with %s parallel jobs...\n\n' \
    "$url_count" "$markdown_file" "$jobs"

# Output each completed request immediately while retaining results for the
# final summary. The summary determines the final exit status.
tr '\n' '\0' < "$urls_file" \
    | xargs -0 -n 1 -P "$jobs" "$0" --check-url \
    | tee "$results_file"

ok_count=$(grep -c '^OK ' "$results_file" || true)
warn_count=$(grep -c '^WARN ' "$results_file" || true)
dead_count=$(grep -c '^DEAD ' "$results_file" || true)

printf '\nLink check complete: %s OK, %s warnings, %s dead.\n' \
    "$ok_count" "$warn_count" "$dead_count"

[ "$dead_count" -eq 0 ]
