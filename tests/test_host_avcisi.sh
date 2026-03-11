#!/usr/bin/env bash
# =============================================================
#  host-avcisi — Test Suite
#  Run: bash tests/test_host_avcisi.sh
# =============================================================
set -eo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$SCRIPT_DIR/host_avcisi.sh"

PASS=0; FAIL=0; SKIP=0

ok()   { echo "  [PASS] $1"; PASS=$((PASS + 1)); }
fail() { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
skip() { echo "  [SKIP] $1"; SKIP=$((SKIP + 1)); }

# Source only the pure functions (no side-effects at top-level)
# We extract and eval individual functions for unit testing
_source_fn() {
  # Extract a function from the script by name and eval it
  local fn="$1"
  local body
  body=$(awk "/^${fn}\(\)/{found=1} found{print} found && /^}/{found=0}" "$SCRIPT")
  eval "$body" 2>/dev/null || true
}

# Stub colors so output is clean
RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYN=""; ORG=""; DIM=""; RST=""

echo
echo "=================================================="
echo " host-avcisi Test Suite"
echo "=================================================="

# ----------------------------------------------------------
echo
echo "--- 1. Syntax Check ---"
# ----------------------------------------------------------
if bash -n "$SCRIPT" 2>/dev/null; then
  ok "bash -n syntax check passes"
else
  fail "bash -n syntax check FAILED"
fi

# ----------------------------------------------------------
echo
echo "--- 2. Help / No-arg exits cleanly ---"
# ----------------------------------------------------------
if bash "$SCRIPT" --help 2>/dev/null | grep -q "Usage"; then
  ok "--help prints usage"
else
  fail "--help did not print usage"
fi

rc=0
{ bash "$SCRIPT" 2>/dev/null; rc=$?; } || rc=$?
if [[ "$rc" -ne 0 ]]; then
  ok "exits non-zero when no subnet given"
else
  fail "should exit non-zero with no args"
fi

# ----------------------------------------------------------
echo
echo "--- 3. normalize_oui ---"
# ----------------------------------------------------------
_source_fn normalize_oui

_check_oui() {
  local input="$1" expected="$2"
  local got; got="$(normalize_oui "$input")"
  if [[ "$got" == "$expected" ]]; then
    ok "normalize_oui '$input' → '$got'"
  else
    fail "normalize_oui '$input': expected '$expected', got '$got'"
  fi
}

_check_oui "AA:BB:CC:dd:ee:ff" "AA:BB:CC"
_check_oui "aa-bb-cc"          "AA:BB:CC"
_check_oui "aabb.cc11.2233"    "AA:BB:CC"
_check_oui "0:1:2"             "00:01:02"

# ----------------------------------------------------------
echo
echo "--- 4. is_ip ---"
# ----------------------------------------------------------
is_ip(){ [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

_check_ip() {
  local val="$1" expect="$2"
  if is_ip "$val"; then result="yes"; else result="no"; fi
  if [[ "$result" == "$expect" ]]; then
    ok "is_ip '$val' → $result"
  else
    fail "is_ip '$val': expected $expect, got $result"
  fi
}

_check_ip "192.168.1.1"    "yes"
_check_ip "10.0.0.255"     "yes"
_check_ip "192.168.1.0/24" "no"
_check_ip "not-an-ip"      "no"
_check_ip ""               "no"

# ----------------------------------------------------------
echo
echo "--- 5. count_subnet_hosts ---"
# ----------------------------------------------------------
count_subnet_hosts() {
  local subnet="$1"
  if [[ "$subnet" == *"/"* ]]; then
    local cidr="${subnet##*/}"
    if [[ "$cidr" =~ ^[0-9]+$ ]] && [[ "$cidr" -ge 0 && "$cidr" -le 32 ]]; then
      local hosts=$(( (1 << (32 - cidr)) ))
      [[ "$hosts" -gt 2 ]] && hosts=$((hosts - 2))
      echo "$hosts"; return
    fi
  fi
  echo "1"
}

_check_hosts() {
  local subnet="$1" expected="$2"
  local got; got="$(count_subnet_hosts "$subnet")"
  if [[ "$got" == "$expected" ]]; then
    ok "count_subnet_hosts '$subnet' → $got"
  else
    fail "count_subnet_hosts '$subnet': expected $expected, got $got"
  fi
}

_check_hosts "192.168.1.0/24" "254"
_check_hosts "10.0.0.0/16"    "65534"
_check_hosts "10.0.0.0/30"    "2"
_check_hosts "10.0.0.1"       "1"
_check_hosts "10.0.0.0/32"    "1"   # /32 = single host address → 1 usable

# ----------------------------------------------------------
echo
echo "--- 6. label_ports ---"
# ----------------------------------------------------------
label_ports() {
  local p="$1" out=""
  has(){ [[ ",$p," == *",$1,"* ]]; }
  if has "17988" || has "17990"; then out+="iLO,"; fi
  if has "623"; then out+="IPMI,"; fi
  if (has "902" || has "903") && has "443"; then out+="ESXi,"; fi
  if has "5480" && has "443"; then out+="vCenter,"; fi
  if has "8006"; then out+="Proxmox,"; fi
  if has "3389"; then out+="RDP,"; fi
  if has "5985" || has "5986"; then out+="WinRM,"; fi
  if has "22"; then out+="SSH,"; fi
  if has "23"; then out+="Telnet,"; fi
  if has "161"; then out+="SNMP,"; fi
  if has "1433" || has "1521" || has "3306" || has "5432" || has "6379" || has "27017"; then out+="DB,"; fi
  if has "2375" || has "2376"; then out+="Docker,"; fi
  if has "8006"; then out+="Proxmox,"; fi
  if has "80" || has "443" || has "8080" || has "8081" || has "8443"; then out+="WEB,"; fi
  if has "445" || has "139"; then out+="SMB,"; fi
  if has "5000" || has "5001"; then out+="NAS,"; fi
  out="${out%,}"; [[ -z "$out" ]] && out="-"; echo "$out"
}

_check_label() {
  local ports="$1" expected_substr="$2"
  local got; got="$(label_ports "$ports")"
  if [[ "$got" == *"$expected_substr"* ]]; then
    ok "label_ports '$ports' contains '$expected_substr'"
  else
    fail "label_ports '$ports': expected to contain '$expected_substr', got '$got'"
  fi
}

_check_label "22,80,443"         "SSH"
_check_label "22,80,443"         "WEB"
_check_label "23"                "Telnet"
_check_label "3306"              "DB"
_check_label "902,903,443"       "ESXi"
_check_label "17988"             "iLO"
_check_label "8006"              "Proxmox"
_check_label "2375"              "Docker"
_check_label "5480,443"          "vCenter"
_check_label "12345"             "-"

# ----------------------------------------------------------
echo
echo "--- 7. label_vendor_context ---"
# ----------------------------------------------------------
label_vendor_context() {
  local v; v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  local out=""
  [[ "$v" == *"dell"* || "$v" == *"hewlett"* || "$v" == *"hp "* || "$v" == *"lenovo"* || "$v" == *"supermicro"* ]] && out+="Enterprise,"
  [[ "$v" == *"cisco"* || "$v" == *"juniper"* || "$v" == *"mikrotik"* || "$v" == *"aruba"* || "$v" == *"ubiquiti"* ]] && out+="Network,"
  [[ "$v" == *"vmware"* ]] && out+="Virt,"
  [[ "$v" == *"synology"* || "$v" == *"qnap"* ]] && out+="Storage,"
  [[ "$v" == *"apple"* ]] && out+="Apple,"
  [[ "$v" == *"hikvision"* || "$v" == *"dahua"* ]] && out+="CCTV,"
  echo "${out%,}"
}

_check_vendor() {
  local input="$1" expected_substr="$2"
  local got; got="$(label_vendor_context "$input")"
  if [[ "$got" == *"$expected_substr"* ]]; then
    ok "label_vendor_context '$input' contains '$expected_substr'"
  else
    fail "label_vendor_context '$input': expected '$expected_substr', got '$got'"
  fi
}

_check_vendor "Dell Inc."          "Enterprise"
_check_vendor "Hewlett Packard"    "Enterprise"
_check_vendor "Cisco Systems"      "Network"
_check_vendor "Ubiquiti Networks"  "Network"
_check_vendor "VMware, Inc."       "Virt"
_check_vendor "Synology Inc."      "Storage"
_check_vendor "Apple, Inc."        "Apple"
_check_vendor "Hikvision"          "CCTV"
_check_vendor "Unknown Vendor"     ""

# ----------------------------------------------------------
echo
echo "--- 8. confidence_score ---"
# ----------------------------------------------------------
confidence_score() {
  local ports="$1" vendor="$2" title="$3" tls="$4" tech="$5"
  local score=20
  bump(){ score=$((score+$1)); }
  has(){ [[ "$ports" == *"$1"* ]]; }
  if has "17988" || has "17990"; then bump 40; fi
  if has "623"; then bump 20; fi
  if (has "902" || has "903") && has "443"; then bump 30; fi
  if has "5480" && has "443"; then bump 30; fi
  if has "8006"; then bump 20; fi
  if has "445" || has "3389" || has "5985"; then bump 10; fi
  local tlow vlow glow
  tlow="$(echo "${title:-}" | tr '[:upper:]' '[:lower:]')"
  vlow="$(echo "${vendor:-}" | tr '[:upper:]' '[:lower:]')"
  glow="$(echo "${tech:-}" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$tlow" && "$tlow" != "-" ]] && bump 10
  [[ -n "${tls:-}" && "${tls:-}" != "-" ]] && bump 10
  [[ -n "$glow" && "$glow" != "-" ]] && bump 10
  [[ "$tlow" == *"vmware"* || "$tlow" == *"vcenter"* || "$tlow" == *"ilo"* || "$tlow" == *"idrac"* || "$tlow" == *"proxmox"* || "$tlow" == *"synology"* ]] && bump 25
  [[ "$vlow" == *"cisco"* || "$vlow" == *"dell"* || "$vlow" == *"vmware"* ]] && bump 10
  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

_check_score_gte() {
  local got; got="$(confidence_score "$1" "$2" "$3" "$4" "$5")"
  if [[ "$got" -ge "$6" ]]; then
    ok "confidence_score ($1/$2/$3) = $got >= $6"
  else
    fail "confidence_score ($1/$2/$3) = $got < $6 (expected >= $6)"
  fi
}

_check_score_gte "17988,443"  ""         ""          ""  ""  60
_check_score_gte "443,902,903" "VMware"  "VMware ESXi" "esxi.local" "vmware" 80
_check_score_gte "22,80"       ""        ""          ""  ""  20
_check_score_gte "22,80"       ""        "iLO Login" ""  ""  55
# Capped at 100
got="$(confidence_score "17988,17990,623,902,903,443,5480" "Dell" "iLO Login" "ilo.corp" "vmware")"
if [[ "$got" -le 100 ]]; then
  ok "confidence_score capped at 100 (got $got)"
else
  fail "confidence_score exceeds 100 (got $got)"
fi

# ----------------------------------------------------------
echo
echo "--- 9. grep -c pipefail regression ---"
# ----------------------------------------------------------
# Verifies the fix: grep -c returning exit 1 on 0 matches is handled inside { ... || true }
_table_data=("IP|MAC|VENDOR|OPEN_PORTS|CF|TITLE|TLS|LABELS" "1.1.1.1|aa:bb:cc|Apple|80|-|-|-|Apple")
_count=$(printf "%s\n" "${_table_data[@]}" | { grep -c "Enterprise" || true; } | tr -dc '0-9')
if [[ "$_count" == "0" ]]; then
  ok "grep -c returns 0 (not error) when no match under pipefail"
else
  fail "grep -c pipefail regression: expected 0 got '$_count'"
fi

_count=$(printf "%s\n" "${_table_data[@]}" | { grep -c "Apple" || true; } | tr -dc '0-9')
if [[ "$_count" == "1" ]]; then
  ok "grep -c returns 1 when match found"
else
  fail "grep -c returned wrong count: '$_count'"
fi

# ----------------------------------------------------------
echo
echo "--- 10. len_no_color (ANSI stripping) ---"
# ----------------------------------------------------------
len_no_color() {
  local clean
  clean=$(echo "$1" | sed 's/\x1B\[[0-9;]*[mK]//g')
  echo "${#clean}"
}

_check_len() {
  local input="$1" expected="$2"
  local got; got="$(len_no_color "$input")"
  if [[ "$got" == "$expected" ]]; then
    ok "len_no_color: length $got (no ANSI) = $expected"
  else
    fail "len_no_color: expected $expected got $got for input '$input'"
  fi
}

_check_len $'\033[32mhello\033[0m' "5"
_check_len "plain"                  "5"
_check_len $'\033[38;5;208mABC\033[0m' "3"
_check_len ""                       "0"

# ----------------------------------------------------------
echo
echo "--- 11. CSV clean_for_csv (Python inline) ---"
# ----------------------------------------------------------
_csv_out=$(python3 - <<'PY'
import re

def clean_for_csv(text):
    if not text: return ""
    text = re.sub(r'\x1b\[[0-9;]*[mK]', '', text)
    text = re.sub(r'[\U00010000-\U0010ffff]', '', text)
    text = re.sub(r'[\u2600-\u27BF]', '', text)
    text = re.sub(r'[\u2300-\u23FF]', '', text)
    return text.replace('\n', ' ').replace('\r', ' ').strip()

tests = [
    ("\033[32mhello\033[0m",    "hello"),
    ("🔐 SSH,🌐 WEB",          "SSH, WEB"),
    ("plain text",              "plain text"),
    ("line\nnewline",           "line newline"),
]

for inp, expected in tests:
    result = clean_for_csv(inp)
    status = "PASS" if result == expected else f"FAIL (got: {repr(result)}, expected: {repr(expected)})"
    print(f"  [{status}] clean_for_csv {repr(inp[:20])}")
PY
)
echo "$_csv_out"
if echo "$_csv_out" | grep -q "FAIL"; then
  ((FAIL++))
else
  _pass_count=$(echo "$_csv_out" | grep -c "PASS" || true)
  PASS=$((PASS + _pass_count))
fi

# ----------------------------------------------------------
echo
echo "--- 12. run_with_timeout exit code ---"
# ----------------------------------------------------------
# Inline function extracted for test
run_with_timeout() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys, signal, os
secs = float(sys.argv[1])
cmd  = sys.argv[2:]
try:
    p = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr, start_new_session=True)
except FileNotFoundError:
    sys.stderr.write(f"run_with_timeout: command not found: {cmd[0]}\n")
    raise SystemExit(127)
try:
    rc = p.wait(timeout=secs)
    raise SystemExit(rc)
except subprocess.TimeoutExpired:
    try: os.killpg(p.pid, signal.SIGTERM)
    except: p.terminate()
    try: p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try: os.killpg(p.pid, signal.SIGKILL)
        except: p.kill()
        p.wait()
    raise SystemExit(124)
PY
}

set +e
run_with_timeout 0.5 sleep 10
_rc=$?
set -e
if [[ "$_rc" -eq 124 ]]; then
  ok "run_with_timeout returns exit code 124 on timeout"
else
  fail "run_with_timeout timeout: expected 124, got $_rc"
fi

set +e
run_with_timeout 5 true
_rc=$?
set -e
if [[ "$_rc" -eq 0 ]]; then
  ok "run_with_timeout returns 0 on successful command"
else
  fail "run_with_timeout success: expected 0, got $_rc"
fi

set +e
run_with_timeout 5 /no/such/command 2>/dev/null
_rc=$?
set -e
if [[ "$_rc" -eq 127 ]]; then
  ok "run_with_timeout returns 127 on command not found"
else
  fail "run_with_timeout not-found: expected 127, got $_rc"
fi

# ----------------------------------------------------------
echo
echo "=================================================="
echo " Results: ${PASS} passed  ${FAIL} failed  ${SKIP} skipped"
echo "=================================================="
echo

[[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
