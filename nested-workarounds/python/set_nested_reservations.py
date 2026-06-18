#!/usr/bin/env python3
"""外層 vCenter 給 nested ESXi VM 設 CPU/Memory reservation(防 swap → 穩 etcd)。
Memory 用降級嘗試:外層容量不足時自動套放得下的最大值。

  pip install pyvmomi
  python set_nested_reservations.py --outer-vc 10.0.0.101 --vm-glob "vcf-m02-esx0*-91" --cpu-mhz 16000 --mem-gb 256
"""
import argparse
import fnmatch
from pyVmomi import vim
from _common import vc_connect, vc_disconnect, get_all, wait_task


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--outer-vc", default="10.0.0.101")
    ap.add_argument("--user", default="administrator@vsphere.local")
    ap.add_argument("--password", default="VMware1!")
    ap.add_argument("--vm-glob", default="vcf-m02-esx0*-91")
    ap.add_argument("--cpu-mhz", type=int, default=16000)
    ap.add_argument("--mem-gb", type=int, default=256)
    a = ap.parse_args()

    si = vc_connect(a.outer_vc, a.user, a.password)
    try:
        content = si.RetrieveContent()
        vms = [v for v in get_all(content, [vim.VirtualMachine]) if fnmatch.fnmatch(v.name, a.vm_glob)]
        print(f"符合 '{a.vm_glob}' 的 VM: {len(vms)} 台")
        for vm in sorted(vms, key=lambda x: x.name):
            # CPU reservation
            try:
                spec = vim.vm.ConfigSpec(cpuAllocation=vim.ResourceAllocationInfo(reservation=a.cpu_mhz))
                wait_task(vm.ReconfigVM_Task(spec), "cpu rsv")
                print(f"  {vm.name}: CPU rsv {a.cpu_mhz} MHz")
            except Exception:
                print(f"  {vm.name}: CPU rsv fail")
            # Memory reservation with fallback
            done = False
            for g in sorted({a.mem_gb, 192, 128, 96, 64}, reverse=True):
                if g > a.mem_gb:
                    continue
                try:
                    spec = vim.vm.ConfigSpec(memoryAllocation=vim.ResourceAllocationInfo(reservation=g * 1024))
                    wait_task(vm.ReconfigVM_Task(spec), "mem rsv")
                    print(f"  {vm.name}: Mem rsv {g} GB")
                    done = True
                    break
                except Exception:
                    continue
            if not done:
                print(f"  {vm.name}: Mem rsv 連最低都設不了 (外層容量不足)")
    finally:
        vc_disconnect(si)


if __name__ == "__main__":
    main()
