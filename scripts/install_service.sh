#!/bin/bash
set -xe

BASEDIR=$(dirname $0)

SERVICE_NAME="openstack-networkd"
SRC_BIN_PATH="${BASEDIR}/src/openstack-networkd.sh"
BIN_PATH="/usr/local/bin/openstack-networkd.sh"
SRC_SERVICE_PATH="${BASEDIR}/systemd/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

cp "${BIN_PATH}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"

cp "${SRC_SERVICE_PATH}" "${SERVICE_PATH}"
chmod 644 "${SERVICE_PATH}"

systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"
