"""透過外層 vCenter 的 Guest Operations(nested ESXi 有 VMware Tools)在 nested ESXi 內執行 shell 腳本,救斷網主機。
用法: OUTER_VC_PASS=... python tools-guest_fix.py <outer VM name> <script file>(外層 vCenter 110.32,帳號 administrator@vsphere.local;nested ESXi root 密碼放 NESTED_ROOT_PASS)"""
import ssl,sys,time,os,urllib.request
from pyVim.connect import SmartConnect
from pyVmomi import vim
ctx=ssl._create_unverified_context()
vmname, script = sys.argv[1], open(sys.argv[2],"rb").read().replace(b"\r\n",b"\n")
si=SmartConnect(host="192.168.110.32",user="administrator@vsphere.local",pwd=os.environ["OUTER_VC_PASS"],sslContext=ctx)
c=si.RetrieveContent()
vm=[v for v in c.viewManager.CreateContainerView(c.rootFolder,[vim.VirtualMachine],True).view if v.name==vmname][0]
auth=vim.vm.guest.NamePasswordAuthentication(username="root",password=os.environ.get("NESTED_ROOT_PASS",""))
fm=c.guestOperationsManager.fileManager; pm=c.guestOperationsManager.processManager
url=fm.InitiateFileTransferToGuest(vm=vm,auth=auth,guestFilePath="/tmp/guestfix.sh",fileAttributes=vim.vm.guest.FileManager.PosixFileAttributes(permissions=0o755),fileSize=len(script),overwrite=True).replace("*","192.168.110.32")
urllib.request.urlopen(urllib.request.Request(url,data=script,method="PUT"),context=ctx).read()
pid=pm.StartProgramInGuest(vm=vm,auth=auth,spec=vim.vm.guest.ProcessManager.ProgramSpec(programPath="/bin/sh",arguments="/tmp/guestfix.sh > /tmp/guestfix.out 2>&1"))
for i in range(60):
    p=pm.ListProcessesInGuest(vm=vm,auth=auth,pids=[pid])
    if p and p[0].endTime: break
    time.sleep(2)
print("exit:",p[0].exitCode if p else None)
info=fm.InitiateFileTransferFromGuest(vm=vm,auth=auth,guestFilePath="/tmp/guestfix.out")
print(urllib.request.urlopen(info.url.replace("*","192.168.110.32"),context=ctx).read().decode(errors="replace"))
