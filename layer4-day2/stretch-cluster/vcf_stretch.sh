#!/usr/bin/env bash
# vcf_stretch.sh — 純 bash + curl 打 SDDC Manager API(vcf_stretch.py 的 shell 版)。
# 需要:curl;JSON 解析用 jq,沒 jq 會自動退回 python3。
#
#   export SDDC_HOST=192.168.120.4 SDDC_USER=administrator@vsphere.local SDDC_PASS='...'
#
#   ./vcf_stretch.sh token
#   ./vcf_stretch.sh hosts | clusters | pools
#   ./vcf_stretch.sh get  /v1/hosts                         # 任意 GET,印原始 JSON
#   ./vcf_stretch.sh remove-host  vcf-m01-cl01 esx04.alan.lab [--decommission]
#   ./vcf_stretch.sh commission   hosts.json [--validate-only]
#   ./vcf_stretch.sh validate     vcf-m01-cl01 stretch-spec.json    # 只驗證
#   ./vcf_stretch.sh stretch      vcf-m01-cl01 stretch-spec.json    # 驗證 → PATCH → 盯
#   ./vcf_stretch.sh task  <taskId>
#   ./vcf_stretch.sh watch <taskId>
#   ./vcf_stretch.sh retry <taskId>
set -euo pipefail

B="https://${SDDC_HOST:-192.168.120.4}"
USER_="${SDDC_USER:-administrator@vsphere.local}"
PASS_="${SDDC_PASS:-}"
CURL="curl -sk"                           # -k 自簽憑證;4xx/5xx 的 body 照印出來,自己看 errorCode
[[ -n "$PASS_" ]] || { echo "請 export SDDC_PASS" >&2; exit 1; }

# ---- JSON 取值:jq 有就用 jq,沒有就 python3 ----
if command -v jq >/dev/null; then
  jget() { jq -r "$1"; }                  # jget '.accessToken'
else
  jget() { python3 -c "import sys,json,functools
d=json.load(sys.stdin); p=sys.argv[1].strip('.').split('.')
for k in p:
    d=d[int(k)] if k.isdigit() else d.get(k)
print(d if not isinstance(d,(dict,list)) else json.dumps(d))" "$1"; }
fi

# ---- token:POST /v1/tokens → accessToken ----
token() {
  $CURL -X POST "$B/v1/tokens" -H 'Content-Type: application/json' \
    -d "{\"username\":\"$USER_\",\"password\":\"$PASS_\"}" | jget '.accessToken'
}
TOKEN="$(token)"
H=(-H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json')

api()   { $CURL -X "$1" "$B$2" "${H[@]}" "${@:3}"; }     # api GET /v1/hosts ; api PATCH /v1/clusters/ID -d @spec.json
log()   { echo "[$(date +%H:%M:%S)] $*"; }

# ---- inventory ----
cluster_id() { api GET /v1/clusters | jq -r --arg n "$1" '.elements[] | select(.name==$n) | .id'; }
host_id()    { api GET /v1/hosts    | jq -r --arg n "$1" '.elements[] | select(.fqdn==$n) | .id'; }

# ---- 驗證:hosts 的是非同步(POST 拿 id → GET 到 COMPLETED);clusters 的是同步(POST 直接回 COMPLETED)----
validate() {   # validate <validations-path> <spec.json>
  local path="$1" spec="$2" vid v r
  r="$(api POST "$path" -d @"$spec")"
  vid="$(echo "$r" | jget '.id')"
  [[ -n "$vid" && "$vid" != "null" ]] || { echo "validation request rejected:"; echo "$r" | (jq . 2>/dev/null || cat); return 1; }
  v="$r"
  while [[ "$(echo "$v" | jget '.executionStatus')" != "COMPLETED" ]]; do
    sleep 10
    v="$(api GET "$path/$vid")"
  done
  echo "validation: $(echo "$v" | jget '.resultStatus')"
  echo "$v" | jq -r '.validationChecks[]? | select(.resultStatus!="SUCCEEDED") | "  \(.resultStatus) \(.description) | \(.errorResponse.message // "")"'
  [[ "$(echo "$v" | jget '.resultStatus')" == "SUCCEEDED" ]]
}

# ---- task:攤平 subTasks,盯到 SUCCESSFUL / FAILED ----
task_show() {
  api GET "/v1/tasks/$1" | jq -r '
    [.. | objects | select(has("status") and has("name"))] as $all
    | "\(.name) | \(.status) | retryable=\(.isRetryable)",
      ($all | map(select(.status=="FAILED" or .status=="IN_PROGRESS"))[] | "  \(.status) \(.name) \(.errors[0].message // "")")'
}
watch() {
  local t st
  while :; do
    t="$(api GET "/v1/tasks/$1")"
    st="$(echo "$t" | jget '.status')"
    log "$st $(echo "$t" | jq -r '[.. | objects | select(.status?=="SUCCESSFUL")] | length')/$(echo "$t" | jq -r '[.. | objects | select(has("status") and has("name"))] | length - 1') $(echo "$t" | jq -c '[.. | objects | select(.status?=="IN_PROGRESS") | .name] | .[1:]')"
    case "${st^^}" in
      SUCCESSFUL) return 0 ;;
      FAILED) echo "$t" | jq -r '.. | objects | select(.status?=="FAILED") | "FAILED: \(.name)\n\(.errors // [] | tojson)"' ; return 1 ;;
    esac
    sleep 60
  done
}

# ---- 子命令 ----
cmd="${1:-}"; shift || true
case "$cmd" in
  token)    echo "token OK: ${TOKEN:0:24}..." ;;
  get)      api GET "$1" | (jq . 2>/dev/null || cat) ;;
  hosts)    api GET /v1/hosts    | jq -r '.elements[] | "\(.id)  \(.fqdn)\t\(.status)\tpool=\(.networkpool.name)"' ;;
  clusters) api GET /v1/clusters | jq -r '.elements[] | "\(.id)  \(.name)\tstretched=\(.isStretched)\thosts=\(.hosts|length)"' ;;
  pools)    api GET /v1/network-pools | jq -r '.elements[] | "\(.id)  \(.name)"' ;;

  remove-host)   # remove-host <cluster> <fqdn> [--decommission]
    CL="$(cluster_id "$1")"; HID="$(host_id "$2")"
    printf '{"clusterCompactionSpec":{"hosts":[{"id":"%s"}]}}' "$HID" > /tmp/compaction.json
    validate "/v1/clusters/$CL/validations" /tmp/compaction.json
    TID="$(api PATCH "/v1/clusters/$CL" -d @/tmp/compaction.json | jget '.id')"; log "task $TID"
    watch "$TID"
    if [[ "${3:-}" == "--decommission" ]]; then
      TID="$(api DELETE /v1/hosts -d "[{\"fqdn\":\"$2\"}]" | jget '.id')"; log "decommission task $TID"; watch "$TID"
    fi ;;

  commission)    # commission <hosts.json> [--validate-only]   (hosts.json = HostCommissionSpec 陣列)
    validate /v1/hosts/validations "$1"
    [[ "${2:-}" == "--validate-only" ]] && exit 0
    TID="$(api POST /v1/hosts -d @"$1" | jget '.id')"; log "task $TID"; watch "$TID" ;;

  validate)      # validate <cluster> <spec.json>
    CL="$(cluster_id "$1")"; validate "/v1/clusters/$CL/validations" "$2" ;;

  stretch)       # stretch <cluster> <stretch-spec.json>
    CL="$(cluster_id "$1")"
    validate "/v1/clusters/$CL/validations" "$2"
    r="$(api PATCH "/v1/clusters/$CL" -d @"$2")"; TID="$(echo "$r" | jget '.id')"
    [[ -n "$TID" && "$TID" != "null" ]] || { echo "$r" | (jq . 2>/dev/null || cat); exit 1; }
    log "stretch task $TID"
    echo "$TID" > stretch-task.txt
    watch "$TID" ;;

  task)   task_show "$1" ;;
  watch)  watch "$1" ;;
  retry)  api PATCH "/v1/tasks/$1" >/dev/null && log "retry sent"; watch "$1" ;;
  *) sed -n '2,17p' "$0"; exit 1 ;;
esac
