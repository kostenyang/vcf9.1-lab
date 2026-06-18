#!/usr/bin/env python3
"""監控 VCF Installer bring-up 進度到完成/失敗。沒給 --sddc-id 會自動抓進行中的。

  pip install requests
  python watch_bringup.py --installer-ip 10.0.1.4
"""
import argparse
import time
import datetime
import requests
import urllib3
urllib3.disable_warnings()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--installer-ip", default="10.0.1.4")
    ap.add_argument("--installer-user", default="admin@local")
    ap.add_argument("--installer-password", default="VMware1!VMware1!")
    ap.add_argument("--sddc-id", default=None)
    ap.add_argument("--interval-sec", type=int, default=120)
    ap.add_argument("--max-hours", type=float, default=6)
    a = ap.parse_args()
    base = f"https://{a.installer_ip}"

    def tok():
        r = requests.post(f"{base}/v1/tokens",
                          json={"username": a.installer_user, "password": a.installer_password},
                          verify=False, timeout=20)
        r.raise_for_status()
        return r.json()["accessToken"]

    sddc_id = a.sddc_id
    if not sddc_id:
        data = requests.get(f"{base}/v1/sddcs", headers={"Authorization": f"Bearer {tok()}"}, verify=False, timeout=30).json()
        elems = data.get("elements", data) if isinstance(data, dict) else data
        running = [e for e in elems if str(e.get("status")).find("PROGRESS") >= 0 or e.get("status") == "RUNNING"]
        if not running:
            raise SystemExit("找不到進行中的 bring-up,請給 --sddc-id")
        sddc_id = running[0]["id"]
        print(f"自動偵測 sddcId: {sddc_id}")

    last_mile = None
    iters = int((a.max_hours * 3600) / a.interval_sec)
    for _ in range(iters):
        try:
            h = {"Authorization": f"Bearer {tok()}"}
            s = requests.get(f"{base}/v1/sddcs/{sddc_id}", headers=h, verify=False, timeout=30).json()
            subs = s.get("sddcSubTasks", [])
            done = sum(1 for t in subs if str(t.get("status")) in ("COMPLETED_WITH_SUCCESS", "SUCCESSFUL"))
            inprog = [t for t in subs if t.get("status") in ("IN_PROGRESS", "RUNNING")]
            cur = inprog[0] if inprog else {}
            mile = cur.get("milestoneTask")
            st = s.get("status")
            if mile != last_mile:
                ts = datetime.datetime.now().strftime("%H:%M")
                print(f"[{ts}] done={done}/{len(subs)} {mile} / {cur.get('name')}")
                last_mile = mile
            if st and any(k in st for k in ("COMPLETED_WITH_SUCCESS",)) or st in ("SUCCESS", "COMPLETED", "Active"):
                print(f"=== SUCCESS: {st} ===")
                return
            if st and ("FAIL" in st or "ERROR" in st):
                print(f"=== FAILED: {st} @ {mile}/{cur.get('name')} ===")
                return
        except Exception:
            pass
        time.sleep(a.interval_sec)
    print(f"=== 監控逾時 ({a.max_hours}h),bring-up 仍在跑 ===")


if __name__ == "__main__":
    main()
