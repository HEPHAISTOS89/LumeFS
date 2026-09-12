#!/bin/zsh

set -euo pipefail

readonly LAB_ID="LUMEFS_NFS_LAB_${UID}"
readonly LAB_ROOT="/private/var/tmp/com.hephaistos.LumeFS.nfs-lab.${UID}"
readonly EXPORT_DIR="${LAB_ROOT}/export"
readonly MOUNT_DIR="${LAB_ROOT}/mount"
readonly STATE_FILE="${LAB_ROOT}/state"
readonly BACKUP_FILE="/etc/exports.lumefs-backup-${UID}"
readonly BEGIN_MARKER="# BEGIN ${LAB_ID}"
readonly END_MARKER="# END ${LAB_ID}"
readonly USER_NAME="$(id -un)"

usage() {
    cat <<'EOF'
Usage: scripts/nfs_lab.sh <validate|status|setup|cleanup>

  validate  Check the generated export syntax without changing the system.
  status    Show whether the managed export, mount, and nfsd are present.
  setup     Create a read-only localhost NFSv3 lab. Requires:
            LUMEFS_NFS_LAB_CONFIRM=YES
  cleanup   Unmount and remove only the managed lab state.

This lab changes /etc/exports and nfsd state only during setup/cleanup.
It does not configure or prove pNFS.
EOF
}

require_command() {
    local command_path="$1"
    if [[ ! -x "${command_path}" ]]; then
        print -u2 "Missing required executable: ${command_path}"
        exit 127
    fi
}

require_tools() {
    require_command /sbin/nfsd
    require_command /sbin/mount
    require_command /sbin/mount_nfs
    require_command /sbin/umount
    require_command /usr/bin/awk
    require_command /usr/bin/id
    require_command /usr/sbin/rpcinfo
}

guard_identity() {
    if [[ ! "${UID}" =~ '^[0-9]+$' ]]; then
        print -u2 "Unexpected numeric user id: ${UID}"
        exit 2
    fi

    if [[ ! "${USER_NAME}" =~ '^[A-Za-z0-9._-]+$' ]]; then
        print -u2 "Unsupported local user name for -mapall."
        exit 2
    fi

    local expected_root="/private/var/tmp/com.hephaistos.LumeFS.nfs-lab.${UID}"
    if [[ "${LAB_ROOT}" != "${expected_root}" ]]; then
        print -u2 "Lab root guard failed."
        exit 2
    fi
}

guard_directory() {
    local path="$1"

    if [[ -L "${path}" ]]; then
        print -u2 "Refusing symbolic-link lab path: ${path}"
        exit 2
    fi

    if [[ -e "${path}" ]]; then
        local owner
        owner="$(/usr/bin/stat -f '%u' "${path}")"
        if [[ "${owner}" != "${UID}" ]]; then
            print -u2 "Refusing lab path owned by uid ${owner}: ${path}"
            exit 2
        fi
    fi
}

render_managed_block() {
    cat <<EOF
${BEGIN_MARKER}
${EXPORT_DIR} -ro -mapall=${USER_NAME} 127.0.0.1
${END_MARKER}
EOF
}

strip_managed_block() {
    local input_file="$1"
    local output_file="$2"

    /usr/bin/awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
        $0 == begin {
            if (inside || seen_begin) exit 41
            inside = 1
            seen_begin = 1
            next
        }
        $0 == end {
            if (!inside || seen_end) exit 42
            inside = 0
            seen_end = 1
            next
        }
        !inside { print }
        END {
            if (inside || seen_begin != seen_end) exit 43
        }
    ' "${input_file}" > "${output_file}"
}

is_lab_mounted() {
    /sbin/mount | /usr/bin/grep -Fq " on ${MOUNT_DIR} (nfs"
}

has_other_exports() {
    [[ -e /etc/exports ]] || return 1
    # If an existing file cannot be inspected, leave nfsd running rather than guessing.
    [[ -r /etc/exports ]] || return 0
    /usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { found = 1 }
        END { exit found ? 0 : 1 }
    ' /etc/exports
}

daemon_is_running() {
    /sbin/nfsd status 2>&1 | /usr/bin/grep -Fq 'nfsd is running'
}

wait_for_nfs_service() {
    local attempt
    for attempt in {1..100}; do
        if /usr/sbin/rpcinfo -t 127.0.0.1 nfs 3 >/dev/null 2>&1; then
            return 0
        fi
        /bin/sleep 0.1
    done

    print -u2 "NFSv3 did not become ready on loopback within 10 seconds."
    return 1
}

managed_export_exists() {
    [[ -r /etc/exports ]] && /usr/bin/grep -Fq "${BEGIN_MARKER}" /etc/exports
}

prior_daemon_state() {
    [[ -r "${STATE_FILE}" ]] || return 1

    local value
    value="$(/usr/bin/awk -F= '$1 == "daemon_was_running" { print $2 }' "${STATE_FILE}")"
    case "${value}" in
        0) print 0 ;;
        1) print 1 ;;
        *)
            print -u2 "Refusing malformed state file: ${STATE_FILE}"
            return 2
            ;;
    esac
}

prior_exports_state() {
    [[ -r "${STATE_FILE}" ]] || return 1

    local value
    value="$(/usr/bin/awk -F= '$1 == "exports_was_present" { print $2 }' "${STATE_FILE}")"
    case "${value}" in
        0) print 0 ;;
        1) print 1 ;;
        *)
            print -u2 "Refusing malformed exports state in: ${STATE_FILE}"
            return 2
            ;;
    esac
}

validate() {
    local temporary_dir
    temporary_dir="$(mktemp -d "/private/var/tmp/lumefs-nfs-validate.XXXXXX")"

    mkdir -p "${temporary_dir}/export"
    {
        print "# LumeFS validation only"
        print "${temporary_dir}/export -ro -mapall=${USER_NAME} 127.0.0.1"
    } > "${temporary_dir}/exports"

    local result=0
    /sbin/nfsd -F "${temporary_dir}/exports" checkexports || result=$?

    rm -f "${temporary_dir}/exports"
    rmdir "${temporary_dir}/export"
    rmdir "${temporary_dir}"

    if (( result != 0 )); then
        return "${result}"
    fi
    print "Export syntax validated. No system configuration was changed."
}

status() {
    print "Lab root: ${LAB_ROOT}"

    if managed_export_exists; then
        print "Managed export: present"
    else
        print "Managed export: absent"
    fi

    if is_lab_mounted; then
        print "Lab mount: present"
    else
        print "Lab mount: absent"
    fi

    /sbin/nfsd status 2>&1 || true
}

require_setup_confirmation() {
    if [[ "${LUMEFS_NFS_LAB_CONFIRM:-}" != "YES" ]]; then
        print -u2 "Setup refused. Review docs/NFS_LAB.md, then set LUMEFS_NFS_LAB_CONFIRM=YES."
        exit 2
    fi
}

prepare_directories() {
    guard_directory "${LAB_ROOT}"
    mkdir -p -m 700 "${LAB_ROOT}"
    guard_directory "${LAB_ROOT}"

    mkdir -p -m 700 "${EXPORT_DIR}" "${MOUNT_DIR}"
    guard_directory "${EXPORT_DIR}"
    guard_directory "${MOUNT_DIR}"

    print "LumeFS localhost NFS lab fixture." > "${EXPORT_DIR}/README.txt"
    chmod 600 "${EXPORT_DIR}/README.txt"
}

write_state_once() {
    if [[ -e "${STATE_FILE}" ]]; then
        return
    fi

    local was_running=0
    if daemon_is_running; then
        was_running=1
    fi

    local exports_was_present=0
    if [[ -e /etc/exports ]]; then
        exports_was_present=1
    fi

    {
        print "daemon_was_running=${was_running}"
        print "exports_was_present=${exports_was_present}"
    } > "${STATE_FILE}"
    chmod 600 "${STATE_FILE}"
}

install_managed_export() {
    local current_file="${LAB_ROOT}/exports.current"
    local stripped_file="${LAB_ROOT}/exports.stripped"
    local candidate_file="${LAB_ROOT}/exports.candidate"

    if sudo test -f /etc/exports; then
        sudo /bin/cat /etc/exports > "${current_file}"
    else
        : > "${current_file}"
    fi
    chmod 600 "${current_file}"

    strip_managed_block "${current_file}" "${stripped_file}"
    {
        /bin/cat "${stripped_file}"
        render_managed_block
    } > "${candidate_file}"
    chmod 600 "${candidate_file}"

    sudo /sbin/nfsd -F "${candidate_file}" checkexports

    if ! sudo test -e "${BACKUP_FILE}"; then
        if sudo test -e /etc/exports; then
            sudo /bin/cp -p /etc/exports "${BACKUP_FILE}"
        else
            sudo /usr/bin/touch "${BACKUP_FILE}"
            sudo /bin/chmod 600 "${BACKUP_FILE}"
        fi
    fi

    sudo /usr/bin/tee /etc/exports < "${candidate_file}" >/dev/null
    sudo /bin/chmod 644 /etc/exports
    rm -f "${current_file}" "${stripped_file}" "${candidate_file}"
}

setup() {
    require_setup_confirmation
    prepare_directories
    write_state_once

    if is_lab_mounted && managed_export_exists; then
        print "LumeFS NFS lab is already set up."
        status
        return
    fi

    sudo -v
    install_managed_export

    if daemon_is_running; then
        sudo /sbin/nfsd update
    else
        sudo /sbin/nfsd start
    fi

    wait_for_nfs_service

    if ! is_lab_mounted; then
        sudo /sbin/mount_nfs \
            -o vers=3,tcp,inet,resvport,soft,intr,retrycnt=0,timeo=10,retrans=2,deadtimeout=15,nolocks,noexec,nosuid,nodev,nobrowse \
            "127.0.0.1:${EXPORT_DIR}" \
            "${MOUNT_DIR}"
    fi

    print "LumeFS read-only localhost NFSv3 lab is ready."
    status
    print "Cleanup command: ./scripts/nfs_lab.sh cleanup"
}

remove_managed_export() {
    local current_file="${LAB_ROOT}/exports.current"
    local candidate_file="${LAB_ROOT}/exports.candidate"

    if ! sudo test -f /etc/exports; then
        return
    fi

    sudo /bin/cat /etc/exports > "${current_file}"
    chmod 600 "${current_file}"
    strip_managed_block "${current_file}" "${candidate_file}"
    chmod 600 "${candidate_file}"

    sudo /sbin/nfsd -F "${candidate_file}" checkexports
    local exports_was_present
    exports_was_present="$(prior_exports_state)"

    if [[ "${exports_was_present}" == "0" ]] && ! /usr/bin/awk '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        { found = 1 }
        END { exit found ? 0 : 1 }
    ' "${candidate_file}"; then
        sudo /bin/rm -f /etc/exports
    else
        sudo /usr/bin/tee /etc/exports < "${candidate_file}" >/dev/null
        sudo /bin/chmod 644 /etc/exports
    fi
    rm -f "${current_file}" "${candidate_file}"
}

remove_lab_directories() {
    [[ "${LAB_ROOT}" == "/private/var/tmp/com.hephaistos.LumeFS.nfs-lab.${UID}" ]] || return 2

    rm -f \
        "${EXPORT_DIR}/README.txt" \
        "${STATE_FILE}" \
        "${LAB_ROOT}/exports.current" \
        "${LAB_ROOT}/exports.stripped" \
        "${LAB_ROOT}/exports.candidate"

    rmdir "${MOUNT_DIR}" 2>/dev/null || true
    rmdir "${EXPORT_DIR}" 2>/dev/null || true
    rmdir "${LAB_ROOT}" 2>/dev/null || true
}

cleanup() {
    guard_directory "${LAB_ROOT}"

    if is_lab_mounted; then
        print "Unmounting ${MOUNT_DIR}"
        if ! sudo /sbin/umount "${MOUNT_DIR}"; then
            print -u2 "Normal unmount failed. Close users of the mount and run cleanup again."
            return 1
        fi
    fi

    local should_stop_daemon=0
    if [[ -r "${STATE_FILE}" ]]; then
        local prior_state
        prior_state="$(prior_daemon_state)" || return $?
        if [[ "${prior_state}" == "0" ]]; then
            should_stop_daemon=1
        fi
    fi

    if managed_export_exists; then
        sudo -v
        remove_managed_export
        if daemon_is_running; then
            sudo /sbin/nfsd update
        fi
    fi

    if (( should_stop_daemon == 1 )) && daemon_is_running && ! has_other_exports; then
        sudo /sbin/nfsd stop
    fi

    if [[ -e "${BACKUP_FILE}" ]]; then
        sudo /bin/rm -f "${BACKUP_FILE}"
    fi

    remove_lab_directories
    print "LumeFS NFS lab cleanup complete."
}

main() {
    require_tools
    guard_identity

    case "${1:-}" in
        validate) validate ;;
        status) status ;;
        setup) setup ;;
        cleanup) cleanup ;;
        *)
            usage
            exit 2
            ;;
    esac
}

main "$@"
