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
import time

from cloudinit import log as logging
from cloudinit import stages
from cloudinit import url_helper
from cloudinit import util

from cloudinit.sources.helpers import openstack

MAGIC_URL = "http://169.254.169.254/openstack/latest/network_data.json"


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


@retry_decorator()
def set_network_config():

    if is_cloud_init_running():
        raise Exception("Cloud-Init is running")

    init = stages.Init()
    init.read_cfg()

    # not available on Ubuntu Trusty (v0.7.5)
    if logging.setupLogging:
        logging.setupLogging(init.cfg)

    uses_old_interfaces_file = False
    if uses_old_interfaces_file:
        # old network interfaces files in debian format
        # required on Ubuntu 14.04, as cloud-init does not
        # know about v2 metadata
        net_cfg = ''
        init.distro.apply_network(net_cfg)
    else:
        net_cfg_raw = url_helper.readurl(MAGIC_URL).contents
        if type(net_cfg_raw) is bytes:
            net_cfg_raw = net_cfg_raw.decode()
        net_cfg_raw = json.loads(net_cfg_raw)
        netcfg = openstack.convert_net_json(net_cfg_raw)

        init.distro.apply_network_config_names(netcfg)
        init.distro.apply_network_config(netcfg, bring_up=True)

        netplan_apply_succes = False
        # required on Ubuntu 18.04
        try:
            util.subp(["netplan", "apply"])
            return
        except Exception:
            pass

        util.subp(["service", "networking", "restart"])

set_network_config()
