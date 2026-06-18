#!/usr/bin/env python3
"""inner vCenter 設 config.vpxd.network.rollback=false(含 SSO 暖機重試)。

  pip install pyvmomi
  python disable_network_rollback.py --vc 10.0.1.19
"""
import argparse
from pyVmomi import vim
from _common import vc_connect_retry, vc_disconnect


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vc", default="10.0.1.19")
    ap.add_argument("--user", default="administrator@vsphere.local")
    ap.add_argument("--password", default="VMware1!VMware1!")
    ap.add_argument("--retry-minutes", type=int, default=8)
    a = ap.parse_args()

    si = vc_connect_retry(a.vc, a.user, a.password, a.retry_minutes)
    try:
        om = si.RetrieveContent().setting
        om.UpdateOptions([vim.option.OptionValue(key="config.vpxd.network.rollback", value="false")])
        cur = om.QueryOptions("config.vpxd.network.rollback")[0].value
        print(f"config.vpxd.network.rollback = {cur}")
    finally:
        vc_disconnect(si)


if __name__ == "__main__":
    main()
