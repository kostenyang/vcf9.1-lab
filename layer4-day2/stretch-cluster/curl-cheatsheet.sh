#!/usr/bin/env bash
# curl-cheatsheet.sh — 一行一個 curl,照順序貼到跳板機 shell 就能打 SDDC Manager API。
# 不是要整支執行(每步之間要等 task),是拿來複製貼上的。需要 curl + jq。

B=https://192.168.120.4
export SDDC_PASS='<pw>'          # 先設密碼,別直接寫在命令列歷史裡

# ---------- 0. token(每次開新 shell 先做;約 1 小時過期就重打) ----------
TOKEN=$(curl -sk -X POST "$B/v1/tokens" -H 'Content-Type: application/json' \
  -d "{\"username\":\"administrator@vsphere.local\",\"password\":\"$SDDC_PASS\"}" | jq -r .accessToken)
H="Authorization: Bearer $TOKEN"; C="Content-Type: application/json"
echo "${TOKEN:0:20}..."

# ---------- 1. 查 inventory(拿 id) ----------
curl -sk "$B/v1/clusters"      -H "$H" | jq -r '.elements[] | "\(.id) \(.name) stretched=\(.isStretched)"'
curl -sk "$B/v1/hosts"         -H "$H" | jq -r '.elements[] | "\(.id) \(.fqdn) \(.status)"'
curl -sk "$B/v1/network-pools" -H "$H" | jq -r '.elements[] | "\(.id) \(.name)"'

CL=$(curl -sk "$B/v1/clusters" -H "$H" | jq -r '.elements[] | select(.name=="vcf-m01-cl01") | .id')
NP=$(curl -sk "$B/v1/network-pools" -H "$H" | jq -r '.elements[] | select(.name=="m01-np01") | .id')

# ---------- 2. 移除一台主機(cluster compaction)+ decommission ----------
HID=$(curl -sk "$B/v1/hosts" -H "$H" | jq -r '.elements[] | select(.fqdn=="esx04.alan.lab") | .id')
echo "{\"clusterCompactionSpec\":{\"hosts\":[{\"id\":\"$HID\"}]}}" > compaction.json

VID=$(curl -sk -X POST "$B/v1/clusters/$CL/validations" -H "$H" -H "$C" -d @compaction.json | jq -r .id)
curl -sk "$B/v1/clusters/$CL/validations/$VID" -H "$H" | jq '{executionStatus,resultStatus}'      # 反覆打到 COMPLETED
TID=$(curl -sk -X PATCH "$B/v1/clusters/$CL" -H "$H" -H "$C" -d @compaction.json | jq -r .id)
curl -sk "$B/v1/tasks/$TID" -H "$H" | jq '{name,status}'                                              # 反覆打到 Successful

curl -sk -X DELETE "$B/v1/hosts" -H "$H" -H "$C" -d '[{"fqdn":"esx04.alan.lab"}]' | jq '{id,name,status}'

# ---------- 3. commission 新主機 ----------
# thumbprint(SHA-1,冒號分隔大寫)。跳板機解不到 alan.lab 就直接用 IP;實測結果與 vcf_stretch.py thumbprint 相同
TP=$(openssl s_client -connect 192.168.120.65:443 </dev/null 2>/dev/null | openssl x509 -fingerprint -sha1 -noout | cut -d= -f2)
cat > hosts.json <<EOF
[{"fqdn":"esx05.alan.lab","username":"root","password":"<esxi-pw>","storageType":"VSAN",
  "networkPoolId":"$NP","networkPoolName":"m01-np01","sslThumbprint":"$TP"}]
EOF
VID=$(curl -sk -X POST "$B/v1/hosts/validations" -H "$H" -H "$C" -d @hosts.json | jq -r .id)
curl -sk "$B/v1/hosts/validations/$VID" -H "$H" | jq '{executionStatus,resultStatus, fail:[.validationChecks[]?|select(.resultStatus!="SUCCEEDED")|.description]}'
TID=$(curl -sk -X POST "$B/v1/hosts" -H "$H" -H "$C" -d @hosts.json | jq -r .id)
curl -sk "$B/v1/tasks/$TID" -H "$H" | jq '{name,status}'

# ---------- 4. stretch ----------
# stretch-spec.json 見附錄 A(hostSpecs 的 id 用 /v1/hosts 查到的)
VID=$(curl -sk -X POST "$B/v1/clusters/$CL/validations" -H "$H" -H "$C" -d @stretch-spec.json | jq -r .id)
curl -sk "$B/v1/clusters/$CL/validations/$VID" -H "$H" | jq '{executionStatus,resultStatus, fail:[.validationChecks[]?|select(.resultStatus!="SUCCEEDED")|{description,msg:.errorResponse.message}]}'
TID=$(curl -sk -X PATCH "$B/v1/clusters/$CL" -H "$H" -H "$C" -d @stretch-spec.json | jq -r .id)
echo "$TID"

# ---------- 5. 盯 task / 看失敗 / retry ----------
curl -sk "$B/v1/tasks/$TID" -H "$H" | jq '{name,status,isRetryable}'
# 正在跑的 subtask
curl -sk "$B/v1/tasks/$TID" -H "$H" | jq -r '.. | objects | select(.status?=="IN_PROGRESS") | .name'
# 失敗的 subtask + errors
curl -sk "$B/v1/tasks/$TID" -H "$H" | jq '.. | objects | select(.status?=="FAILED") | {name, errors}'
# 每 60 秒印一次直到結束
while :; do S=$(curl -sk "$B/v1/tasks/$TID" -H "$H" | jq -r .status); echo "$(date +%T) $S"; [[ "$S" =~ ^(Successful|Failed)$ ]] && break; sleep 60; done
# retry(從失敗的 subtask 續跑)
curl -sk -X PATCH "$B/v1/tasks/$TID" -H "$H" -w '%{http_code}\n'

# ---------- 6. 驗證結果 ----------
curl -sk "$B/v1/clusters/$CL" -H "$H" | jq '{name,isStretched,hosts:(.hosts|length)}'
