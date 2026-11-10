#!/usr/bin/env bash
#
# ci/detect-project-id.sh: Detects the GCP Project ID / Apigee Organization
# using a unified precedence order across all scripts and Makefile.
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_FALLBACK="training-gcp-demos"
KEY_FILE="${REPO_ROOT}/cert/service-account.json"
EXPLICIT_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --default)
            DEFAULT_FALLBACK="$2"
            shift 2
            ;;
        --key-file)
            KEY_FILE="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            if [[ -z "${EXPLICIT_ID}" ]]; then
                EXPLICIT_ID="$1"
            fi
            shift
            ;;
    esac
done

resolve_project_id() {
    # 1. Explicit ID from CLI argument or environment variables
    local proj="${EXPLICIT_ID:-${ORG:-${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-${GCP_PROJECT:-}}}}}"
    if [[ -n "${proj}" ]]; then
        echo "${proj}"
        return 0
    fi

    # 2. Active gcloud configuration
    if command -v gcloud >/dev/null 2>&1; then
        local gcloud_proj
        gcloud_proj="$(gcloud config get-value project 2>/dev/null || true)"
        if [[ -n "${gcloud_proj}" && "${gcloud_proj}" != "(unset)" ]]; then
            echo "${gcloud_proj}"
            return 0
        fi
    fi

    # 3. Local service account key file
    if [[ -f "${KEY_FILE}" ]]; then
        local key_proj=""
        if command -v jq >/dev/null 2>&1; then
            key_proj="$(jq -r '.project_id // empty' "${KEY_FILE}" 2>/dev/null || true)"
        else
            key_proj="$(grep -o '"project_id"[[:space:]]*:[[:space:]]*"[^"]*"' "${KEY_FILE}" 2>/dev/null | cut -d'"' -f4 || true)"
        fi
        if [[ -n "${key_proj}" ]]; then
            echo "${key_proj}"
            return 0
        fi
    fi

    # 4. Fallback default
    echo "${DEFAULT_FALLBACK}"
}

resolve_project_id

