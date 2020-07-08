#!/bin/bash
ROOT_DIR="/var/lib/openstack-networkd"
LOG_FILE="${ROOT_DIR}/openstack-networkd.log"

MAGIC_URL="http://169.254.169.254/openstack/latest/network_data.json"
OLD_NETWORK_DATA="${ROOT_DIR}/old_network_data.json"
NETWORK_DATA="${ROOT_DIR}/network_data.json"

CLOUD_INIT_CONFIG_FILE="/tmp/80_dpkg.cfg"

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

function rerun_cloudinit {
    cat > "${CLOUD_INIT_CONFIG_FILE}" <<- EOM
datasource:
  OpenStack:
    apply_network_config: True
datasource_list:
  - OpenStack
system_info:
  paths:
    cloud_dir: "/var/lib/cloud-openstack"
EOM
    cloud-init --file "${CLOUD_INIT_CONFIG_FILE}" clean --logs

    retries=0
    max_retries=10
    while :
    do
        cloud_init_out=$(/usr/bin/cloud-init --file "${CLOUD_INIT_CONFIG_FILE}" init 2>&1)
        if [ $? -eq 0 ]; then
            write_log_info "Cloud-init ran successfully"
            break
        else
            write_log_error "Cloud-init exited unsuccessfully: ${cloud_init_out}"
        fi

        ((retries=retries+1))

        if [ $max_retries -eq $retries ]; then
            write_log_error "Cloud-init failed ${max_retries} times. Exiting with error code 1"
            exit 1
        fi
    done

    /usr/sbin/netplan apply || true
    /usr/sbin/service networking restart || true
}


mkdir -p "${ROOT_DIR}"
touch "${OLD_NETWORK_DATA}"
touch "${NETWORK_DATA}"

function run_as_poll_service {
    while :
    do
        write_log_debug "Polling for updated network data..."

        curl_out=$(/usr/bin/curl --connect-timeout 10 -s "${MAGIC_URL}" -o "${NETWORK_DATA}" 2>&1)
        if [ $? -ne 0 ]; then
            write_log_error "Curl exited unsuccessfully: ${curl_out}"
            exit 1
        fi

        net_data_json=$(/usr/bin/jq --sort-keys . "${NETWORK_DATA}")
        if [ $? -ne 0 ]; then
            write_log_error "jq failed to parse net_data_json"
            exit 1
        fi
        old_net_data_json=$(/usr/bin/jq --sort-keys . "${OLD_NETWORK_DATA}")
        if [ $? -ne 0 ]; then
            write_log_error "jq failed to parse old_net_data_json"
            exit 1
        fi

        if [[ "${net_data_json}" != "" ]]; then
            if [[ "${net_data_json}" == "${old_net_data_json}" ]]; then
                write_log_debug "Network data is the same"
            else
                write_log_debug "New network data: ${net_data_json}"

                cp -f "${NETWORK_DATA}" "${OLD_NETWORK_DATA}"
                if [[ "${old_net_data_json}" != "" ]]; then
                    if [ ${#old_net_data_json} -gt ${#net_data_json} ]; then
                        write_log_info "Less network information received"
                    else
                        write_log_info "More network information received"
                    fi
                    rerun_cloudinit
                fi
            fi
        fi

        sleep 5
    done
}

function run_as_udev_service {
    rerun_cloudinit
}

function run_as_cloud_init_wrapper {
    LOCK_FILE_REMOVE="/tmp/cloud_init_wrapper_remove"
    LOCK_FILE_ADD="/tmp/cloud_init_wrapper_add"
    CURRENT_LOCK_FILE="/tmp/cloud_init_wrapper_${ACTION}"


    if [[ "${ACTION}" == "" ]]; then
        write_log_info "ACTION variable is not set, not running under udev."
    else
        export PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin
        write_log_info "Running on nic ${ACTION}. Checking if another action is running..."

        retries=0
        max_retries=10
        while :
        do
            running_action=""


            if [[ "${ACTION}" == "remove" ]]; then
                if [ -e "${LOCK_FILE_ADD}" ]; then
                    running_action="add"
                else
                    break
                fi
            fi

            if [[ "${ACTION}" == "add" ]]; then
                if [ -e "${LOCK_FILE_REMOVE}" ]; then
                    running_action="remove"
                else
                    break
                fi
                running_action="remove"
            fi

            ((retries=retries+1))
            if [ $retries -eq $max_retries ]; then
                write_log_error "Lock file for action ${running_action} still present."
                exit 1
            fi

            write_log_info "Action ${running_action} still running. Waiting..."

            sleep 5
        done
    fi

    touch "${CURRENT_LOCK_FILE}"
    python_path=$(which "python3")
    "${python_path}" -c 'import cloudinit'
    if [ $? -ne 0 ]; then
        write_log_info "Cloud-init is not installed as a ${python_path} package"
        python_path=$(which "python2" || which "python")
        "${python_path}" -c 'import cloudinit'
        if [ $? -ne 0 ]; then
            write_log_error "Cloud-init is not installed as a ${python_path} package"
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