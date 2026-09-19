#!/usr/bin/env python3
"""
witness_prep.py — 把一台 nested ESXi 加進 vCenter 當 vSAN witness(cluster 外 standalone),
並建 vSAN vmk(VLAN、IP、MTU 9000、vsan tag)。stretch 前跑。

  pip install pyvmomi
  python witness_prep.py --vc 192.168.120.3 --vc-pass 'xxx' --dc vcf-m01-dc01 \
      --witness esx-witness.alan.lab --witness-pass 'xxx' \
      --vlan 140 --ip 192.168.140.68 --mask 255.255.255.0 [--mtu 9000] [--pg vsan-witness]

做的事(等同 vSphere Client 手動點):
  1. Datacenter → Add Host(standalone,不進 cluster)
  2. vSwitch0 MTU 9000 → 新 portgroup(VLAN)→ 新 vmk(IP、MTU 9000)→ 標 vsan traffic
  3. 提示你用 vmkping -s 8972 -d 驗 jumbo 到每台 cluster 主機的 vSAN IP(沒通 stretch 最後 remediate 會掛)
"""
import argparse, ssl, hashlib, socket, time
from pyVim.connect import SmartConnect
from pyVmomi import vim

ap = argparse.ArgumentParser()
ap.add_argument("--vc", required=True); ap.add_argument("--vc-user", default="administrator@vsphere.local"); ap.add_argument("--vc-pass", required=True)
ap.add_argument("--dc", required=True, help="Datacenter 名稱")
ap.add_argument("--witness", required=True, help="witness FQDN"); ap.add_argument("--witness-ip", help="解不到 DNS 時用 IP 連"); ap.add_argument("--witness-pass", required=True)
ap.add_argument("--vlan", type=int, required=True); ap.add_argument("--ip", required=True); ap.add_argument("--mask", default="255.255.255.0")
ap.add_argument("--mtu", type=int, default=9000); ap.add_argument("--pg", default="vsan-witness"); ap.add_argument("--vswitch", default="vSwitch0")
a = ap.parse_args()

ctx = ssl._create_unverified_context()
vc = SmartConnect(host=a.vc, user=a.vc_user, pwd=a.vc_pass, sslContext=ctx)
c = vc.RetrieveContent()
dc = next(d for d in c.rootFolder.childEntity if isinstance(d, vim.Datacenter) and d.name == a.dc)


def wait(t):
    while t.info.state in ("queued", "running"):
        time.sleep(2)
    if t.info.error:
        raise SystemExit(t.info.error.msg)
    return t.info.result


# 1. add standalone host(要帶 SHA-1 thumbprint)
with socket.create_connection((a.witness_ip or a.witness, 443), timeout=10) as s:
    with ctx.wrap_socket(s, server_hostname=a.witness) as ss:
        der = ss.getpeercert(binary_form=True)
h = hashlib.sha1(der).hexdigest().upper(); tp = ":".join(h[i:i + 2] for i in range(0, 40, 2))
existing = [x for x in c.viewManager.CreateContainerView(dc, [vim.HostSystem], True).view if x.name == a.witness]
if existing:
    host = existing[0]; print("host already in vCenter:", host.name)
else:
    spec = vim.host.ConnectSpec(hostName=a.witness, userName="root", password=a.witness_pass, sslThumbprint=tp, force=True)
    print("adding standalone host", a.witness)
    cr = wait(dc.hostFolder.AddStandaloneHost_Task(spec=spec, addConnected=True))
    host = cr.host[0]

ns = host.configManager.networkSystem

# 2. vSwitch MTU → portgroup → vmk → vsan tag
vs = next(v for v in ns.networkInfo.vswitch if v.name == a.vswitch)
if vs.mtu != a.mtu:
    sp = vs.spec; sp.mtu = a.mtu
    ns.UpdateVirtualSwitch(a.vswitch, sp); print(f"{a.vswitch} MTU -> {a.mtu}")
if not any(p.spec.name == a.pg for p in ns.networkInfo.portgroup):
    ns.AddPortGroup(vim.host.PortGroup.Specification(name=a.pg, vlanId=a.vlan, vswitchName=a.vswitch, policy=vim.host.NetworkPolicy()))
    print(f"portgroup {a.pg} VLAN {a.vlan} created")
vmk = next((v.device for v in ns.networkInfo.vnic if v.portgroup == a.pg), None)
if not vmk:
    vmk = ns.AddVirtualNic(a.pg, vim.host.VirtualNic.Specification(
        ip=vim.host.IpConfig(dhcp=False, ipAddress=a.ip, subnetMask=a.mask), mtu=a.mtu))
    print(f"{vmk} {a.ip}/{a.mask} MTU {a.mtu} created")
else:
    vn = next(v for v in ns.networkInfo.vnic if v.device == vmk)
    if vn.spec.mtu != a.mtu:
        sp = vn.spec; sp.mtu = a.mtu; ns.UpdateVirtualNic(vmk, sp); print(f"{vmk} MTU -> {a.mtu}")
vnm = host.configManager.virtualNicManager
if vmk not in (vnm.QueryNetConfig("vsan").selectedVnic or []):
    vnm.SelectVnicForNicType("vsan", vmk); print(f"{vmk} tagged vsan")

print(f"""
DONE. 現在到 witness SSH 驗 jumbo(每台 cluster 主機的 vSAN IP,不是管理 IP):
  esxcli vsan network list
  for ip in 192.168.140.5 192.168.140.6 ...; do vmkping -I {vmk} -s 8972 -d -c 2 $ip; done
全部通了再跑 vcf_stretch.py stretch。""")
