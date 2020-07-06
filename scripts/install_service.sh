#!/bin/bash
set -e

BASEDIR=$(dirname $0)

SERVICE_NAME="openstack-networkd"
SRC_BIN_PATH="${BASEDIR}/../src/openstack-networkd.sh"
SRC_BIN_PATH_PYTHON="${BASEDIR}/../src/cloud_init_apply_net.py"
BIN_PATH="/usr/local/bin/openstack-networkd.sh"
BIN_PATH_PYTHON="/usr/local/bin/cloud_init_apply_net.py"
SRC_SERVICE_PATH="${BASEDIR}/../systemd/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

UDEV_RULES_FILE="/etc/udev/rules.d/90-openstack-networkd.rules"


systemctl stop "${SERVICE_NAME}" || true
systemctl disable "${SERVICE_NAME}" || true


cat > "${UDEV_RULES_FILE}" <<- EOM
ACTION=="add", SUBSYSTEMS=="net", RUN+="/bin/systemctl start openstack-networkd"
ACTION=="remove", SUBSYSTEMS=="net", RUN+="/bin/systemctl start openstack-networkd"
EOM

udevadm control --reload-rules

mkdir -p "/var/lib/openstack-networkd"
rm -f "/var/lib/openstack-networkd/openstack-networkd.log" || true
rm -f "/var/lib/openstack-networkd/network_data.json" || true
rm -f "/var/lib/openstack-networkd/old_network_data.json" || true

cp -f "${SRC_BIN_PATH}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"

cp -f "${SRC_BIN_PATH_PYTHON}" "${BIN_PATH_PYTHON}"
chmod +x "${BIN_PATH_PYTHON}"

cp -f "${SRC_SERVICE_PATH}" "${SERVICE_PATH}"
chmod 644 "${SERVICE_PATH}"

systemctl enable "${SERVICE_NAME}"
# systemctl start "${SERVICE_NAME}"
