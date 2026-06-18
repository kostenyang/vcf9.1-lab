#!/usr/bin/env python3
"""把 vSAN Default Storage Policy 設成 FTT=0 + forceProvisioning,並可 reapply 到現有 VM。
→ 降 etcd 寫延遲(FTT=1 雙寫拖垮 nested vSAN 上的 Supervisor etcd)。

⚠ 這支用 pyVmomi 的 pbm API(SPBM),是 Python 版裡最複雜、最需在你環境驗證的一支。
   若 pbm 行為有差異,PowerShell 版 (../Set-VsanFtt0.ps1) 是已驗證的參考。

  pip install pyvmomi
  python set_vsan_ftt0.py --vc 10.0.1.19 --reapply-existing
"""
import argparse
import ssl
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import pbm, vim, VmomiSupport, SoapStubAdapter
import urllib3
urllib3.disable_warnings()


def connect_vc(host, user, pwd):
    ctx = ssl._create_unverified_context()
    return SmartConnect(host=host, user=user, pwd=pwd, sslContext=ctx)


def connect_pbm(vc_si, host):
    ctx = ssl._create_unverified_context()
    VmomiSupport.GetRequestContext()["vcSessionCookie"] = vc_si._stub.cookie.split('"')[1]
    stub = SoapStubAdapter(host=host, version="pbm.version.version2", path="/pbm/sdk", sslContext=ctx)
    return pbm.ServiceInstance("ServiceInstance", stub)


def ftt0_constraints():
    def cap(ns, cid, val):
        return pbm.capability.CapabilityInstance(
            id=pbm.capability.CapabilityMetadata.UniqueId(namespace=ns, id=cid),
            constraint=[pbm.capability.ConstraintInstance(
                propertyInstance=[pbm.capability.PropertyInstance(id=cid, value=val)])])
    sub = pbm.profile.SubProfileCapabilityConstraints.SubProfile(
        name="VSAN",
        capability=[cap("VSAN", "hostFailuresToTolerate", 0),
                    cap("VSAN", "forceProvisioning", True),
                    cap("VSAN", "stripeWidth", 1)])
    return pbm.profile.SubProfileCapabilityConstraints(subProfiles=[sub])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--vc", default="10.0.1.19")
    ap.add_argument("--user", default="administrator@vsphere.local")
    ap.add_argument("--password", default="VMware1!VMware1!")
    ap.add_argument("--policy-name", default="vSAN Default Storage Policy")
    ap.add_argument("--reapply-existing", action="store_true")
    a = ap.parse_args()

    vc = connect_vc(a.vc, a.user, a.password)
    try:
        pbm_si = connect_pbm(vc, a.vc)
        pm = pbm_si.RetrieveContent().profileManager
        ids = pm.PbmQueryProfile(
            resourceType=pbm.profile.ResourceType(resourceType="STORAGE"),
            profileCategory="REQUIREMENT")
        profiles = pm.PbmRetrieveContent(profileIds=ids)
        target = next((p for p in profiles if p.name == a.policy_name), None)
        if not target:
            raise SystemExit(f"找不到 policy: {a.policy_name}")

        pm.PbmUpdate(profileId=target.profileId,
                     updateSpec=pbm.profile.CapabilityBasedProfileUpdateSpec(
                         description=target.description, constraints=ftt0_constraints()))
        print(f"預設 policy '{a.policy_name}' 已設 FTT=0 + forceProvisioning。")

        if a.reapply_existing:
            print("Reapply 到所有現有 VM...")
            content = vc.RetrieveContent()
            view = content.viewManager.CreateContainerView(content.rootFolder, [vim.VirtualMachine], True)
            prof = [vim.vm.DefinedProfileSpec(profileId=target.profileId.uniqueId)]
            for vm in view.view:
                try:
                    disks = [d for d in vm.config.hardware.device if isinstance(d, vim.vm.device.VirtualDisk)]
                    spec = vim.vm.ConfigSpec(vmProfile=prof)
                    spec.deviceChange = [vim.vm.device.VirtualDeviceSpec(
                        operation=vim.vm.device.VirtualDeviceSpec.Operation.edit, device=d, profile=prof) for d in disks]
                    t = vm.ReconfigVM_Task(spec)
                    while t.info.state in (vim.TaskInfo.State.queued, vim.TaskInfo.State.running):
                        pass
                    print(f"  {'✓' if t.info.state == vim.TaskInfo.State.success else '!'} {vm.name}")
                except Exception as e:
                    print(f"  ! {vm.name}: {e}")
            view.Destroy()
    finally:
        Disconnect(vc)


if __name__ == "__main__":
    main()
