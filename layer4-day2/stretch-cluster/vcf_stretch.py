#!/usr/bin/env python3
"""
vcf_stretch.py — 用 SDDC Manager API 把 VCF 9.x 的 vSAN cluster 變成 stretched cluster(3+3+witness)。
純標準庫(urllib),Windows / Linux 跳板機都能直接跑,不用 pip。

連線設定用環境變數或參數:
    SDDC_HOST=192.168.120.4  SDDC_USER=administrator@vsphere.local  SDDC_PASS='<password>'

子命令(照 stretch 的順序排):
    token                         測登入
    hosts / clusters / pools      列 inventory(拿 id 用)
    thumbprint <fqdn>             算 ESXi 的 SHA-256 SSL thumbprint(commission 用)
    remove-host   --cluster NAME --host FQDN [--decommission]
                                  從 cluster 移除(cluster compaction)+ decommission
    commission    --hosts esx05.x,esx06.x --pool m01-np01 --password PW [--validate-only]
                                  (解不到 DNS 的機器可寫 esx05.x=192.168.120.65)
    gen-stretch-spec --cluster NAME --hosts esx05.x,esx06.x,esx07.x --witness FQDN
                     --witness-ip IP --witness-cidr CIDR [--overlay-vlan 150] [-o stretch-spec.json]
                                  自動填 host id + VDS/uplink 對應,產生 stretch spec
    stretch       --cluster NAME --spec stretch-spec.json [--validate-only] [--watch]
    unstretch     --cluster NAME [--validate-only] [--watch]     拆回一般 cluster(重做 / 回退用)
    task <id> / watch <id> / retry <id>

例:
    python vcf_stretch.py hosts
    python vcf_stretch.py remove-host --cluster vcf-m01-cl01 --host esx04.alan.lab --decommission
    python vcf_stretch.py thumbprint esx05.alan.lab
    python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password 'xxx' --validate-only
    python vcf_stretch.py commission --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab --pool m01-np01 --password 'xxx'
    python vcf_stretch.py gen-stretch-spec --cluster vcf-m01-cl01 --hosts esx05.alan.lab,esx06.alan.lab,esx07.alan.lab \
        --witness esx-witness.alan.lab --witness-ip 192.168.140.68 --witness-cidr 192.168.140.0/24 --overlay-vlan 150
    python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --validate-only
    python vcf_stretch.py stretch --cluster vcf-m01-cl01 --spec stretch-spec.json --watch
    python vcf_stretch.py retry <taskId>      # 失敗排除後重跑
"""
import argparse, json, os, ssl, sys, time, datetime, socket, hashlib, urllib.request, urllib.error

CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE
HOST = os.environ.get("SDDC_HOST", "192.168.120.4")
USER = os.environ.get("SDDC_USER", "administrator@vsphere.local")
PASS = os.environ.get("SDDC_PASS", "")
_TOKEN = None


def log(msg):
    print(f"[{datetime.datetime.now():%H:%M:%S}] {msg}", flush=True)


# ---------- HTTP ----------
def token():
    """POST /v1/tokens → accessToken(之後每個 request 帶 Authorization: Bearer)。"""
    global _TOKEN
    if _TOKEN:
        return _TOKEN
    if not PASS:
        sys.exit("請設 SDDC_PASS 環境變數(或 --password-sddc)")
    body = json.dumps({"username": USER, "password": PASS}).encode()
    r = urllib.request.Request(f"https://{HOST}/v1/tokens", data=body,
                               headers={"Content-Type": "application/json"}, method="POST")
    _TOKEN = json.load(urllib.request.urlopen(r, timeout=30, context=CTX))["accessToken"]
    return _TOKEN


def api(path, method="GET", body=None, timeout=120):
    """回 (http status, json)。4xx/5xx 不丟例外,直接回錯誤 json 讓你看。"""
    h = {"Content-Type": "application/json", "Authorization": "Bearer " + token()}
    data = json.dumps(body).encode() if body is not None else None
    r = urllib.request.Request(f"https://{HOST}{path}", data=data, headers=h, method=method)
    try:
        resp = urllib.request.urlopen(r, timeout=timeout, context=CTX)
        s = resp.read().decode()
        return resp.status, (json.loads(s) if s.strip() else {})
    except urllib.error.HTTPError as e:
        s = e.read().decode()
        try:
            return e.code, json.loads(s)
        except Exception:
            return e.code, {"raw": s}


def pj(o):
    print(json.dumps(o, indent=2, ensure_ascii=False))


# ---------- task ----------
def _flat(subs, acc):
    for s in subs:
        acc.append(s)
        _flat(s.get("subTasks", []), acc)
    return acc


def watch_task(tid, interval=60):
    """GET /v1/tasks/{id} 盯到 SUCCESSFUL / FAILED;失敗時印出失敗 subtask 的 errors。"""
    while True:
        st, t = api(f"/v1/tasks/{tid}")
        subs = _flat(t.get("subTasks", []), [])
        done = sum(1 for s in subs if s.get("status") == "SUCCESSFUL")
        running = [s["name"] for s in subs if s.get("status") == "IN_PROGRESS"]
        log(f"{t.get('status')} {done}/{len(subs)} {running}")
        if str(t.get("status")).upper() in ("SUCCESSFUL", "FAILED"):
            for s in subs:
                if s.get("status") == "FAILED":
                    print("FAILED:", s["name"])
                    pj(s.get("errors"))
            return t
        time.sleep(interval)


def validation_wait(path_get, resp, interval=10, max_wait=1800):
    """hosts 的 validations 是非同步(POST 回 id → GET 到 COMPLETED);
    clusters 的 validations 是同步(POST 直接回 COMPLETED,之後 GET /{id} 會 400)。兩種都吃。"""
    v = resp
    waited = 0
    while v.get("executionStatus") != "COMPLETED":
        if waited >= max_wait:
            sys.exit(f"validation 超過 {max_wait}s 未完成: {json.dumps(v, ensure_ascii=False)[:300]}")
        time.sleep(interval); waited += interval
        st, v2 = api(f"{path_get}/{v['id']}")
        if st >= 400:
            sys.exit(f"GET {path_get}/{v['id']} -> {st} {json.dumps(v2, ensure_ascii=False)[:300]}")
        v = v2
    return v


def print_validation(v):
    print("validation:", v.get("executionStatus"), v.get("resultStatus"))
    for c in v.get("validationChecks", []):
        if c.get("resultStatus") != "SUCCEEDED":
            print("  ", c.get("resultStatus"), c.get("description"), "|",
                  (c.get("errorResponse") or {}).get("message"))


# ---------- inventory helpers ----------
def find_cluster(name):
    st, r = api("/v1/clusters")
    for c in r.get("elements", []):
        if c["name"] == name:
            return c
    sys.exit(f"找不到 cluster {name}")


def find_host(fqdn):
    st, r = api("/v1/hosts")
    for h in r.get("elements", []):
        if h["fqdn"].lower() == fqdn.lower():
            return h
    sys.exit(f"找不到 host {fqdn}(要先 commission)")


def find_pool(name):
    st, r = api("/v1/network-pools")
    for p in r.get("elements", []):
        if p["name"] == name:
            return p
    sys.exit(f"找不到 network pool {name}")


def split_host(item):
    """'esx05.alan.lab' 或 'esx05.alan.lab=192.168.120.65'(跳板機解不到 DNS 時用 IP 連)→ (fqdn, connect_to)"""
    fqdn, _, ip = item.strip().partition("=")
    return fqdn, (ip or fqdn)


THUMB_ALGO = "sha1"   # 2026-09 alan.lab 實測 VCF 9.1.1 commission 吃 SHA-1(20 bytes);要 SHA-256 加 --sha256


def ssl_thumbprint(fqdn, port=443, connect_to=None):
    """算 ESXi 憑證 thumbprint(冒號分隔大寫),commission spec 的 sslThumbprint 用。"""
    with socket.create_connection((connect_to or fqdn, port), timeout=10) as s:
        with CTX.wrap_socket(s, server_hostname=fqdn) as ss:
            der = ss.getpeercert(binary_form=True)
    h = hashlib.new(THUMB_ALGO, der).hexdigest().upper()
    return ":".join(h[i:i + 2] for i in range(0, len(h), 2))


# ---------- commands ----------
def cmd_token(a):
    print("token OK:", token()[:24] + "...")


def cmd_hosts(a):
    st, r = api("/v1/hosts")
    for h in r.get("elements", []):
        print(f"{h['id']}  {h['fqdn']:24s} {h['status']:22s} pool={(h.get('networkpool') or {}).get('name')}")


def cmd_clusters(a):
    st, r = api("/v1/clusters")
    for c in r.get("elements", []):
        print(f"{c['id']}  {c['name']:16s} stretched={c.get('isStretched')} hosts={len(c.get('hosts', []))}")


def cmd_pools(a):
    st, r = api("/v1/network-pools")
    for p in r.get("elements", []):
        print(f"{p['id']}  {p['name']}")


def cmd_thumbprint(a):
    fqdn, ip = split_host(a.fqdn)
    print(ssl_thumbprint(fqdn, connect_to=ip))


def cmd_remove_host(a):
    """POST /v1/clusters/{id}/validations → PATCH /v1/clusters/{id}(clusterCompactionSpec)→ DELETE /v1/hosts"""
    cl = find_cluster(a.cluster)
    h = find_host(a.host)
    spec = {"clusterCompactionSpec": {"hosts": [{"id": h["id"]}]}}
    st, r = api(f"/v1/clusters/{cl['id']}/validations", "POST", spec)
    if st not in (200, 202):
        pj(r); sys.exit(1)
    v = validation_wait(f"/v1/clusters/{cl['id']}/validations", r)
    print_validation(v)
    if v.get("resultStatus") != "SUCCEEDED":
        sys.exit(1)
    st, r = api(f"/v1/clusters/{cl['id']}", "PATCH", spec)
    print("PATCH compaction ->", st, r.get("name") or r)
    t = watch_task(r.get("id"))
    if str(t.get("status")).upper() != "SUCCESSFUL":
        sys.exit(1)
    if a.decommission:
        st, r = api("/v1/hosts", "DELETE", [{"fqdn": a.host}])
        print("DELETE host ->", st, r.get("name") or r)
        watch_task(r.get("id"))


def cmd_commission(a):
    """POST /v1/hosts/validations → POST /v1/hosts"""
    pool = find_pool(a.pool)
    spec = []
    for item in a.hosts.split(","):
        fq, ip = split_host(item)
        spec.append({"fqdn": fq, "username": "root", "password": a.password, "storageType": "VSAN",
                     "networkPoolId": pool["id"], "networkPoolName": pool["name"],
                     "sslThumbprint": ssl_thumbprint(fq, connect_to=ip)})
    st, r = api("/v1/hosts/validations", "POST", spec)
    if st not in (200, 202):
        pj(r); sys.exit(1)
    v = validation_wait("/v1/hosts/validations", r)
    print_validation(v)
    if v.get("resultStatus") != "SUCCEEDED" or a.validate_only:
        return
    st, r = api("/v1/hosts", "POST", spec)
    print("POST hosts ->", st, r.get("name") or r)
    watch_task(r.get("id"))


def cmd_gen_stretch_spec(a):
    """從既有 cluster 抓 VDS 名稱/uplink 對應(AZ2 主機必須照抄),產生 clusterStretchSpec。"""
    cl = find_cluster(a.cluster)
    st, ref = api(f"/v1/hosts/{cl['hosts'][0]['id']}")
    vmnics = []
    for n in ref.get("physicalNics", []):
        vds = n.get("vdsName") or (n.get("vds") or {}).get("name")
        if not vds:
            continue
        vmnics.append({"id": n["deviceName"], "vdsName": vds, "uplink": n.get("uplink") or f"uplink{len(vmnics) + 1}"})
    if not vmnics:  # 拿不到就用 VCF 預設命名
        vds = f"{a.cluster}-vds01"
        vmnics = [{"id": "vmnic0", "vdsName": vds, "uplink": "uplink1"},
                  {"id": "vmnic1", "vdsName": vds, "uplink": "uplink2"}]
    host_specs = []
    for fq in a.hosts.split(","):
        h = find_host(fq.strip())
        host_specs.append({"id": h["id"], "hostname": h["fqdn"], "hostNetworkSpec": {"vmNics": vmnics}})
    spec = {"clusterStretchSpec": {
        "hostSpecs": host_specs,
        "witnessSpec": {"fqdn": a.witness, "vsanIp": a.witness_ip, "vsanCidr": a.witness_cidr},
        "witnessTrafficSharedWithVsanTraffic": True,
        "secondaryAzOverlayVlanId": a.overlay_vlan,
        "isEdgeClusterConfiguredForMultiAZ": False,
        "deployWithoutLicenseKeys": True}}
    json.dump(spec, open(a.output, "w"), indent=2)
    pj(spec)
    print("written", a.output)


def cmd_stretch(a):
    """POST /v1/clusters/{id}/validations → PATCH /v1/clusters/{id}(clusterStretchSpec)"""
    cl = find_cluster(a.cluster)
    spec = json.load(open(a.spec))
    st, r = api(f"/v1/clusters/{cl['id']}/validations", "POST", spec)
    if st not in (200, 202):
        pj(r); sys.exit(1)
    v = validation_wait(f"/v1/clusters/{cl['id']}/validations", r)
    print_validation(v)
    if v.get("resultStatus") != "SUCCEEDED" or a.validate_only:
        return
    st, r = api(f"/v1/clusters/{cl['id']}", "PATCH", spec)
    print("PATCH stretch ->", st, r.get("name") or r, "task", r.get("id"))
    if r.get("id"):
        open("stretch-task.txt", "w").write(r["id"])
    if a.watch and r.get("id"):
        watch_task(r["id"])


def cmd_unstretch(a):
    """POST /v1/clusters/{id}/validations → PATCH /v1/clusters/{id}(clusterUnstretchSpec):拆回一般 cluster,
    AZ2 主機退回 UNASSIGNED_USEABLE、witness 解除。"""
    cl = find_cluster(a.cluster)
    spec = {"clusterUnstretchSpec": {}}
    st, r = api(f"/v1/clusters/{cl['id']}/validations", "POST", spec)
    if st not in (200, 202):
        pj(r); sys.exit(1)
    v = validation_wait(f"/v1/clusters/{cl['id']}/validations", r)
    print_validation(v)
    if v.get("resultStatus") != "SUCCEEDED" or a.validate_only:
        return
    st, r = api(f"/v1/clusters/{cl['id']}", "PATCH", spec)
    print("PATCH unstretch ->", st, r.get("name") or r, "task", r.get("id"))
    if a.watch and r.get("id"):
        watch_task(r["id"])


def cmd_task(a):
    st, t = api(f"/v1/tasks/{a.id}")
    subs = _flat(t.get("subTasks", []), [])
    print(t.get("name"), t.get("status"), f"retryable={t.get('isRetryable')}")
    for s in subs:
        if s.get("status") in ("FAILED", "IN_PROGRESS"):
            print(" ", s["status"], s["name"])
            if s.get("errors"):
                pj(s["errors"])


def cmd_watch(a):
    watch_task(a.id)


def cmd_retry(a):
    """PATCH /v1/tasks/{id} = retry 失敗的 task(從失敗的 subtask 續跑)。"""
    st, r = api(f"/v1/tasks/{a.id}", "PATCH")
    print("retry ->", st, r)
    watch_task(a.id)


def main():
    global HOST, USER, PASS, THUMB_ALGO
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--sddc", default=HOST)
    p.add_argument("--user", default=USER)
    p.add_argument("--password-sddc", default=PASS)
    p.add_argument("--sha256", action="store_true", help="thumbprint 用 SHA-256(預設 SHA-1)")
    sp = p.add_subparsers(dest="cmd", required=True)
    sp.add_parser("token").set_defaults(f=cmd_token)
    sp.add_parser("hosts").set_defaults(f=cmd_hosts)
    sp.add_parser("clusters").set_defaults(f=cmd_clusters)
    sp.add_parser("pools").set_defaults(f=cmd_pools)
    x = sp.add_parser("thumbprint"); x.add_argument("fqdn", help="fqdn 或 fqdn=ip"); x.set_defaults(f=cmd_thumbprint)
    x = sp.add_parser("remove-host"); x.add_argument("--cluster", required=True); x.add_argument("--host", required=True)
    x.add_argument("--decommission", action="store_true"); x.set_defaults(f=cmd_remove_host)
    x = sp.add_parser("commission"); x.add_argument("--hosts", required=True); x.add_argument("--pool", required=True)
    x.add_argument("--password", required=True, help="ESXi root 密碼"); x.add_argument("--validate-only", action="store_true")
    x.set_defaults(f=cmd_commission)
    x = sp.add_parser("gen-stretch-spec"); x.add_argument("--cluster", required=True); x.add_argument("--hosts", required=True)
    x.add_argument("--witness", required=True); x.add_argument("--witness-ip", required=True); x.add_argument("--witness-cidr", required=True)
    x.add_argument("--overlay-vlan", type=int, default=150); x.add_argument("-o", "--output", default="stretch-spec.json")
    x.set_defaults(f=cmd_gen_stretch_spec)
    x = sp.add_parser("stretch"); x.add_argument("--cluster", required=True); x.add_argument("--spec", required=True)
    x.add_argument("--validate-only", action="store_true"); x.add_argument("--watch", action="store_true"); x.set_defaults(f=cmd_stretch)
    x = sp.add_parser("unstretch"); x.add_argument("--cluster", required=True)
    x.add_argument("--validate-only", action="store_true"); x.add_argument("--watch", action="store_true"); x.set_defaults(f=cmd_unstretch)
    x = sp.add_parser("task"); x.add_argument("id"); x.set_defaults(f=cmd_task)
    x = sp.add_parser("watch"); x.add_argument("id"); x.set_defaults(f=cmd_watch)
    x = sp.add_parser("retry"); x.add_argument("id"); x.set_defaults(f=cmd_retry)
    a = p.parse_args()
    HOST, USER = a.sddc, a.user
    if a.sha256:
        THUMB_ALGO = "sha256"
    if a.password_sddc:
        PASS = a.password_sddc
    a.f(a)


if __name__ == "__main__":
    main()
