#!/bin/bash
BASEDIR=$(dirname $0)

SERVICE_NAME="openstack-networkd"
SRC_BIN_PATH="${BASEDIR}/../src/openstack-networkd.sh"
SRC_BIN_PATH_PYTHON="${BASEDIR}/../src/cloud_init_apply_net.py"
BIN_PATH="/usr/local/bin/openstack-networkd.sh"
BIN_PATH_PYTHON="/usr/local/bin/cloud_init_apply_net.py"
SRC_SERVICE_PATH="${BASEDIR}/../systemd/${SERVICE_NAME}.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
UPSTART_CONF_DIR="/etc/init/"
UPSTART_SERVICE_FILE="${BASEDIR}/openstack-networkd.conf"

UDEV_RULES_FILE="/etc/udev/rules.d/90-openstack-networkd.rules"

is_upstart="false"
initctl --version
if [ $? -ne 0 ]; then
    is_upstart="true"
fi

is_systemd="false"
systemctl --version
if [ $? -ne 0 ]; then
    is_systemd="true"
fi

if [[ "${is_upstart}" == "true" ]]; then
    service "${SERVICE_NAME}" stop
    cp -f "${UPSTART_SERVICE_FILE}" "${UPSTART_CONF_DIR}"
fi

if [[ "${is_systemd}" == "true" ]]; then
    systemctl stop "${SERVICE_NAME}" || true
    systemctl disable "${SERVICE_NAME}" || true
fi

cat > "${UDEV_RULES_FILE}" <<- EOM
ACTION=="add", SUBSYSTEMS=="net", RUN+="/usr/sbin/service openstack-networkd start"
ACTION=="remove", SUBSYSTEMS=="net", RUN+="/usr/sbin/service openstack-networkd start"
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

if [[ "${is_systemd}" == "true" ]]; then
    systemctl enable "${SERVICE_NAME}"
fi

