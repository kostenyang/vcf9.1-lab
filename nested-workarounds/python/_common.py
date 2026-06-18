"""共用 helper:vCenter (pyVmomi) 連線 + VCF Installer REST。

被各 workaround 腳本 import。所有腳本都用 argparse 帶參數,預設值對齊本環境
(home.lab / 10.0.0.101 / 10.0.1.x / VMware1!),客戶換環境就帶參數覆蓋。
"""
import ssl
import sys
import time
import requests
import urllib3
from pyVim.connect import SmartConnect, Disconnect
from pyVmomi import vim

urllib3.disable_warnings()  # lab 自簽憑證


# ---------- vCenter (pyVmomi) ----------
def vc_connect(host, user, password):
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    si = SmartConnect(host=host, user=user, pwd=password, sslContext=ctx)
    return si


def vc_disconnect(si):
    try:
        Disconnect(si)
    except Exception:
        pass


def vc_connect_retry(host, user, password, retry_minutes=8):
    """vCenter 剛部好 SSO 還沒起來時重試 (給 network-rollback 用)。"""
    deadline = time.time() + retry_minutes * 60
    last = None
    while time.time() < deadline:
        try:
            return vc_connect(host, user, password)
        except Exception as e:
            last = e
            print(f"  SSO 未就緒, 重試: {str(e).splitlines()[0]}")
            time.sleep(30)
    raise RuntimeError(f"{retry_minutes} 分鐘內無法連上 {host}: {last}")


def get_all(content, vimtype):
    view = content.viewManager.CreateContainerView(content.rootFolder, vimtype, True)
    objs = list(view.view)
    view.Destroy()
    return objs


def get_obj(content, vimtype, name):
    for o in get_all(content, vimtype):
        if o.name == name:
            return o
    return None


def wait_task(task, what="task"):
    while task.info.state in (vim.TaskInfo.State.queued, vim.TaskInfo.State.running):
        time.sleep(2)
    if task.info.state != vim.TaskInfo.State.success:
        raise RuntimeError(f"{what} 失敗: {task.info.error}")
    return task.info.result


# ---------- VCF Installer REST ----------
def installer_token(installer_ip, user="admin@local", password="VMware1!VMware1!"):
    r = requests.post(f"https://{installer_ip}/v1/tokens",
                      json={"username": user, "password": password},
                      verify=False, timeout=20)
    r.raise_for_status()
    return r.json()["accessToken"]


def installer_headers(installer_ip, user="admin@local", password="VMware1!VMware1!"):
    return {"Authorization": f"Bearer {installer_token(installer_ip, user, password)}",
            "Content-Type": "application/json"}
