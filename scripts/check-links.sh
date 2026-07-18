#!/bin/sh

# Check HTTP and HTTPS links in a Markdown file with curl. Response handling,
# retry behaviour and narrowly scoped exceptions live in check-policies.json.

set -u

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
policy_file=${LINK_CHECK_POLICY_FILE:-$script_dir/check-policies.json}

if [ ! -r "$policy_file" ]; then
    printf 'Cannot read link-check policy file: %s\n' "$policy_file" >&2
    exit 2
fi

policy_array_values() {
    key=$1
    awk -v key="\"$key\"" '
        index($0, key) { in_array = 1; next }
        in_array && /^[[:space:]]*]/ { exit }
        in_array && /^[[:space:]]*"/ {
            line = $0
            sub(/^[[:space:]]*"/, "", line)
            sub(/"[[:space:]]*,?[[:space:]]*$/, "", line)
            print line
        }
    ' "$policy_file"
}

policy_has() {
    policy_array_values "$1" | grep -Fqx "$2"
}

policy_number() {
    key=$1
    fallback=$2
    value=$(awk -F: -v key="\"$key\"" '
        index($1, key) {
            gsub(/[^0-9]/, "", $2)
            print $2
            exit
        }
    ' "$policy_file")

    case "$value" in
        ''|*[!0-9]*) printf '%s\n' "$fallback" ;;
        *) printf '%s\n' "$value" ;;
    esac
}

is_allowed_response() {
    policy_has 'allowedResponses' "$1 $2"
}

is_allowed_curl_error() {
    policy_has 'allowedCurlErrors' "$1 $2"
}

request_url() {
    method=$1
    url=$2
    timeout=$3
    retries=$4
    user_agent=$5
    attempt=0
    delay=$(policy_number 'initialRetryDelaySeconds' 1)
    max_redirects=$(policy_number 'maxRedirects' 100)

    while :; do
        if [ "$method" = 'HEAD' ]; then
            code=$(curl \
                --head \
                --location \
                --max-redirs "$max_redirects" \
                --silent \
                --output /dev/null \
                --write-out '%{http_code}' \
                --connect-timeout "$timeout" \
                --max-time "$timeout" \
                --user-agent "$user_agent" \
                "$url" 2>/dev/null)
        else
            code=$(curl \
                --location \
                --max-redirs "$max_redirects" \
                --silent \
                --output /dev/null \
                --write-out '%{http_code}' \
                --range 0-0 \
                --connect-timeout "$timeout" \
                --max-time "$timeout" \
                --user-agent "$user_agent" \
                "$url" 2>/dev/null)
        fi
        curl_status=$?

        retry_request=false
        if policy_has 'retryStatusCodes' "$code"; then
            retry_request=true
        fi
        if [ "$curl_status" -ne 0 ] && ! is_allowed_curl_error "$curl_status" "$url"; then
            retry_request=true
        fi

        if [ "$retry_request" = false ] || [ "$attempt" -ge "$retries" ]; then
            printf '%s %s\n' "$curl_status" "$code"
            return
        fi

        sleep "$delay"
        attempt=$((attempt + 1))
        delay=$((delay * 2))
    done
}

classify_result() {
    code=$1
    url=$2

    case "$code" in
        2??|3??)
            printf 'OK    [%s] %s\n' "$code" "$url"
            return 0
            ;;
    esac

    if is_allowed_response "$code" "$url"; then
        printf 'WARN  [%s allowlisted] %s\n' "$code" "$url"
        return 0
    fi

    printf 'DEAD  [%s] %s\n' "$code" "$url"
    return 1
}

check_url() {
    url=$1
    timeout=${LINK_CHECK_TIMEOUT:-$(policy_number 'defaultTimeoutSeconds' 20)}
    retries=${LINK_CHECK_RETRIES:-$(policy_number 'defaultRetries' 3)}
    user_agent='Amazing-Digital-Cinema-Link-Checker/1.0'

    response=$(request_url 'HEAD' "$url" "$timeout" "$retries" "$user_agent")
    curl_status=${response%% *}
    code=${response#* }

    if [ "$curl_status" -ne 0 ] && is_allowed_curl_error "$curl_status" "$url"; then
        printf 'WARN  [curl %s allowlisted] %s\n' "$curl_status" "$url"
        return 0
    fi

    # Retry with a one-byte GET when HEAD is rejected, reports a missing page,
    # or cannot complete. This catches servers that do not implement HEAD well.
    if [ "$curl_status" -eq 0 ] && ! policy_has 'headFallbackStatusCodes' "$code"; then
        classify_result "$code" "$url"
        return
    fi

    response=$(request_url 'GET' "$url" "$timeout" "$retries" "$user_agent")
    curl_status=${response%% *}
    code=${response#* }

    if [ "$curl_status" -ne 0 ]; then
        if is_allowed_curl_error "$curl_status" "$url"; then
            printf 'WARN  [curl %s allowlisted] %s\n' "$curl_status" "$url"
            return 0
        fi

        printf 'DEAD  [curl %s] %s\n' "$curl_status" "$url"
        return 1
    fi

    classify_result "$code" "$url"
}

acquire_host_lock() {
    url=$1
    host=${url#*://}
    host=${host%%/*}
    host=${host%%:*}
    lock_name=$(printf '%s' "$host" | tr -c '[:alnum:]_.-' '_')
    host_lock=${LINK_CHECK_LOCK_DIR}/${lock_name}

    while ! mkdir "$host_lock" 2>/dev/null; do
        sleep 1
    done
}

release_host_lock() {
    rmdir "$host_lock" 2>/dev/null || true
}

if [ "${1:-}" = '--check-url' ]; then
    [ "$#" -eq 2 ] || exit 2
    acquire_host_lock "$2"
    check_url "$2"
    status=$?
    release_host_lock
    exit "$status"
fi

if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [MARKDOWN_FILE]\n' "$0" >&2
    exit 2
fi

markdown_file=${1:-README.md}
jobs=${LINK_CHECK_JOBS:-$(policy_number 'defaultJobs' 8)}

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
LINK_CHECK_LOCK_DIR=$tmp_dir/host-locks
export LINK_CHECK_LOCK_DIR
mkdir "$LINK_CHECK_LOCK_DIR"

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

# Requests run in parallel across hosts. A per-host lock ensures that only one
# URL is checked against a given host at a time.
tr '\n' '\0' < "$urls_file" \
    | xargs -0 -n 1 -P "$jobs" "$0" --check-url \
    | tee "$results_file"

ok_count=$(grep -c '^OK ' "$results_file" || true)
warn_count=$(grep -c '^WARN ' "$results_file" || true)
dead_count=$(grep -c '^DEAD ' "$results_file" || true)

printf '\nLink check complete: %s OK, %s warnings, %s dead.\n' \
    "$ok_count" "$warn_count" "$dead_count"

[ "$dead_count" -eq 0 ]
