#!/usr/bin/env python3
"""把 VCF Installer 接到 offline depot (HTTP no-auth) + 觸發 metadata sync。

眉角:depot URL 用 IP 不用 FQDN(9.1 installer URL 驗證對 FQDN 會擋);HTTP no-auth 避免
自簽憑證問題;URL 給根 (http://IP:PORT),installer 自接 /PROD。

  pip install requests
  python connect_offline_depot.py --installer-ip 10.0.1.4 --depot-url http://10.0.0.61:8888
"""
import argparse
import time
import requests
import urllib3
urllib3.disable_warnings()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--installer-ip", default="10.0.1.4")
    ap.add_argument("--installer-user", default="admin@local")
    ap.add_argument("--installer-password", default="VMware1!VMware1!")
    ap.add_argument("--depot-url", default="http://10.0.0.61:8888", help="用 IP! 不要 FQDN")
    ap.add_argument("--skip-sync", action="store_true")
    a = ap.parse_args()
    base = f"https://{a.installer_ip}"

    def tok():
        r = requests.post(f"{base}/v1/tokens",
                          json={"username": a.installer_user, "password": a.installer_password},
                          verify=False, timeout=20)
        r.raise_for_status()
        return r.json()["accessToken"]

    h = {"Authorization": f"Bearer {tok()}", "Content-Type": "application/json"}
    print(f"PUT offline depot: {a.depot_url}")
    body = {"depotConfiguration": {"isOfflineDepot": True, "url": a.depot_url}}
    r = requests.put(f"{base}/v1/system/settings/depot", headers=h, json=body, verify=False, timeout=90)
    if r.status_code >= 400:
        raise SystemExit(f"depot 接上失敗 HTTP {r.status_code}: {r.text}")
    j = r.json()
    status = (j.get("offlineAccount") or j.get("vmwareAccount") or {}).get("status")
    print(f"  -> status: {status}")
    if not status or "SUCCESS" not in status:
        raise SystemExit(f"depot 接上失敗: {j}")

    if not a.skip_sync:
        print("觸發 metadata sync...")
        try:
            requests.patch(f"{base}/v1/system/settings/depot/depot-sync-info", headers=h, verify=False, timeout=60)
        except Exception:
            pass
        for _ in range(20):
            time.sleep(15)
            h = {"Authorization": f"Bearer {tok()}"}
            si = requests.get(f"{base}/v1/system/settings/depot/depot-sync-info", headers=h, verify=False, timeout=30).json()
            ss = si.get("status") or si.get("syncStatus")
            print(f"  sync: {ss}")
            if ss and any(k in ss for k in ("SYNC", "SUCCESS", "COMPLETED")):
                break
        b = requests.get(f"{base}/v1/bundles", headers=h, verify=False, timeout=60).json().get("elements", [])
        ok = sum(1 for x in b if x.get("downloadStatus") == "SUCCESSFUL")
        print(f"bundles: {len(b)} 總, {ok} SUCCESSFUL")
    print("完成。")


if __name__ == "__main__":
    main()
