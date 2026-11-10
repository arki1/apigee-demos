#!/usr/bin/env bash
#
# ci/apigee-emulator.sh: CLI to manage the local Apigee Emulator and deploy proxies.
# Useful for local development and CI/CD pipelines.
#
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configurable options via environment variables
EMULATOR_IMAGE="${EMULATOR_IMAGE:-gcr.io/apigee-release/hybrid/apigee-emulator:1.16.2}"
EMULATOR_CONTAINER="${EMULATOR_CONTAINER:-apigee-localhost}"
EMULATOR_MGMT_PORT="${EMULATOR_MGMT_PORT:-8080}"
EMULATOR_RUNTIME_PORT="${EMULATOR_RUNTIME_PORT:-8999}"
EMULATOR_ENV="${EMULATOR_ENV:-dev}"
EMULATOR_KEYS_DIR="${EMULATOR_KEYS_DIR:-${REPO_ROOT}/cert}"
EMULATOR_SA_KEY="${EMULATOR_SA_KEY:-service-account.json}"
SRC_DIR="${SRC_DIR:-${REPO_ROOT}/src}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-120}"

# Pretty printing helpers
info() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

success() {
    echo -e "\033[1;32m[OK]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARN]\033[0m $*"
}

error() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
}

format_json() {
    if command -v jq >/dev/null 2>&1; then
        jq .
    else
        cat
    fi
}

ensure_deployments_config() {
    local target_env="${1:-${EMULATOR_ENV}}"
    local env_dir="${SRC_DIR}/main/apigee/environments/${target_env}"
    local template_file="${env_dir}/deployments.json.template"
    local config_file="${env_dir}/deployments.json"

    if [[ -f "${template_file}" ]]; then
        local project_id="${PROJECT_ID:-${GOOGLE_CLOUD_PROJECT:-${GCP_PROJECT:-}}}"
        if [[ -z "${project_id}" && -f "${EMULATOR_KEYS_DIR}/${EMULATOR_SA_KEY}" && -x "$(command -v jq 2>/dev/null)" ]]; then
            project_id="$(jq -r '.project_id // empty' "${EMULATOR_KEYS_DIR}/${EMULATOR_SA_KEY}" 2>/dev/null || true)"
        fi

        if [[ -n "${project_id}" ]]; then
            info "Configuring ${config_file} with project '${project_id}' from template..."
            sed "s/PROJECT_ID/${project_id}/g" "${template_file}" > "${config_file}"
        fi
    fi
}

is_container_running() {
    docker ps --format '{{.Names}}' | grep -Eq "^${EMULATOR_CONTAINER}$"
}

is_container_existing() {
    docker ps -a --format '{{.Names}}' | grep -Eq "^${EMULATOR_CONTAINER}$"
}

cmd_start() {
    local wait_flag=true
    if [[ "$1" == "--no-wait" ]]; then
        wait_flag=false
    fi

    mkdir -p "${EMULATOR_KEYS_DIR}"

    if is_container_running; then
        info "Emulator container '${EMULATOR_CONTAINER}' is already running."
    elif is_container_existing; then
        info "Starting existing stopped container '${EMULATOR_CONTAINER}'..."
        docker start "${EMULATOR_CONTAINER}" >/dev/null
    else
        info "Starting new Apigee Emulator container '${EMULATOR_CONTAINER}'..."
        local sa_env_args=()
        if [[ -f "${EMULATOR_KEYS_DIR}/${EMULATOR_SA_KEY}" ]]; then
            sa_env_args=(-e "GOOGLE_APPLICATION_CREDENTIALS=/emulator/keys/${EMULATOR_SA_KEY}")
        fi

        docker run -d \
            --name "${EMULATOR_CONTAINER}" \
            --privileged \
            -p "${EMULATOR_MGMT_PORT}:8080" \
            -p "${EMULATOR_RUNTIME_PORT}:8998" \
            -v "${EMULATOR_KEYS_DIR}:/emulator/keys" \
            "${sa_env_args[@]}" \
            "${EMULATOR_IMAGE}" >/dev/null
    fi

    if [[ "${wait_flag}" == "true" ]]; then
        cmd_wait
    fi
}

cmd_wait() {
    local url="http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/version"
    info "Waiting for Apigee Emulator to be ready at ${url} (timeout: ${TIMEOUT_SECONDS}s)..."

    local elapsed=0
    until curl -s -f "${url}" >/dev/null 2>&1; do
        if (( elapsed >= TIMEOUT_SECONDS )); then
            error "Timeout after ${TIMEOUT_SECONDS}s waiting for Apigee Emulator."
            error "Inspect logs with: docker logs ${EMULATOR_CONTAINER}"
            return 1
        fi
        sleep 3
        elapsed=$(( elapsed + 3 ))
        printf "."
    done
    echo ""
    success "Apigee Emulator is ready and accepting requests!"
}

cmd_deploy() {
    local target_env="${1:-${EMULATOR_ENV}}"
    local deploy_url="http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/deploy?environment=${target_env}"

    if ! is_container_running; then
        warn "Emulator container is not running. Starting it first..."
        cmd_start
    else
        # Quick healthcheck
        if ! curl -s -f "http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/version" >/dev/null 2>&1; then
            cmd_wait
        fi
    fi

    if [[ ! -d "${SRC_DIR}" ]]; then
        error "Source directory '${SRC_DIR}' not found!"
        return 1
    fi

    ensure_deployments_config "${target_env}"

    local tmp_dir
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "${tmp_dir}"' EXIT

    local bundle_zip="${tmp_dir}/src-bundle.zip"
    info "Packaging sources from '${SRC_DIR}'..."
    (cd "${SRC_DIR}/.." && zip -r -q "${bundle_zip}" "$(basename "${SRC_DIR}")")

    info "Deploying to emulator environment '${target_env}'..."
    local deploy_resp
    deploy_resp="$(curl -s -f -X POST "${deploy_url}" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@${bundle_zip}")"

    success "Proxy bundle deployed successfully: ${deploy_resp}"

    # Setup test data (e.g. KVMs, test products/apps) if available
    local test_data_dir="${SRC_DIR}/tests/${target_env}"
    if [[ -d "${test_data_dir}" ]]; then
        local test_zip="${tmp_dir}/test-data.zip"
        info "Packaging and loading test data from '${test_data_dir}'..."
        (cd "${test_data_dir}" && zip -r -q "${test_zip}" .)
        curl -s -f -X POST "http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/setup/tests" \
            -H "Content-Type: application/octet-stream" \
            --data-binary "@${test_zip}" >/dev/null
        success "Test data loaded successfully."
    fi

    echo ""
    cmd_status
}

cmd_status() {
    if ! is_container_running; then
        warn "Container '${EMULATOR_CONTAINER}' is not running."
        return 1
    fi

    info "Emulator Version & Features:"
    curl -s "http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/version" | format_json

    echo ""
    info "Deployed Proxies:"
    curl -s "http://localhost:${EMULATOR_MGMT_PORT}/v1/emulator/tree" | format_json
}

cmd_test() {
    local path="${1:-/gcpreleases/v1/echo}"
    local url="http://localhost:${EMULATOR_RUNTIME_PORT}${path}"
    info "Sending test request to ${url}..."
    curl -s -i "${url}"
}

cmd_logs() {
    docker logs -f "${EMULATOR_CONTAINER}"
}

cmd_stop() {
    if is_container_existing; then
        info "Stopping and removing container '${EMULATOR_CONTAINER}'..."
        docker rm -f "${EMULATOR_CONTAINER}" >/dev/null 2>&1 || true
        success "Container removed."
    else
        info "Container '${EMULATOR_CONTAINER}' does not exist."
    fi
}

cmd_restart() {
    cmd_stop
    cmd_start
}

cmd_help() {
    cat <<EOF
Apigee Emulator CLI

Usage:
  $(basename "$0") <command> [arguments]

Commands:
  start [--no-wait]    Start the emulator container (and wait until healthy)
  wait                 Wait until the emulator management API is healthy
  deploy [env]         Package src/ and deploy proxy bundle (default env: ${EMULATOR_ENV})
  status               Show version and list deployed proxies
  test [path]          Run a smoke test against http://localhost:${EMULATOR_RUNTIME_PORT}[path]
  logs                 Stream container logs
  stop                 Stop and remove the emulator container
  restart              Restart the emulator container
  help                 Show this help message

Environment Variables:
  EMULATOR_IMAGE        Docker image (default: ${EMULATOR_IMAGE})
  EMULATOR_CONTAINER    Container name (default: ${EMULATOR_CONTAINER})
  EMULATOR_MGMT_PORT    Management port on host (default: ${EMULATOR_MGMT_PORT})
  EMULATOR_RUNTIME_PORT Runtime proxy port on host (default: ${EMULATOR_RUNTIME_PORT})
  EMULATOR_ENV          Target environment name (default: ${EMULATOR_ENV})
  EMULATOR_KEYS_DIR     Cert/keys directory (default: ${EMULATOR_KEYS_DIR})
  EMULATOR_SA_KEY       Service Account JSON filename (default: ${EMULATOR_SA_KEY})
  SRC_DIR               Source code directory (default: ${SRC_DIR})
  TIMEOUT_SECONDS       Wait timeout in seconds (default: ${TIMEOUT_SECONDS})

Examples:
  # Start emulator and wait
  $0 start

  # Deploy current code to dev environment
  $0 deploy dev

  # Test an endpoint
  $0 test /gcpreleases/v1/echo

  # CI/CD pipeline step
  $0 start && $0 deploy dev && npm run integration-test
EOF
}

case "${1:-}" in
    start)
        shift
        cmd_start "$@"
        ;;
    wait)
        cmd_wait
        ;;
    deploy)
        shift
        cmd_deploy "$@"
        ;;
    status|tree)
        cmd_status
        ;;
    test)
        shift
        cmd_test "$@"
        ;;
    logs)
        cmd_logs
        ;;
    stop)
        cmd_stop
        ;;
    restart)
        shift
        cmd_restart "$@"
        ;;
    help|-h|--help)
        cmd_help
        ;;
    *)
        cmd_help
        exit 1
        ;;
esac
