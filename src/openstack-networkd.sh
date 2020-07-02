#!/bin/bash
set -xe

ROOT_DIR="/var/lib/openstack-networkd"
LOG_FILE="${ROOT_DIR}/openstack-networkd.log"

function write_log {
    curr_date=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${curr_date}: ${1}" >> $LOG_FILE
}


while :
do
    write_log "Doing nothing..."
    sleep 5
done