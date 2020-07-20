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
import subprocess
import sys
import time

from base64 import b64decode


def get_example_metadata():
    return "eyJzZXJ2aWNlcyI6IFt7InR5cGUiOiAiZG5zIiwgImFkZHJlc3MiOiAiOC44LjguOCJ9XSwgIm5ldHdvcmtzIjogW3sibmV0d29ya19pZCI6ICI4MWQ1MjkyZS03OTBhLTRiMWEtOGRmZi1mNmRmZmVjMDY2ZmIiLCAidHlwZSI6ICJpcHY0IiwgInNlcnZpY2VzIjogW3sidHlwZSI6ICJkbnMiLCAiYWRkcmVzcyI6ICI4LjguOC44In1dLCAibmV0bWFzayI6ICIyNTUuMjU1LjI1NS4wIiwgImxpbmsiOiAidGFwODU0NDc3YzgtYmIiLCAicm91dGVzIjogW3sibmV0bWFzayI6ICIwLjAuMC4wIiwgIm5ldHdvcmsiOiAiMC4wLjAuMCIsICJnYXRld2F5IjogIjE5Mi4xNjguNS4xIn1dLCAiaXBfYWRkcmVzcyI6ICIxOTIuMTY4LjUuMTciLCAiaWQiOiAibmV0d29yazAifV0sICJsaW5rcyI6IFt7ImV0aGVybmV0X21hY19hZGRyZXNzIjogIjAwOjE1OjVEOjY0Ojk4OjYwIiwgIm10dSI6IDE0NTAsICJ0eXBlIjogIm92cyIsICJpZCI6ICJ0YXA4NTQ0NzdjOC1iYiIsICJ2aWZfaWQiOiAiODU0NDc3YzgtYmJmZS00OGY1LTg5NGQtODBmMGNkZmNjYTYwIn1dfQ=="


def execute_process(self, args, shell=True, decode_output=False):
    p = subprocess.Popen(args,
                         stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE,
                         shell=shell)
    (out, err) = p.communicate()

    if decode_output and sys.version_info < (3, 0):
        out = out.decode(sys.stdout.encoding)
        err = err.decode(sys.stdout.encoding)

    return out, err, p.returncode


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


def parse_fron_b64_json(b64json_data):
    return json.loads(b64decode(b64json_data))


def LOG(msg):
    print(msg)


@retry_decorator()
def set_network_config(b64json_network_data):
    network_data = parse_fron_b64_json(b64json_network_data)
    LOG(network_data)
    return


data = sys.argv[1]
#data = get_example_metadata()

set_network_config(data)
