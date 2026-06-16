#!/usr/bin/env bash
set -Eeuo pipefail

source "$(dirname "${0}")/lib/common.sh"

# pvc-cp.sh — Copy files to/from a PVC using a temporary pod
#
# Usage:
#   pvc-cp.sh list   <pvc>[:<path>] [--namespace <ns>]
#   pvc-cp.sh copy   <local-dir>    <pvc>:<remote-path> [--namespace <ns>]
#   pvc-cp.sh chown  <owner>        <pvc>:<remote-path> [--namespace <ns>]
#
# Examples:
#   pvc-cp.sh list ghost-laur:/data/images --namespace comm
#   pvc-cp.sh copy /tmp/images ghost-laur:/data/images --namespace comm
#   pvc-cp.sh chown 1000:1000 ghost-laur:/images --namespace comm

readonly HELPER_IMAGE="docker.io/library/alpine:latest"
readonly HELPER_PREFIX="pvc-helper"

function usage() {
    cat <<EOF
Usage:
  $(basename "$0") list   REMOTE [--namespace NS]
  $(basename "$0") copy   LOCAL  REMOTE [--namespace NS]
  $(basename "$0") chown  OWNER  REMOTE [--namespace NS]

REMOTE format: <pvc-name>[:<path>]
  - pvc-name: name of the PersistentVolumeClaim
  - path:     optional path within the PVC (default: /)

OWNER format: <uid>[:<gid>]
  - e.g. 1000:1000, 1000, root:root

Examples:
  $(basename "$0") list ghost-laur --namespace comm
  $(basename "$0") list ghost-laur:/data/images --namespace comm
  $(basename "$0") copy /tmp/images ghost-laur:/data/images --namespace comm
  $(basename "$0") chown 1000:1000 ghost-laur:/images --namespace comm
EOF
    exit 1
}

function parse_remote() {
    local remote="$1"
    # Split on first colon
    PVC_NAME="${remote%%:*}"
    PVC_PATH="${remote#*:}"
    if [[ "${PVC_PATH}" == "${PVC_NAME}" ]]; then
        PVC_PATH="/"
    fi
    # Ensure path starts with /
    [[ "${PVC_PATH}" == /* ]] || PVC_PATH="/${PVC_PATH}"
}

function create_helper_pod() {
    local pvc="$1"
    local ns="$2"
    local pod_name="${HELPER_PREFIX}-${pvc}-$$"

    log info "Creating helper pod" "pod=${pod_name}" "namespace=${ns}" "pvc=${pvc}" >&2

    kubectl run "${pod_name}" \
        --namespace "${ns}" \
        --image "${HELPER_IMAGE}" \
        --restart=Never \
        --overrides="{
            \"spec\": {
                \"containers\": [{
                    \"name\": \"helper\",
                    \"image\": \"${HELPER_IMAGE}\",
                    \"command\": [\"sleep\", \"3600\"],
                    \"volumeMounts\": [{\"name\": \"data\", \"mountPath\": \"/mnt/pvc\"}]
                }],
                \"volumes\": [{
                    \"name\": \"data\",
                    \"persistentVolumeClaim\": {\"claimName\": \"${pvc}\"}
                }]
            }
        }" \
        >/dev/null 2>&1

    log info "Waiting for helper pod to be ready" >&2
    kubectl wait --namespace "${ns}" --for=condition=Ready "pod/${pod_name}" --timeout=120s >/dev/null 2>&1

    echo "${pod_name}"
}

function delete_helper_pod() {
    local pod_name="$1"
    local ns="$2"
    log info "Cleaning up helper pod" "pod=${pod_name}"
    kubectl delete pod --namespace "${ns}" "${pod_name}" --force --grace-period=0 >/dev/null 2>&1 || true
}

function do_list() {
    local remote="$1"
    local ns="$2"

    parse_remote "${remote}"

    log info "Listing PVC contents" "pvc=${PVC_NAME}" "path=${PVC_PATH}" "namespace=${ns}"

    # Verify PVC exists
    if ! kubectl get pvc --namespace "${ns}" "${PVC_NAME}" >/dev/null 2>&1; then
        log error "PVC not found" "pvc=${PVC_NAME}" "namespace=${ns}"
        exit 1
    fi

    local pod_name
    pod_name=$(create_helper_pod "${PVC_NAME}" "${ns}")
    trap "delete_helper_pod '${pod_name}' '${ns}'" EXIT

    log info "Contents of ${PVC_NAME}:${PVC_PATH}"
    echo "---"
    kubectl exec --namespace "${ns}" "${pod_name}" -- ls -la "/mnt/pvc${PVC_PATH}" 2>&1 || {
        log error "Path not found on PVC" "path=${PVC_PATH}"
        exit 1
    }
}

function do_copy() {
    local local_dir="$1"
    local remote="$2"
    local ns="$3"

    parse_remote "${remote}"

    # Validate local directory
    if [[ ! -d "${local_dir}" ]]; then
        log error "Local directory does not exist" "path=${local_dir}"
        exit 1
    fi

    # Verify PVC exists
    if ! kubectl get pvc --namespace "${ns}" "${PVC_NAME}" >/dev/null 2>&1; then
        log error "PVC not found" "pvc=${PVC_NAME}" "namespace=${ns}"
        exit 1
    fi

    local pod_name
    pod_name=$(create_helper_pod "${PVC_NAME}" "${ns}")
    trap "delete_helper_pod '${pod_name}' '${ns}'" EXIT

    # Ensure remote directory exists
    kubectl exec --namespace "${ns}" "${pod_name}" -- mkdir -p "/mnt/pvc${PVC_PATH}" >/dev/null 2>&1

    # Count local files
    local file_count
    file_count=$(find "${local_dir}" -type f | wc -l)
    log info "Copying files to PVC" "source=${local_dir}" "dest=${PVC_NAME}:${PVC_PATH}" "files=${file_count}"

    # Build remote file size map in a single kubectl exec call
    log info "Building remote file index..."
    declare -A remote_sizes=()
    local index_output
    index_output=$(kubectl exec --namespace "${ns}" "${pod_name}" -- \
        find "/mnt/pvc${PVC_PATH}" -type f -printf '%s\t%p\n' 2>/dev/null || true)
    if [[ -n "${index_output}" ]]; then
        while IFS=$'\t' read -r size path; do
            local rel="${path#/mnt/pvc${PVC_PATH}/}"
            remote_sizes["${rel}"]="${size}"
        done <<< "${index_output}"
    fi
    log info "Remote index built" "remote_files=${#remote_sizes[@]}"

    # Determine which files need copying (missing or different size)
    local copy_list
    copy_list=$(mktemp)
    trap "rm -f '${copy_list}'; delete_helper_pod '${pod_name}' '${ns}'" EXIT

    local skipped=0
    while IFS= read -r -d '' file; do
        local rel_path="${file#"${local_dir}"}"
        rel_path="${rel_path#/}"

        local local_size
        local_size=$(stat --printf='%s' "${file}" 2>/dev/null || stat -f '%z' "${file}" 2>/dev/null)

        local remote_size="${remote_sizes["${rel_path}"]:-}"
        if [[ -n "${remote_size}" && "${local_size}" == "${remote_size}" ]]; then
            skipped=$((skipped + 1))
            continue
        fi

        # Write relative path to copy list
        echo "${rel_path}" >> "${copy_list}"
    done < <(find "${local_dir}" -type f -print0)

    local to_copy
    to_copy=$(wc -l < "${copy_list}" | tr -d ' ')

    if [[ "${to_copy}" -eq 0 ]]; then
        log info "All files already up to date, nothing to copy"
        log info "Copy complete" "copied=0" "skipped=${skipped}" "failed=0" "total=${file_count}"
        return 0
    fi

    log info "Transferring files via tar stream" "to_copy=${to_copy}" "skipped=${skipped}"

    # Stream files as a tar archive into the pod (single kubectl exec call)
    if tar -cf - -C "${local_dir}" -T "${copy_list}" | \
        kubectl exec -i --namespace "${ns}" "${pod_name}" -- \
        tar -xf - -C "/mnt/pvc${PVC_PATH}"; then
        log info "Copy complete" "copied=${to_copy}" "skipped=${skipped}" "failed=0" "total=${file_count}"
    else
        log error "Tar stream transfer failed"
        log info "Copy complete" "copied=0" "skipped=${skipped}" "failed=${to_copy}" "total=${file_count}"
        exit 1
    fi
}

function do_chown() {
    local owner="$1"
    local remote="$2"
    local ns="$3"

    parse_remote "${remote}"

    log info "Changing ownership on PVC" "owner=${owner}" "pvc=${PVC_NAME}" "path=${PVC_PATH}" "namespace=${ns}"

    # Verify PVC exists
    if ! kubectl get pvc --namespace "${ns}" "${PVC_NAME}" >/dev/null 2>&1; then
        log error "PVC not found" "pvc=${PVC_NAME}" "namespace=${ns}"
        exit 1
    fi

    local pod_name
    pod_name=$(create_helper_pod "${PVC_NAME}" "${ns}")
    trap "delete_helper_pod '${pod_name}' '${ns}'" EXIT

    # Verify path exists
    if ! kubectl exec --namespace "${ns}" "${pod_name}" -- test -e "/mnt/pvc${PVC_PATH}" 2>/dev/null; then
        log error "Path not found on PVC" "path=${PVC_PATH}"
        exit 1
    fi

    # Run chown recursively
    log info "Running chown -R ${owner} on ${PVC_PATH}"
    kubectl exec --namespace "${ns}" "${pod_name}" -- chown -R "${owner}" "/mnt/pvc${PVC_PATH}" 2>&1

    log info "Ownership changed successfully"
}

function main() {
    if [[ $# -lt 2 ]]; then
        usage
    fi

    local action="$1"
    shift

    local namespace="default"
    local positional=()

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --namespace|-n)
                namespace="$2"
                shift 2
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    check_cli kubectl

    case "${action}" in
        list)
            if [[ ${#positional[@]} -lt 1 ]]; then
                log error "Missing REMOTE argument"
                usage
            fi
            do_list "${positional[0]}" "${namespace}"
            ;;
        copy)
            if [[ ${#positional[@]} -lt 2 ]]; then
                log error "Missing LOCAL and/or REMOTE arguments"
                usage
            fi
            do_copy "${positional[0]}" "${positional[1]}" "${namespace}"
            ;;
        chown)
            if [[ ${#positional[@]} -lt 2 ]]; then
                log error "Missing OWNER and/or REMOTE arguments"
                usage
            fi
            do_chown "${positional[0]}" "${positional[1]}" "${namespace}"
            ;;
        *)
            log error "Unknown action: ${action}"
            usage
            ;;
    esac
}

main "$@"
