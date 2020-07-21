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

import base64
import errno
import json
import os
import subprocess
import sys
import time

NET_RENDERERS = ["eni", "sysconfig", "netplan"]
ENI_INTERFACE_STATIC_TEMPLATE = """
    auto <LINK_NAME>
    iface <LINK_NAME> inet<FAMILY> <TYPE>
        hwaddress ether <LINK_MAC_ADDRESS>
        address <IP_ADDRESS>
        mtu <MTU>
        netmask <NETMASK>
        gateway <GATEWAY>
        dns-nameservers <DNS>
"""
ENI_INTERFACE_DEFAULT_TEMPLATE = """
    auto <LINK_NAME>
    iface <LINK_NAME> inet<FAMILY> <TYPE>
"""
SYS_CLASS_NET = "/sys/class/net/"

EXAMPLE_JSON_METADATA = """
{
    "links": [
        {
            "id": "tapef0ec56c-88",
            "mtu": 1420,
            "ethernet_mac_address": "fa:16:3e:7a:61:64"
        }
    ],
    "networks": [
        {
            "id": "network0",
            "link": "tapef0ec56c-88",
            "type": "ipv4",
            "netmask": "255.255.255.0",
            "ip_address": "192.168.5.22",
            "routes": [
                {
                    "network": "0.0.0.0",
                    "netmask": "0.0.0.0",
                    "gateway": "192.168.5.1"
                }
            ],
            "services": [
                {
                    "type": "dns",
                    "address": "8.8.8.8"
                }
            ]
        },
        {
            "id": "network1",
            "link": "tapef0ec56c-88",
            "type": "ipv6",
            "netmask": "ffff:ffff:ffff:ffff::",
            "ip_address": "fe80::9",
            "routes": [
                {
                    "network": "::",
                    "netmask": "::",
                    "gateway": "fe80::1ff:fe23:4567:890a"
                }
            ],
            "services": [
                {
                    "type": "dns",
                    "address": "2001:4860:4860::8888"
                }
            ]
        }
    ],
    "services": [
        {
            "type": "dns",
            "address": "1.1.1.1"
        }
    ]
}
"""


class Ubuntu14Distro(object):

    def __init__(self):
        self.distro_name = "ubuntu_14_04"
        self.config_file = "/etc/network/interfaces"

        LOG("Running on %s." % self.distro_name)

    def set_network_config_file(self, network_data):
        template_network_data = {}
        template_network_data["lo"] = {
            "name": "lo",
            "type": "loopback"
        }

        links = {}
        for link in network_data["links"]:
            os_link_name = get_os_net_interface_by_mac(
                link["ethernet_mac_address"])
            if not os_link_name:
                raise Exception(
                    "Link could not be found " + link["ethernet_mac_address"])
            link["os_link_name"] = os_link_name
            links[link["id"]] = link

        for network in network_data["networks"]:
            LOG("Processing network %s" % network["id"])
            os_link_name = links[network["link"]]["os_link_name"]
            if not os_link_name:
                raise Exception("Link not found for net %s" % network["id"])

            net_type = "static"
            family = ""
            if network["type"] == "ipv6":
                family = "6"

            gateway = None
            for route in network["routes"]:
                route_gateway = route["gateway"]
                prefixlen = str(mask_to_net_prefix(str(route["netmask"])))
                if prefixlen == "0":
                    gateway = route_gateway
                    break

            if not gateway:
                raise "No gateways have been found"

            template_network_data[network["id"]] = {
                "name": os_link_name,
                "type": net_type,
                "family": family,
                "mac_address": links[network["link"]]["ethernet_mac_address"],
                "mtu": links[network["link"]]["mtu"],
                "address": network["ip_address"],
                "netmask": network["netmask"],
                "gateway": network["gateway"],
                "dns-nameservers": "8.8.8.8"
            }

            LOG(template_network_data)

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

            LOG("Apply config for link " + os_link_name)
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
            os_link_name = links[network["link"]]["os_link_name"]
            if not os_link_name:
                raise Exception("Link not found for net %s" % network["id"])
            LOG("Apply network " + network["id"] + " for " + os_link_name)

            base_cmd = ["ip"]
            if str(network["type"]) == "ipv6":
                base_cmd += ["-6"]

            flush_addr_cmd = base_cmd + ["addr", "flush", "dev", os_link_name]
            out, err, exit_code = execute_process(flush_addr_cmd, shell=False)
            if exit_code:
                raise Exception("IPs could not be flushed")

            flush_route_cmd = base_cmd + ["route", "flush", "dev",
                                          os_link_name]
            out, err, exit_code = execute_process(flush_route_cmd, shell=False)
            if exit_code:
                raise Exception("Routes could not be flushed")

            ip_address = network["ip_address"]
            ip_netmask = network["netmask"]
            prefixlen = str(mask_to_net_prefix(str(ip_netmask)))
            addr_add_cmd = base_cmd + ["addr", "add",
                                       ip_address + "/" + prefixlen,
                                       "dev", os_link_name]
            out, err, exit_code = execute_process(addr_add_cmd, shell=False)
            if exit_code:
                raise Exception("IP could not be set. Err: %s" % err)

            for route in network["routes"]:
                network_address = route["network"]
                gateway = route["gateway"]
                prefixlen = str(mask_to_net_prefix(str(route["netmask"])))
                route_add_cmd = base_cmd + ["route", "add",
                                            network_address + "/" + prefixlen,
                                            "via", gateway, "dev",
                                            os_link_name]
                out, err, exit_code = execute_process(route_add_cmd,
                                                      shell=False)
                if exit_code:
                    raise Exception("Route could not be set. Err: %s" % err)


def is_python_3():
    return sys.version_info[0] == 3


def ipv4_mask_to_net_prefix(mask):
    """Convert an ipv4 netmask into a network prefix length.

    If the input is already an integer or a string representation of
    an integer, then int(mask) will be returned.
       "255.255.255.0" => 24
       str(24)         => 24
       "24"            => 24
    """
    if isinstance(mask, int):
        return mask
    if isinstance(mask, str):
        try:
            return int(mask)
        except ValueError:
            pass
    else:
        raise TypeError("mask '%s' is not a string or int" % mask)

    if '.' not in mask:
        raise ValueError("netmask '%s' does not contain a '.'" % mask)

    toks = mask.split(".")
    if len(toks) != 4:
        raise ValueError("netmask '%s' had only %d parts" % (mask, len(toks)))

    return sum([bin(int(x)).count('1') for x in toks])


def ipv6_mask_to_net_prefix(mask):
    """Convert an ipv6 netmask (very uncommon) or prefix (64) to prefix.

    If 'mask' is an integer or string representation of one then
    int(mask) will be returned.
    """

    if isinstance(mask, int):
        return mask
    if isinstance(mask, str):
        try:
            return int(mask)
        except ValueError:
            pass
    else:
        raise TypeError("mask '%s' is not a string or int" % mask)

    if ':' not in mask:
        raise ValueError("mask '%s' does not have a ':'")

    bitCount = [0, 0x8000, 0xc000, 0xe000, 0xf000, 0xf800, 0xfc00, 0xfe00,
                0xff00, 0xff80, 0xffc0, 0xffe0, 0xfff0, 0xfff8, 0xfffc,
                0xfffe, 0xffff]
    prefix = 0
    for word in mask.split(':'):
        if not word or int(word, 16) == 0:
            break
        prefix += bitCount.index(int(word, 16))

    return prefix


def is_ipv6_addr(address):
    if not address:
        return False
    return ":" in str(address)


def mask_to_net_prefix(mask):
    """Return the network prefix for the netmask provided.

    Supports ipv4 or ipv6 netmasks.
    """

    try:
        # if 'mask' is a prefix that is an integer.
        # then just return it.
        return int(mask)
    except ValueError:
        pass
    if is_ipv6_addr(mask):
        return ipv6_mask_to_net_prefix(mask)
    else:
        return ipv4_mask_to_net_prefix(mask)


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
    example = EXAMPLE_JSON_METADATA
    if is_python_3():
        example = example.encode()
    return base64.b64encode(example)
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
                    try_count = try_count + 1
                    if try_count == max_retry_count:
                        raise

                    time.sleep(sleep_time)
        return inner
    return wrapper


def parse_fron_b64_json(b64json_data):
    json_data = base64.b64decode(b64json_data)
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

# data = sys.argv[1]
data = get_example_metadata()

configure_network(data)
