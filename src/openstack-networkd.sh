#!/bin/bash
ROOT_DIR="/var/lib/openstack-networkd"
LOG_FILE="${ROOT_DIR}/openstack-networkd.log"

MAGIC_URL="http://169.254.169.254/openstack/latest/network_data.json"
OLD_NETWORK_DATA="${ROOT_DIR}/old_network_data.json"
NETWORK_DATA="${ROOT_DIR}/network_data.json"

CLOUD_INIT_CONFIG_FILE="/etc/cloud/cloud.cfg.d/90_dpkg.cfg"

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
    msg="${curr_date}: OpenStack Networkd (action:${ACTION}, ${2}): ${1}"
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
EOM
    rm -rf "/run/cloud-init"
    cloud-init clean --logs

    retries=0
    max_retries=10
    while :
    do
        cloud_init_out=$(/usr/bin/cloud-init init 2>&1)
        /usr/bin/cloud-init status
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


touch "${OLD_NETWORK_DATA}"
touch "${NETWORK_DATA}"

function run_as_service {
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

function run_as_udev {
    rerun_cloudinit
}


run_as_udev