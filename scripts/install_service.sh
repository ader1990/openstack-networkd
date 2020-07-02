#!/bin/bash
set -e

BASEDIR=$(dirname $0)

SERVICE_NAME="openstack-networkd"
SRC_BIN_PATH="${BASEDIR}/../src/openstack-networkd.sh"
BIN_PATH="/usr/local/bin/openstack-networkd.sh"
SRC_SERVICE_PATH="${BASEDIR}/../systemd/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

systemctl stop "${SERVICE_NAME}" || true
systemctl disable "${SERVICE_NAME}" || true

mkdir -p "/var/lib/openstack-networkd"
rm -f "/var/lib/openstack-networkd/openstack-networkd.log" || true
rm -f "/var/lib/openstack-networkd/network_data.json" || true
rm -f "/var/lib/openstack-networkd/old_network_data.json" || true

cp -f "${SRC_BIN_PATH}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"

cp -f "${SRC_SERVICE_PATH}" "${SERVICE_PATH}"
chmod 644 "${SERVICE_PATH}"

systemctl enable "${SERVICE_NAME}"
systemctl start "${SERVICE_NAME}"
