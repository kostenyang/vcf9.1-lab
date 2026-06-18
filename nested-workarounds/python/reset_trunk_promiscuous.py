#!/usr/bin/env python3
"""Toggle 外層 trunk dvPortgroup 的 AllowPromiscuous (False->True) 重推 swsec policy
→ 解 nested ESXi 部完 ping 不到(外層 ESXi 7.x swsec runtime stale)。

  pip install pyvmomi
  python reset_trunk_promiscuous.py --outer-vc 10.0.0.101 --portgroup Trunk-Nobinding
"""
import argparse
import time
from pyVmomi import vim
from _common import vc_connect, vc_disconnect, get_obj, wait_task


def set_promiscuous(pg, value):
    spec = vim.dvs.DistributedVirtualPortgroup.ConfigSpec()
    spec.configVersion = pg.config.configVersion  # 每次都要帶當前 version
    pol = vim.dvs.VmwareDistributedVirtualSwitch.VmwarePortConfigPolicy()
    pol.securityPolicy = vim.dvs.VmwareDistributedVirtualSwitch.SecurityPolicy(
        allowPromiscuous=vim.BoolPolicy(value=value))
    spec.defaultPortConfig = pol
    wait_task(pg.ReconfigureDVPortgroup_Task(spec), f"set promiscuous={value}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outer-vc", default="10.0.0.101")
    ap.add_argument("--user", default="administrator@vsphere.local")
    ap.add_argument("--password", default="VMware1!")
    ap.add_argument("--portgroup", default="Trunk-Nobinding")
    a = ap.parse_args()

    si = vc_connect(a.outer_vc, a.user, a.password)
    try:
        content = si.RetrieveContent()
        pg = get_obj(content, [vim.dvs.DistributedVirtualPortgroup], a.portgroup)
        if not pg:
            raise SystemExit(f"找不到 portgroup {a.portgroup}")
        before = pg.config.defaultPortConfig.securityPolicy.allowPromiscuous.value
        print(f"Before AllowPromiscuous = {before}")
        set_promiscuous(pg, False)
        time.sleep(4)
        set_promiscuous(pg, True)   # ReconfigureDVPortgroup_Task 內會重抓 configVersion
        print("Toggle 完成 (False->True 重推 swsec policy)。nested ESXi 幾秒內應可 ping。")
    finally:
        vc_disconnect(si)


if __name__ == "__main__":
    main()
