#!/bin/bash

function write_log_info {
    write_log "${1}" "info"
}

function write_log_debug {
    write_log "${1}" "debug"
}

function write_log_error {
    write_log "${1}" "error"
}

function write_log {
    curr_date=$(date '+%Y-%m-%d %H:%M:%S')
    msg="${2}: openstack-networkd: ${curr_date}: ${1}"
    echo "${msg}" >> $LOG_FILE

    if [[ "${2}" == "info" || "${2}" == "error" ]]; then
        # Log to serial console
        echo "${msg}" > /dev/ttyS0
    fi
}

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
            exit 1
        fi
    fi

    cloud_init_out=$("${python_path}" "/usr/local/bin/cloud_init_apply_net.py" 2>&1)
    if [ $? -ne 0 ]; then
        write_log_error "Failed to set networking using cloud init wrapper. Error log: ${cloud_init_out}"
    else
        write_log_info "Cloud init wrapper set the networking config"
    fi
}

run_as_cloud_init_wrapper