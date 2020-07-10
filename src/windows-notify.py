import requests
import sys

from cloudbaseinit.utils import network

metadata_url = "http://169.254.169.254"
password_metadata_url = metadata_url  + "/openstack/latest/password"

network.check_metadata_ip_route(metadata_url)

existent_message = requests.get(password_metadata_url).content

print(existent_message)

data = "NIC_ADD"

try:
    data = sys.argv[1] or "NIC_ADD"
except Exception:
    pass

requests.request(method="POST", url=password_metadata_url, data=data)

# TO DO
# Recache the existent_message
