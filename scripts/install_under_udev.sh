#!/bin/bash
BASEDIR=$(dirname $0)

SRC_BIN_PATH="${BASEDIR}/../src/openstack-networkd.sh"
SRC_BIN_PATH_PYTHON="${BASEDIR}/../src/cloud_init_apply_net.py"
BIN_PATH="/usr/local/bin/openstack-networkd.sh"
BIN_PATH_PYTHON="/usr/local/bin/cloud_init_apply_net.py"

UDEV_RULES_FILE="/etc/udev/rules.d/90-openstack-networkd.rules"


cp -f "${SRC_BIN_PATH}" "${BIN_PATH}"
chmod +x "${BIN_PATH}"

cp -f "${SRC_BIN_PATH_PYTHON}" "${BIN_PATH_PYTHON}"
chmod +x "${BIN_PATH_PYTHON}"

cat > "${UDEV_RULES_FILE}" <<- EOM
ACTION=="add", SUBSYSTEM=="net", RUN+="/usr/sbin/service openstack-networkd start"
ACTION=="remove", SUBSYSTEM=="net", RUN+="/usr/sbin/service openstack-networkd start"
EOM
udevadm control --reload-rules
