# Copyright 2020 Cloudbase Solutions Srl
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

import json
import os
import time

from cloudinit import log as logging
from cloudinit import stages
from cloudinit import url_helper
from cloudinit import util

from cloudinit.sources.helpers import openstack

MAGIC_URL = "http://169.254.169.254/openstack/latest/network_data.json"
LEGACY_MAGIC_URL = "http://169.254.169.254/openstack/content/0000"


def retry_decorator(max_retry_count=5, sleep_time=5):
    """Retries invoking the decorated method"""

    def wrapper(f):
        def inner(*args, **kwargs):
            try_count = 0

            while True:
                try:
                    return f(*args, **kwargs)
                except Exception:
                    if try_count == max_retry_count:
                        raise

                    try_count = try_count + 1
                    time.sleep(sleep_time)
        return inner
    return wrapper


def is_cloud_init_running():
    try:
        return util.subp(["ps", "--no-headers", "-fC", "cloud-init"])
    except Exception:
        pass


def try_reset_network(distro_name, reset_async=False):
    # required on Ubuntu 18.04
    try:
        util.subp(["netplan", "apply"])
        return
    except Exception:
        pass

    if distro_name == "debian" or distro_name == "ubuntu":
        try:
            util.subp(["systemctl", "stop", "networking"])
        except Exception:
            pass
        try:
            args = ["systemctl", "start", "networking"]
            if reset_async:
                args += ["--no-block"]
            util.subp(args)
            return
        except Exception:
            pass

    if distro_name == "rhel" or distro_name == "centos":
        try:
            util.subp(["service", "network", "restart"])
            return
        except Exception:
            pass


def set_manual_interface(interface_name):
    interfaces_file = "/etc/network/interfaces.d/50-cloud-init.cfg"
    with open(interfaces_file, 'r') as file:
        interfaces = file.read()

    interfaces = interfaces.replace("iface {0} inet static".format(interface_name),
                                    "iface {0} inet manual".format(interface_name))

    with open(interfaces_file, 'w') as file:
        file.write(interfaces)

    try_reset_network("debian", reset_async=True)


def try_read_url(url, distro_name, reset_net=True):
    try:
        raw_data = url_helper.readurl(url, timeout=3, retries=3).contents
    except Exception:
        if reset_net:
            try_reset_network(distro_name, reset_async=True)
            raw_data = url_helper.readurl(url, timeout=5, retries=30).contents

    if type(raw_data) is bytes:
        raw_data = raw_data.decode()

    return raw_data


@retry_decorator()
def set_network_config(action="", id_net_name=""):

    if is_cloud_init_running():
        return

    init = stages.Init()
    init.read_cfg()

    logging.setupLogging(init.cfg)

    use_legacy_networking = False
    try:
        openstack.convert_net_json
        init.distro.apply_network_config
    except AttributeError:
        use_legacy_networking = True

    if use_legacy_networking:
        # old network interfaces files in Debian format
        # required on Ubuntu 14.04, as cloud-init does not
        # know about v2 metadata.
        # Legacy network metadata appears only if
        # on compute node, in nova.conf:
        # [DEFAULT}
        # flat_injected = True
        net_cfg_raw = try_read_url(LEGACY_MAGIC_URL, init.distro.name)
        init.distro.apply_network(net_cfg_raw, bring_up=True)
    else:
        if id_net_name and action == "remove":
            set_manual_interface(id_net_name)

        net_cfg_raw = try_read_url(MAGIC_URL, init.distro.name)
        net_cfg_raw = json.loads(net_cfg_raw)
        netcfg = openstack.convert_net_json(net_cfg_raw)

        init.distro.apply_network_config_names(netcfg)
        init.distro.apply_network_config(netcfg, bring_up=True)

        try_reset_network(init.distro.name, reset_async=True)


action = os.environ.get("ACTION", "")
id_net_name = os.environ.get("ID_NET_NAME", "")

set_network_config(action, id_net_name)
