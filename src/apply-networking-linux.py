#!/usr/bin/env python
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
import platform
import string
import subprocess
import sys
import syslog
import time

NET_RENDERERS = ["eni", "sysconfig", "netplan"]

ENI_DISABLE_DAD = """
pre-up echo 0 > /proc/sys/net/ipv6/conf/$name/accept_dad
"""
ENI_INTERFACE_HEADER = """
# Injected by CLOUD MANAGER
#     DO NOT EDIT THIS FILE BY HAND -- YOUR CHANGES WILL BE OVERWRITTEN
"""
ENI_INTERFACE_STATIC_TEMPLATE = """
auto $name$index
iface $name$index inet$family $type
    hwaddress ether $mac_address
    address $address$mtu
    netmask $netmask
    gateway $gateway
    dns-nameservers $dns
"""
ENI_DEBIAN_BUSTER_INTERFACE_STATIC_TEMPLATE = """
auto $name$index
iface $name$index inet$family $type
    hwaddress ether $mac_address
    address $address$mtu
    netmask $netmask
    post-up route add -A inet$family default gw $gateway || true
    pre-down route del -A inet$family default gw $gateway || true
    dns-nameservers $dns
"""
ENI_INTERFACE_DEFAULT_TEMPLATE = """
auto $name$index
iface $name$index inet$family $type
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

NETPLAN_ROOT_CONFIG = {
    "network": {
        "version": 2,
        "ethernets": []
    }
}

CENTOS_STATIC_TEMPLATE = """
BOOTPROTO=none
DEFROUTE=yes
DEVICE=$name
IPV4INIT=$init_ipv4
HWADDR=$mac_address
MTU=$mtu
ONBOOT=yes
TYPE=Ethernet
USERCTL=no
IPV4_FAILURE_FATAL=no
IPV6_FAILURE_FATAL=no
IPV6INIT=$init_ipv6
GATEWAY=$gateway_ipv4
IPV6_DEFAULTGW=$gateway_ipv6%$name
$ipv4_str
IPV6ADDR_SECONDARIES="$ipv6_str"
$dns
"""

CENTOS_STATIC_TEMPLATE_IP_V4 = """
PREFIX$index=$prefix
IPADDR$index=$address
"""

SUPPORTED_NETWORK_TYPES = ["ipv4", "ipv6", "ipv4_dhcp", "ipv6_dhcp"]


class DebianInterfacesDistro(object):

    def __init__(self):
        self.config_file = "/etc/network/interfaces"
        self.default_template = ENI_INTERFACE_DEFAULT_TEMPLATE
        self.static_template = ENI_DEBIAN_BUSTER_INTERFACE_STATIC_TEMPLATE

    def set_network_config_file(self, network_data, reset_to_dhcp=False):
        template_string = ENI_INTERFACE_HEADER + "\n"
        lo_data = {
            "name": "lo",
            "type": "loopback",
            "family": "",
            "index": ""
        }
        template_string += (
            format_template(self.default_template, lo_data) + "\n")

        links = {}
        for link in network_data["links"]:
            os_link_name = get_os_net_interface_by_mac(
                link["ethernet_mac_address"])
            if not os_link_name:
                raise Exception(
                    "Link could not be found " + link["ethernet_mac_address"])
            link["os_link_name"] = os_link_name
            links[link["id"]] = link

        interface_indexes = {}
        for network in network_data["networks"]:
            LOG("Processing network %s" % network["id"])
            os_link_name = links[network["link"]]["os_link_name"]
            if not os_link_name:
                raise Exception("Link not found for net %s" % network["id"])

            network_type = str(network["type"])
            if network_type not in SUPPORTED_NETWORK_TYPES:
                raise Exception(
                    "Network type %s not supported for %s" % (network_type,
                                                              os_link_name))

            net_type = "static"
            if "dhcp" in network_type:
                net_type = "dhcp"

            family = ""
            if "ipv6" in network_type:
                family = "6"

            mac_address = links[network["link"]]["ethernet_mac_address"]

            if net_type == "static":
                interface_index_str = ""
                mtu = ""
                interface_index_id = "%s%s" % (os_link_name, family)
                interface_index = interface_indexes.get(interface_index_id, 0)
                if interface_index != 0:
                    interface_index_str = ":%d" % (interface_index - 1)
                else:
                    mtu = "\n    mtu %s" % links[network["link"]]["mtu"]
                interface_indexes[interface_index_id] = interface_index + 1
                gateway = None
                for route in network["routes"]:
                    route_gateway = route["gateway"]
                    prefixlen = str(mask_to_net_prefix(str(route["netmask"])))
                    if prefixlen == "0":
                        gateway = route_gateway
                        break

                if not gateway:
                    raise Exception("No gateways have been found")

                dns = []
                for service in network["services"]:
                    if str(service["type"]) == "dns":
                        dns += [service["address"]]

                netmask = network["netmask"]
                if family == "6":
                    netmask = str(mask_to_net_prefix(str(netmask)))

                template_network_data = {
                    "index": interface_index_str,
                    "name": os_link_name,
                    "type": net_type,
                    "family": family,
                    "mac_address": mac_address,
                    "mtu": mtu,
                    "address": network["ip_address"],
                    "netmask": netmask,
                    "gateway": gateway,
                    "dns": " ".join(dns)
                }
                template_string += format_template(self.static_template,
                                                   template_network_data)
            elif reset_to_dhcp:
                auto_data = {
                    "name": os_link_name,
                    "type": net_type,
                    "family": family
                }
                template_string += (
                    format_template(self.default_template, auto_data) + "\n")
            else:
                LOG("Skipping network %s" % network["id"])
                continue

            LOG("Setting network %s to %s" % (network["id"], net_type))
            template_string += "\n"

        LOG("Writing config to %s" % self.config_file)
        with open(self.config_file, 'w') as config_file:
            config_file.write(template_string)

    def _get_device_for_link(self, network_data, link):
        for n_link in network_data["links"]:
            if n_link["id"] == link:
                return get_os_net_interface_by_mac(
                    n_link["ethernet_mac_address"])
        raise Exception("Could not find device for link %s" % link)

    def _set_link_mtu(self, link, mtu):
        LOG("Setting MTU for link %s to %r" % (link, mtu))
        ip_cmd = ["ip", "link", "set", "dev", link, "mtu", mtu]
        _, err, exit_code = execute_process(ip_cmd, shell=False)
        if exit_code:
            raise Exception("MTU could not be set: %s" % err)

    def _set_link_online(self, link):
        ip_cmd = ["ip", "link", "set", "dev", link, "up"]
        _, err, exit_code = execute_process(ip_cmd, shell=False)
        if exit_code:
            raise Exception("MTU could not be set: %s" % err)

    def _flush_nic(self, link):
        for i in ("4", "6"):
            flush_addr_cmd = ["ip", "-%s" % i, "addr", "flush", "dev", link]
            out, err, exit_code = execute_process(flush_addr_cmd, shell=False)
            if exit_code:
                raise Exception("IPs could not be flushed")

            flush_route_cmd = ["ip", "-%s" % i, "route", "flush", "dev",
                               link, "scope", "global"]
            out, err, exit_code = execute_process(flush_route_cmd, shell=False)
            if exit_code:
                raise Exception("Routes could not be flushed")

    def apply_network_config(self, network_data, reset_to_dhcp=False):
        for link in network_data["links"]:
            os_link_name = self._get_device_for_link(network_data, link["id"])
            if not os_link_name:
                raise Exception("Link not found for net %s" % link["id"])
            self._set_link_online(os_link_name)
            self._set_link_mtu(os_link_name, link["mtu"])
            self._flush_nic(os_link_name)

        route_destinations = set()
        for network in network_data["networks"]:
            os_link_name = self._get_device_for_link(network_data,
                                                     network["link"])
            if not os_link_name:
                raise Exception("Link not found for net %s" % network["id"])
            LOG("Apply network " + network["id"] + " for " + os_link_name)

            base_cmd = ["ip"]
            dhclient_cmd = ["dhclient"]
            network_type = str(network["type"])
            if network_type not in SUPPORTED_NETWORK_TYPES:
                raise Exception(
                    "Network type %s not supported for %s" % (network_type,
                                                              os_link_name))

            LOG("Network type is %s" % network_type)
            if network_type == "ipv6":
                base_cmd += ["-6"]
                dhclient_cmd += ["-6"]

            if "dhcp" in network_type:
                if reset_to_dhcp:
                    dhclient_cmd += [os_link_name]
                    out, err, exit_code = execute_process(dhclient_cmd,
                                                          shell=False)
                    if exit_code:
                        LOG("dhclient failed for %s. Err: %s" % (os_link_name,
                                                                 err))
                # That's all folks!
                continue

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
                destination = network_address + "/" + prefixlen
                if destination in route_destinations:
                    continue

                route_add_cmd = base_cmd + ["route", "add",
                                            destination,
                                            "via", gateway, "dev",
                                            os_link_name]
                out, err, exit_code = execute_process(route_add_cmd,
                                                      shell=False)
                if exit_code:
                    raise Exception("Route could not be set. Err: %s" % err)
                route_destinations.add(destination)


class DebianInterfacesd50Distro(DebianInterfacesDistro):

    def __init__(self):
        super(DebianInterfacesd50Distro, self).__init__()
        self.config_file = "/etc/network/interfaces.d/50-cloud-init.cfg"


class DebianBusterInterfacesd50Distro(DebianInterfacesDistro):

    def __init__(self):
        super(DebianBusterInterfacesd50Distro, self).__init__()
        self.config_file = "/etc/network/interfaces.d/50-cloud-init"
        self.static_template = ENI_DEBIAN_BUSTER_INTERFACE_STATIC_TEMPLATE


class NetplanDistro(DebianInterfacesDistro):

    def __init__(self):
        super(NetplanDistro, self).__init__()
        self.config_file = "/etc/netplan/50-cloud-init.yaml"

    def set_network_config_file(self, network_data, reset_to_dhcp=False):
        ethernets = {}

        links = {}
        for link in network_data["links"]:
            os_link_name = get_os_net_interface_by_mac(
                link["ethernet_mac_address"])
            if not os_link_name:
                raise Exception(
                    "Link could not be found " + link["ethernet_mac_address"])
            link["os_link_name"] = os_link_name
            links[link["id"]] = link
            ethernets[os_link_name] = {
                "addresses": [],
                "match": {
                    "macaddress": link["ethernet_mac_address"]
                },
                "mtu": link["mtu"],
                "nameservers": {
                    "addresses": [],
                    "search": []
                },
                "routes": [],
                "set-name": os_link_name
            }
        existing_destinations = set()
        for network in network_data["networks"]:
            LOG("Processing network %s" % network["id"])
            os_link_name = links[network["link"]]["os_link_name"]

            ip_address = network["ip_address"]
            prefixlen = str(mask_to_net_prefix(str(network["netmask"])))
            ethernets[os_link_name]["addresses"] += [
                "%s/%s" % (ip_address, prefixlen)
            ]

            dns = []
            link_ns = ethernets[os_link_name]["nameservers"]["addresses"]
            for service in network["services"]:
                if str(service["type"]) == "dns":
                    if service["address"] in link_ns:
                        continue
                    dns += [service["address"]]
            link_ns += dns

            routes = []
            for route in network["routes"]:
                network_address = route["network"]
                gateway = route["gateway"]
                prefixlen = str(mask_to_net_prefix(str(route["netmask"])))
                destination = "%s/%s" % (network_address, prefixlen)
                if destination in existing_destinations:
                    continue
                existing_destinations.add(destination)
                routes += [{
                    "to": destination,
                    "via": gateway
                }]
            ethernets[os_link_name]["routes"] += routes

        netplan_config = NETPLAN_ROOT_CONFIG
        netplan_config["network"]["ethernets"] = ethernets

        import yaml
        netplan_config_str = yaml.dump(netplan_config, line_break="\n",
                                       indent=4, default_flow_style=False)

        LOG("Writing config to %s" % self.config_file)
        with open(self.config_file, 'w') as config_file:
            config_file.write(netplan_config_str)


class CentOSDistro(DebianInterfacesDistro):

    def __init__(self):
        super(CentOSDistro, self).__init__()
        self.config_file = "/etc/sysconfig/network-scripts/ifcfg-%s"

    def set_network_config_file(self, network_data, reset_to_dhcp=False):
        ethernets = {}
        links = {}
        for link in network_data["links"]:
            os_link_name = get_os_net_interface_by_mac(
                link["ethernet_mac_address"])
            if not os_link_name:
                raise Exception(
                    "Link could not be found " + link["ethernet_mac_address"])
            link["os_link_name"] = os_link_name
            links[link["id"]] = link
            ethernets[os_link_name] = {
                "name": os_link_name,
                "mac_address": link["ethernet_mac_address"],
                "mtu": link["mtu"],
                "ipv4": [],
                "ipv6": [],
                "gateway_ipv4": "",
                "gateway_ipv6": "",
                "ipv4_str": "",
                "ipv6_str": "",
                "init_ipv4": "no",
                "init_ipv6": "no",
                "dns_set": set(),
                "dns": "",
                "dns_nr": 1,
            }

        for network in network_data["networks"]:
            LOG("Processing network %s" % network["id"])
            os_link_name = links[network["link"]]["os_link_name"]
            if not os_link_name:
                raise Exception("Link not found for net %s" % network["id"])

            family = ""
            if network["type"] == "ipv6":
                family = "6"

            dns_template = ""
            for service in network["services"]:
                if (str(service["type"]) == "dns" and
                        not (service["address"] in
                             ethernets[os_link_name]["dns_set"])):
                        dns_nr = ethernets[os_link_name]["dns_nr"]
                        dns_template += ("DNS%d=%s\n" % (
                            dns_nr, service["address"]))
                        ethernets[os_link_name]["dns_nr"] += 1
                        ethernets[os_link_name]["dns_set"].add(
                            service["address"])

            gateway = None
            for route in network["routes"]:
                route_gateway = route["gateway"]
                prefixlen = str(mask_to_net_prefix(str(route["netmask"])))
                if prefixlen == "0":
                    gateway = route_gateway
                    break

            if not gateway:
                raise "No gateways have been found"

            netmask = network["netmask"]
            prefix = str(mask_to_net_prefix(str(netmask)))

            address = {
                "gateway": gateway,
                "name": os_link_name,
                "netmask": netmask,
                "prefix": prefix,
                "address": network["ip_address"],
                "index": "0"
            }

            if family == "6":
                len_addr = len(ethernets[os_link_name]["ipv6"])
                address["index"] = "%d" % len_addr
                if address["index"] == "0":
                    address["index"] = ""
                ethernets[os_link_name]["init_ipv6"] = "yes"
                ethernets[os_link_name]["ipv6"] += [address]
                ethernets[os_link_name]["gateway_ipv6"] = gateway
            else:
                len_addr = len(ethernets[os_link_name]["ipv4"])
                address["index"] = "%d" % len_addr
                ethernets[os_link_name]["init_ipv4"] = "yes"
                ethernets[os_link_name]["ipv4"] += [address]
                ethernets[os_link_name]["gateway_ipv4"] = gateway

            ethernets[os_link_name]["dns"] += dns_template

        for os_link_name in ethernets.keys():
            net_config_file = self.config_file % os_link_name

            for ipv4_addr in ethernets[os_link_name]["ipv4"]:
                template = CENTOS_STATIC_TEMPLATE_IP_V4
                ethernets[os_link_name]["ipv4_str"] += (
                    "%s\n" % format_template(template,
                                             ipv4_addr))

            for ipv6_addr in ethernets[os_link_name]["ipv6"]:
                ethernets[os_link_name]["ipv6_str"] += (
                    "%s/%s " % (ipv6_addr["address"], ipv6_addr["prefix"]))

            ethernets[os_link_name]["ipv6_str"] = (
                ethernets[os_link_name]["ipv6_str"].strip())
            ethernets[os_link_name]["ipv4_str"] = (
                ethernets[os_link_name]["ipv4_str"].strip())

            LOG("Writing config to %s" % net_config_file)
            template_string = format_template(CENTOS_STATIC_TEMPLATE,
                                              ethernets[os_link_name])
            with open(net_config_file, 'w') as config_file:
                config_file.write(template_string)


def get_os_distribution():
    try:
        return platform.dist()
    except Exception:
        import distro
        return [distro.name(),
                distro.major_version() + '.' + distro.minor_version(),
                distro.codename()]


def format_template(template, data):
    template = string.Template(template)
    return template.safe_substitute(**data)


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
    LOG("Executing: %s" % " ".join(args))
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
    msg = "%s" % msg
    syslog.syslog(syslog.LOG_INFO, msg)
    print(msg)


@retry_decorator()
def configure_network(b64json_network_data, reset_to_dhcp=False):
    network_data = parse_fron_b64_json(b64json_network_data)
    LOG(network_data)

    if not network_data:
        LOG("Network data is empty")
        return

    os_distrib = get_os_distribution()
    os_distrib_str = " ".join(os_distrib)
    LOG("Running on %s" % os_distrib_str)

    if (os_distrib_str == "Ubuntu 14.04 trusty" or
            os_distrib_str.find("debian 8.") == 0):
        DISTRO = DebianInterfacesDistro()
    elif (os_distrib_str.find("debian 9") == 0 or
            os_distrib_str == "Ubuntu 16.04 xenial"):
        DISTRO = DebianInterfacesd50Distro()
    elif (os_distrib_str.find("debian 10") == 0):
        DISTRO = DebianBusterInterfacesd50Distro()
    elif (os_distrib_str == "Ubuntu 18.04 bionic" or
            os_distrib_str == "Ubuntu 20.04 focal"):
        DISTRO = NetplanDistro()
    elif (os_distrib_str.find("centos ") == 0):
        DISTRO = CentOSDistro()
    else:
        raise Exception("Distro %s not supported" % os_distrib_str)

    DISTRO.set_network_config_file(network_data, reset_to_dhcp=reset_to_dhcp)
    DISTRO.apply_network_config(network_data, reset_to_dhcp=reset_to_dhcp)

data = sys.argv[1]

# data = get_example_metadata()

reset_to_dhcp = False

configure_network(data, reset_to_dhcp=reset_to_dhcp)
