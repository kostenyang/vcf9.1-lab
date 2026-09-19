#!/usr/bin/env python3
"""
vsan_policy_sftt0.py — stretch 後把 VCF 套的 cluster policy(PFTT=1 / SFTT=1,4 份 copy)
改成 PFTT=1 / SFTT=0(跨站鏡像、站內單份,2 份 copy),並 reapply 到所有 VM。
nested lab 容量不夠 4 份時用;也順便讓 resync 少一半。

  pip install pyvmomi
  python vsan_policy_sftt0.py --vc 192.168.120.3 --vc-pass 'xxx' --policy 'vcf-m01-cl01 vSAN Storage Policy'
  python vsan_policy_sftt0.py ... --check        # 只看目前 policy 與各 VM compliance,不改

注意:改 policy 之後 SPBM 只把物件標 outOfDate,不會自動套 → 本腳本會對每台 VM 做 ReconfigVM_Task
(vmProfile + 每顆 disk 的 profile)。Content Library 的 template VM 不能 reconfigure,會跳過。
改完等 `esxcli vsan debug resync summary get` 歸零、Skyline Health 綠,再 retry SDDC Manager 的 task。
"""
import argparse, ssl, time
from pyVim.connect import SmartConnect
from pyVmomi import pbm, vim, VmomiSupport, SoapStubAdapter

ap = argparse.ArgumentParser()
ap.add_argument("--vc", required=True); ap.add_argument("--vc-user", default="administrator@vsphere.local"); ap.add_argument("--vc-pass", required=True)
ap.add_argument("--policy", required=True, help="要改的 policy 名稱(VCF 命名:<cluster> vSAN Storage Policy)")
ap.add_argument("--sftt", type=int, default=0); ap.add_argument("--pftt", type=int, default=1)
ap.add_argument("--check", action="store_true", help="只查不改")
a = ap.parse_args()

ctx = ssl._create_unverified_context()
vc = SmartConnect(host=a.vc, user=a.vc_user, pwd=a.vc_pass, sslContext=ctx)
VmomiSupport.GetRequestContext()["vcSessionCookie"] = vc._stub.cookie.split('"')[1]
stub = SoapStubAdapter(host=a.vc, version="pbm.version.version2", path="/pbm/sdk", sslContext=ctx)
pbmc = pbm.ServiceInstance("ServiceInstance", stub).RetrieveContent()
pm, cm = pbmc.profileManager, pbmc.complianceManager
c = vc.RetrieveContent(); uuid = c.about.instanceUuid

ids = pm.PbmQueryProfile(resourceType=pbm.profile.ResourceType(resourceType="STORAGE"), profileCategory="REQUIREMENT")
profiles = pm.PbmRetrieveContent(profileIds=ids)
target = next((p for p in profiles if p.name == a.policy), None)
if not target:
    raise SystemExit("找不到 policy: " + a.policy + "\n有的:" + ", ".join(p.name for p in profiles))


def caps(p):
    return {ci.id.id: ci.constraint[0].propertyInstance[0].value for sp in p.constraints.subProfiles for ci in sp.capability}


print("目前:", caps(target))


def vm_refs(vm):
    disks = [d for d in vm.config.hardware.device if isinstance(d, vim.vm.device.VirtualDisk)]
    return disks, [pbm.ServerObjectRef(objectType="virtualMachine", key=vm._moId, serverUuid=uuid)] + \
        [pbm.ServerObjectRef(objectType="virtualDiskId", key=f"{vm._moId}:{d.key}", serverUuid=uuid) for d in disks]


vms = c.viewManager.CreateContainerView(c.rootFolder, [vim.VirtualMachine], True).view


def show():
    for vm in vms:
        try:
            disks, refs = vm_refs(vm)
            comp = {r.complianceStatus for r in cm.PbmCheckCompliance(entities=refs)}
            print(f"  {vm.name:45s} disks={len(disks):2d} {comp}")
        except Exception as e:
            print(f"  {vm.name:45s} ERR {str(e)[:80]}")


if a.check:
    show(); raise SystemExit

# 改 policy
def cap(cid, val):
    return pbm.capability.CapabilityInstance(
        id=pbm.capability.CapabilityMetadata.UniqueId(namespace="VSAN", id=cid),
        constraint=[pbm.capability.ConstraintInstance(propertyInstance=[pbm.capability.PropertyInstance(id=cid, value=val)])])


cur = caps(target)
cur["hostFailuresToTolerate"] = a.pftt
cur["subFailuresToTolerate"] = a.sftt
sub = pbm.profile.SubProfileCapabilityConstraints.SubProfile(name="VSAN", capability=[cap(k, v) for k, v in cur.items()])
pm.PbmUpdate(profileId=target.profileId, updateSpec=pbm.profile.CapabilityBasedProfileUpdateSpec(
    description=target.description, constraints=pbm.profile.SubProfileCapabilityConstraints(subProfiles=[sub])))
print("改後:", caps(pm.PbmRetrieveContent(profileIds=[target.profileId])[0]))

# reapply 到每台 VM
prof = [vim.vm.DefinedProfileSpec(profileId=target.profileId.uniqueId)]
tasks = []
for vm in vms:
    try:
        disks, refs = vm_refs(vm)
        if not any(target.profileId.uniqueId == p.uniqueId for r in pm.PbmQueryAssociatedProfiles(refs) for p in r.profileId):
            continue  # 不是用這個 policy 的 VM 不動
        spec = vim.vm.ConfigSpec(vmProfile=prof)
        spec.deviceChange = [vim.vm.device.VirtualDeviceSpec(operation="edit", device=d, profile=prof) for d in disks]
        tasks.append((vm.name, vm.ReconfigVM_Task(spec)))
    except Exception as e:
        print(f"  {vm.name}: skip ({str(e)[:60]})")
for name, t in tasks:
    while t.info.state in ("queued", "running"):
        time.sleep(2)
    print(f"  reapply {name:45s} {t.info.state} {t.info.error.msg if t.info.error else ''}")
print("\ncompliance:"); show()
print("\n接著在任一 cluster 主機:esxcli vsan debug resync summary get  → 歸零後再 retry SDDC Manager task")
