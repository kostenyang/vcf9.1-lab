#!/usr/bin/env python3
"""關掉 inner cluster 的 HA Admission Control(讓 VSP appliance 放得下)。

  pip install pyvmomi
  python disable_ha_admission_control.py --vc 10.0.1.19
"""
import argparse
from pyVmomi import vim
from _common import vc_connect, vc_disconnect, get_all, wait_task


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vc", default="10.0.1.19")
    ap.add_argument("--user", default="administrator@vsphere.local")
    ap.add_argument("--password", default="VMware1!VMware1!")
    a = ap.parse_args()

    si = vc_connect(a.vc, a.user, a.password)
    try:
        content = si.RetrieveContent()
        for cl in get_all(content, [vim.ClusterComputeResource]):
            enabled = cl.configurationEx.dasConfig.admissionControlEnabled
            print(f"{cl.name}: AdmissionControl {enabled} -> 關閉中")
            spec = vim.cluster.ConfigSpecEx()
            spec.dasConfig = vim.cluster.DasConfigInfo(admissionControlEnabled=False)
            wait_task(cl.ReconfigureComputeResource_Task(spec, True), f"{cl.name} reconfigure")
            print(f"  -> AdmissionControl = {cl.configurationEx.dasConfig.admissionControlEnabled}")
    finally:
        vc_disconnect(si)


if __name__ == "__main__":
    main()
