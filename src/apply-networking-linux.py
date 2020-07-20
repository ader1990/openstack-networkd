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

import errno
import json
import os
import subprocess
import sys
import time

from base64 import b64decode


NET_RENDERERS = ["eni", "sysconfig", "netplan"]
ENI_INTERFACE_TEMPLATE = """
    auto <LINK_NAME>
    iface <LINK_NAME> inet static
        hwaddress ether <LINK_MAC_ADDRESS>
        address <IP_ADDRESS>
        mtu <MTU>
        netmask <NETMASK>
        gateway <GATEWAY>
        dns-nameservers <DNS>
"""
SYS_CLASS_NET = "/sys/class/net/"
DEFAULT_PRIMARY_INTERFACE = 'eth0'


class Ubuntu14Distro(object):

    def __init__(self):
        self.distro_name = "ubuntu_14_04"
        self.distro_family = "debian"
        self.service_binary = "service"
        self.network_implementation = "eni"
        self.config_file = "/etc/network/interfaces"
        self.dns_config_file = "/etc/resolv.conf"

    def _get_static_interface_template(self):
        return ENI_INTERFACE_TEMPLATE

    def set_network_config_file(self, network_data):
        pass

    def apply_network_config(self, network_data):
        links = {}
        for link in network_data["links"]:
            os_link_name = get_os_net_interface_by_mac(
                link["ethernet_mac_address"])
            if not os_link_name:
                raise Exception(
                    "Link could not be found " + link["ethernet_mac_address"])
            link["os_link_name"] = os_link_name
            links[link["id"]] = link

            LOG("Apply config for link: " + os_link_name)
            base_cmd = ["ip", "link", "set", "dev", os_link_name]

            mtu_cmd = base_cmd + ["mtu", link["mtu"]]
            out, err, exit_code = execute_process(mtu_cmd, shell=False)
            if exit_code:
                raise Exception("MTU could not be set")

            up_cmd = base_cmd + ["up"]
            out, err, exit_code = execute_process(up_cmd, shell=False)
            if exit_code:
                raise Exception("Link could not be set to up state")

        for network in network_data["networks"]:
            LOG("Apply network : " + network["id"] + " for link " + network["link"])
            os_link_name = links[network["link"]]
            if not os_link_name:
                raise Exception("Link not found for network")

            flush_cmd = ["ip", "addr", "flush", "dev", os_link_name]
            out, err, exit_code = execute_process(flush_cmd, shell=False)
            if exit_code:
                raise Exception("IP could not be flushed")

            ip_address = network["ip_address"]
            ip_netmask = network["netmask"]
            prefixlen = sum(
                bin(int(x)).count('1') for x in ip_netmask.split('.'))
            addr_add_cmd = ["ip", "addr", "add",
                            ip_address + "/" + prefixlen, "dev", os_link_name]
            out, err, exit_code = execute_process(addr_add_cmd, shell=False)
            if exit_code:
                raise Exception("IP could not be set. Err: " + err)

            # ip route add <network/prefixlen> via <gateway> dev <link_name>


def get_os_net_interfaces():
    """Return NET interfaces as [eth0, eth1]"""

    try:
        devs = os.listdir(SYS_CLASS_NET)
    except OSError as e:
        if e.errno == errno.ENOENT:
            devs = []
        else:
            raise
    return devs


def get_os_net_interface_by_mac(mac_address):
    """Get interface name by MAC ADDRESS

    MAC ADDRESS should be in this format: fa:16:3e:93:69:32
    """

    devs = get_os_net_interfaces()

    if not devs:
        return None

    for dev in devs:
        mac_file_path = (
            os.path.join(os.path.join(SYS_CLASS_NET, dev), 'address'))
        with open(mac_file_path, 'r') as mac_file:
            existent_mac = mac_file.read().strip().rstrip()
            if mac_address == existent_mac:
                return dev


def get_example_metadata():
    return "ewogICAgImxpbmtzIjogWwogICAgICAgIHsKICAgICAgICAgICAgImlkIjogInRhcGVmMGVjNTZjLTg4IiwKICAgICAgICAgICAgInZpZl9pZCI6ICJlZjBlYzU2Yy04ODIzLTQ1MWItYTllNy0zMjdlY2FkM2VjMDUiLAogICAgICAgICAgICAidHlwZSI6ICJvdnMiLAogICAgICAgICAgICAibXR1IjogMTUwMCwKICAgICAgICAgICAgImV0aGVybmV0X21hY19hZGRyZXNzIjogImZhOjE2OjNlOjkzOjY5OjMyIgogICAgICAgIH0KICAgIF0sCiAgICAibmV0d29ya3MiOiBbCiAgICAgICAgewogICAgICAgICAgICAiaWQiOiAibmV0d29yazEiLAogICAgICAgICAgICAibGluayI6ICJ0YXBlZjBlYzU2Yy04OCIsCiAgICAgICAgICAgICJuZXR3b3JrX2lkIjogIjA5MzY0Mjk2LTFmMjAtNGZjNi05ZTRkLTkwYjBkODA2ODMwYSIsCiAgICAgICAgICAgICJ0eXBlIjogImlwdjQiLAogICAgICAgICAgICAibmV0bWFzayI6ICIyNTUuMjU1LjI1NS4yMjQiLAogICAgICAgICAgICAiaXBfYWRkcmVzcyI6ICI0LjUuNC40IiwKICAgICAgICAgICAgInJvdXRlcyI6IFsKICAgICAgICAgICAgICAgIHsKICAgICAgICAgICAgICAgICAgICAibmV0d29yayI6ICIwLjAuMC4wIiwKICAgICAgICAgICAgICAgICAgICAibmV0bWFzayI6ICIwLjAuMC4wIiwKICAgICAgICAgICAgICAgICAgICAiZ2F0ZXdheSI6ICI0LjUuMS4xIgogICAgICAgICAgICAgICAgfQogICAgICAgICAgICBdLAogICAgICAgICAgICAic2VydmljZXMiOiBbCiAgICAgICAgICAgICAgICB7CiAgICAgICAgICAgICAgICAgICAgInR5cGUiOiAiZG5zIiwKICAgICAgICAgICAgICAgICAgICAiYWRkcmVzcyI6ICI4LjguOC44IgogICAgICAgICAgICAgICAgfQogICAgICAgICAgICBdCiAgICAgICAgfQogICAgXSwKICAgICJzZXJ2aWNlcyI6IFsKICAgICAgICB7CiAgICAgICAgICAgICJ0eXBlIjogImRucyIsCiAgICAgICAgICAgICJhZGRyZXNzIjogIjEuMS4xLjEiCiAgICAgICAgfQogICAgXQp9Cg===="
    # return "eyJzZXJ2aWNlcyI6IFt7InR5cGUiOiAiZG5zIiwgImFkZHJlc3MiOiAiOC44LjguOCJ9XSwgIm5ldHdvcmtzIjogW3sibmV0d29ya19pZCI6ICI4MWQ1MjkyZS03OTBhLTRiMWEtOGRmZi1mNmRmZmVjMDY2ZmIiLCAidHlwZSI6ICJpcHY0IiwgInNlcnZpY2VzIjogW3sidHlwZSI6ICJkbnMiLCAiYWRkcmVzcyI6ICI4LjguOC44In1dLCAibmV0bWFzayI6ICIyNTUuMjU1LjI1NS4wIiwgImxpbmsiOiAidGFwODU0NDc3YzgtYmIiLCAicm91dGVzIjogW3sibmV0bWFzayI6ICIwLjAuMC4wIiwgIm5ldHdvcmsiOiAiMC4wLjAuMCIsICJnYXRld2F5IjogIjE5Mi4xNjguNS4xIn1dLCAiaXBfYWRkcmVzcyI6ICIxOTIuMTY4LjUuMTciLCAiaWQiOiAibmV0d29yazAifV0sICJsaW5rcyI6IFt7ImV0aGVybmV0X21hY19hZGRyZXNzIjogIjAwOjE1OjVEOjY0Ojk4OjYwIiwgIm10dSI6IDE0NTAsICJ0eXBlIjogIm92cyIsICJpZCI6ICJ0YXA4NTQ0NzdjOC1iYiIsICJ2aWZfaWQiOiAiODU0NDc3YzgtYmJmZS00OGY1LTg5NGQtODBmMGNkZmNjYTYwIn1dfQ=="


def execute_process(args, shell=True, decode_output=False):
    args = [str(arg) for arg in args]
    p = subprocess.Popen(args,
                         stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE,
                         shell=shell)
    (out, err) = p.communicate()

    if decode_output and sys.version_info < (3, 0):
        out = out.decode(sys.stdout.encoding)
        err = err.decode(sys.stdout.encoding)

    return out, err, p.returncode


def retry_decorator(max_retry_count=1, sleep_time=5):
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


def parse_fron_b64_json(b64json_data):
    json_data = b64decode(b64json_data)
    if type(json_data) is bytes:
        json_data = json_data.decode()
    return json.loads(json_data)


def LOG(msg):
    print(msg)


@retry_decorator()
def configure_network(b64json_network_data):
    network_data = parse_fron_b64_json(b64json_network_data)
    LOG(network_data)

    if not network_data:
        LOG("Network data is empty")
        return

    DISTRO = Ubuntu14Distro()
    DISTRO.set_network_config_file(network_data)
    DISTRO.apply_network_config(network_data)

data = sys.argv[1]
# data = get_example_metadata()

configure_network(data)
