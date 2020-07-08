#!/bin/bash

function run_as_cloud_init_wrapper {
    if [[ "${ACTION}" == "" ]]; then
        write_log_info "ACTION variable is not set, not running under udev."
    else
        export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
        write_log_info "Running hook for event '${ACTION}' for NIC '${ID_NET_NAME}'."
        export ACTION="${ACTION}"
        export ID_NET_NAME="${ID_NET_NAME}"
    fi

    python_path=$(which "python3")
    "${python_path}" -c 'import cloudinit'
    if [ $? -ne 0 ]; then
        write_log_info "Cloud-init is not installed as a python3 package"
        python_path=$(which "python2" || which "python")
        "${python_path}" -c 'import cloudinit'
        if [ $? -ne 0 ]; then
            write_log_error "Cloud-init is not installed as a python2 package"
            rm -f "${CURRENT_LOCK_FILE}" || true
            exit 1
        fi
    fi

    "${python_path}" "/usr/local/bin/cloud_init_apply_net.py"
    if [ $? -ne 0 ]; then
        write_log_error "Failed to set networking using cloud init wrapper"
    else
        write_log_info "Cloud init wrapper set the networking config"
    fi

    rm -f "${CURRENT_LOCK_FILE}" || true
}

run_as_cloud_init_wrapper