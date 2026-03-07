#!/usr/bin/env bash
#===HELP_START===
# ==============================================================
#  host-avcisi
#  Multi-Engine Network Discovery & Infrastructure Analysis
#  -github@goktugorgn
#
#  Engines:
#    - naabu   : fastest (SYN scan, highly recommended)
#    - rustscan: extremely fast (port discovery focus)
#    - nmap    : reliable fallback & host discovery
#
#  Ultimate Features:
#    - Pro Dashboard : Visual summary of assets (IoT, Ent, Virt, etc.)
#    - Smart Labels  : 🛠️ iLO, 🍎 Apple, 🏗️ Enterprise, 🗃️ Storage, 📹 CCTV
#    - Intel (httpx) : HTTP titles, technologies, and SSL/TLS CN details
#    - Privacy Info  : Automatic Randomized MAC (LAA) detection
#    - Stealth       : ARP-based discovery + Randomized/Decoy ping probes
#
#  Usage:
#    sudo ./host_avcisi.sh 192.168.1.0/24 --warm-arp
#    ./host_avcisi.sh --stealth --warm-arp 10.0.0.0/24
#    ./host_avcisi.sh --deep 192.168.1.10 --save
#
#  Options:
#    --engine <type>            auto|naabu|rustscan|nmap
#    --warm-arp                 Wake up ARP cache for better MAC/Vendor intel
#    --stealth                  Silent mode (Randomized delay, Decoys, Fragmented)
#    --ports <list>             Default: Top 38 Enterprise/SaaS/IoT ports
#    --rate <num>               Scan rate for naabu/rustscan (default 3000)
#    --no-intel                 Skip httpx title/tech discovery
#    --save                     Export Excel-friendly CSV to Desktop
#    --deep <ip>                Intense nmap version scan + script discovery
#    --update-oui               Update local MAC Vendor OUI database
#
#  Advanced Tuning:
#    --httpx-timeout <sec>      httpx timeout (default 3)
#    --httpx-threads <num>      httpx threads (default 50)
#    --naabu-timeout <ms>       naabu probe timeout (default 300)
#    --naabu-retries <num>      naabu retries (default 1)
#    --naabu-hard-timeout <sec> Forced timeout for naabu engine
#    --no-progress              Disable scan progress bars
#
# ==============================================================
#===HELP_END===

set -eo pipefail
SC_START=$(date +%s)

# ---------------- Global Cleanup Trap ----------------
TMP_FILES=()
cleanup() {
  local exit_code=$?
  trap - EXIT
  # Use ${VAR+SET} trick to avoid unbound variable error if array is empty with set -u
  for f in ${TMP_FILES[@]+"${TMP_FILES[@]}"}; do
    [[ -f "$f" ]] && rm -f "$f" || true
  done
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Helper to register temp files for cleanup
track_tmp() { TMP_FILES+=("$1"); echo "$1"; }

# ---------------- Colors ----------------
if [[ -t 1 ]]; then
  RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; BLU=$'\033[34m'; MAG=$'\033[35m'; CYN=$'\033[36m'; ORG=$'\033[38;5;208m'; DIM=$'\033[2m'; RST=$'\033[0m'
else
  RED=""; GRN=""; YLW=""; BLU=""; MAG=""; CYN=""; ORG=""; DIM=""; RST=""
fi

have(){ command -v "$1" >/dev/null 2>&1; }

print_help(){
  awk '
    /^#===HELP_START===/ {show=1; next}
    /^#===HELP_END===/   {show=0; exit}
    show==1 { sub(/^# ?/, "", $0); print }
  ' "$0"
}

# ---------------- Optional vendor file ----------------
# Moving this up so update_oui_database can use VENDOR_FILE correctly
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR_FILE=""
if [[ -f "./mac-vendor.txt" ]]; then
  VENDOR_FILE="./mac-vendor.txt"
elif [[ -f "${SCRIPT_DIR}/mac-vendor.txt" ]]; then
  VENDOR_FILE="${SCRIPT_DIR}/mac-vendor.txt"
fi

update_oui_database() {
  local url="https://standards-oui.ieee.org/oui/oui.txt"
  # Use VENDOR_FILE if found, otherwise default to local directory
  local target="${VENDOR_FILE:-./mac-vendor.txt}"
  
  echo "${BLU}[*] Updating OUI database...${RST}"
  echo "${DIM}  Source: $url${RST}"
  echo "${DIM}  Target: $target${RST}"
  
  if ! have curl; then echo "❌ curl not found."; return 1; fi

  local tmp; tmp="$(track_tmp "$(mktemp -t oui_download.XXXXXX)")"
  if curl -L -s -k "$url" -o "$tmp"; then
    # Parse IEEE format to our compact format: XX:XX:XX<TAB>Vendor Name
    # Robust regex for IEEE oui.txt format: catch XX-XX-XX and convert to XX:XX:XX
    grep "(hex)" "$tmp" | \
      sed -E 's/^([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})-([0-9A-Fa-f]{2})[[:space:]]+\(hex\)[[:space:]]+(.*)/\1:\2:\3\t\4/' | \
      sed 's/\r//g' > "$target"
    
    if [[ -s "$target" ]]; then
       echo "${GRN}[+] OUI database updated successfully ($target).${RST}"
    else
       echo "${RED}❌ Parsing failed. File is empty.${RST}"
       return 1
    fi
  else
    echo "${RED}❌ Download failed.${RST}"
    return 1
  fi
}

check_deps() {
  local missing=()
  for cmd in nmap naabu rustscan httpx; do
    if ! have "$cmd"; then missing+=("$cmd"); fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    # Only show if not updating OUI which is a specialized task
    echo "${YLW}[!] Warning: Missing recommended tools:${RST} ${RED}${missing[*]}${RST}"
    echo "${DIM}  You can install them via Homebrew: brew install nmap naabu rustscan httpx/tap/httpx${RST}"
    echo
    if ! have nmap; then
      echo "${RED}❌ Critical: 'nmap' is required as the final fallback engine.${RST}"
      exit 1
    fi
  fi
}

# ---------------- Check Dependencies ----------------
# Only check if not just asking for help or OUI update
if [[ ! " $* " == *" --help "* && ! " $* " == *" -h "* && ! " $* " == *" --update-oui "* ]]; then
  check_deps
  # Vendor file check
  if [[ -z "$VENDOR_FILE" || ! -f "$VENDOR_FILE" ]]; then
    echo "${YLW}[!] Warning: MAC Vendor database (mac-vendor.txt) is missing.${RST}"
    echo "${DIM}    Vendor names will not be shown in the results.${RST}"
    echo -n "${CYN}    Would you like to download it now? (y/n): ${RST}"
    read -r -n 1 opt
    echo
    if [[ "$opt" == "y" || "$opt" == "Y" ]]; then
      update_oui_database
      # Update VENDOR_FILE variable after download
      VENDOR_FILE="./mac-vendor.txt"
    else
      echo "${DIM}    Skipping... Use --update-oui later to fix this.${RST}"
    fi
    echo
  fi
fi

# ---------------- Defaults ----------------
SUBNET=""
ENGINE="auto"          # auto|naabu|rustscan|nmap
WARM_ARP=0
NO_INTEL=0
STEALTH=0
SAVE_CSV=0

PORTS="22,80,111,139,443,445,623,902,903,1433,1521,2049,2375,2376,3000,3306,3389,5000,5001,5432,5480,5601,5985,5986,6161,6379,8006,8080,8081,8443,9090,9100,9200,9443,10000,11211,17988,17990"
HTTPX_PORTS="80,443,3000,5000,5001,5480,5986,8006,8080,8081,8443,9443,10000,17988,17990"

RATE="3000"
HTTPX_TIMEOUT="3"
HTTPX_THREADS="50"
NAABU_TIMEOUT="300"    # ms (per-probe timeout) - decreased for speed
NAABU_HARD_TIMEOUT=""  # auto-calculated if empty
RUSTSCAN_HARD_TIMEOUT="60" # seconds
RUSTSCAN_ULIMIT="2000" # macOS: 5000 can crash/abort; tune if needed
NAABU_RETRIES="1"       # keep low to avoid long stalls
NAABU_PROGRESS=1         # show naabu stats/progress (disable with --no-progress)

DEEP_IP=""

# ---------------- Arg parsing (order-independent) ----------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) print_help; exit 0 ;;
    --engine) ENGINE="${2:-auto}"; shift 2 ;;
    --warm-arp) WARM_ARP=1; shift ;;
    --ports) PORTS="${2:-}"; shift 2 ;;
    --rate) RATE="${2:-3000}"; shift 2 ;;
    --httpx-timeout) HTTPX_TIMEOUT="${2:-3}"; shift 2 ;;
    --httpx-threads) HTTPX_THREADS="${2:-50}"; shift 2 ;;
    --naabu-timeout) NAABU_TIMEOUT="${2:-1000}"; shift 2 ;;
    --naabu-hard-timeout) NAABU_HARD_TIMEOUT="${2:-}"; shift 2 ;;
    --naabu-retries) NAABU_RETRIES="${2:-1}"; shift 2 ;;
    --no-progress) NAABU_PROGRESS=0; shift ;;
    --no-intel) NO_INTEL=1; shift ;;
    --stealth) STEALTH=1; shift ;;
    --save) SAVE_CSV=1; shift ;;
    --deep) DEEP_IP="${2:-}"; shift 2 ;;
    --update-oui) update_oui_database; exit 0 ;;
    --) shift; break ;;
    -*) echo "Unknown option: $1"; echo; print_help; exit 1 ;;
    *)
      if [[ -z "$SUBNET" ]]; then SUBNET="$1"; shift
      else echo "Unknown arg: $1"; exit 1
      fi
      ;;
  esac
done

is_ip(){ [[ "${1:-}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; }

if [[ -n "$DEEP_IP" ]]; then
  if ! is_ip "$DEEP_IP"; then
    echo "❌ --deep expects an IP (e.g. --deep 10.252.10.122)"; exit 1
  fi
fi

if [[ -z "$SUBNET" && -z "$DEEP_IP" ]]; then
  echo "❌ Subnet required. Example: ./host_avcisi.sh 10.252.10.0/24"; exit 1
fi


# ---------------- Timeout helper (pipe-friendly) ----------------
# Streams stdout in real-time so pipe chains work correctly.
# Uses start_new_session=True so the child gets its own process group,
# preventing os.killpg from killing the parent script.
# Usage: run_with_timeout <seconds> <cmd...>
# Exit code 124 = timeout reached.
run_with_timeout() {
  local secs="$1"; shift
  python3 - "$secs" "$@" <<'PY'
import subprocess, sys, signal, os

secs = float(sys.argv[1])
cmd  = sys.argv[2:]

try:
    p = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr,
                         start_new_session=True)
except FileNotFoundError:
    sys.stderr.write(f"run_with_timeout: command not found: {cmd[0]}\n")
    raise SystemExit(127)

try:
    rc = p.wait(timeout=secs)
    raise SystemExit(rc)
except subprocess.TimeoutExpired:
    # Child is in its own session/pgid — safe to killpg without hitting parent
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        p.terminate()
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(p.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, OSError):
            p.kill()
        p.wait()
    raise SystemExit(124)
PY
}

# Timeout wrapper that captures stdout to a file (for tools whose output we parse).
# Uses start_new_session=True so the child gets its own process group.
# Usage: run_with_timeout_capture <seconds> <outfile> <cmd...>
# Exit code 124 = timeout reached; partial output is still written to outfile.
run_with_timeout_capture() {
  local secs="$1" outfile="$2"; shift 2
  python3 - "$secs" "$outfile" "$@" <<'PY'
import subprocess, sys, signal, os

secs    = float(sys.argv[1])
outfile = sys.argv[2]
cmd     = sys.argv[3:]

try:
    with open(outfile, 'w') as fout:
        p = subprocess.Popen(cmd, stdout=fout, stderr=sys.stderr,
                             start_new_session=True)
        try:
            rc = p.wait(timeout=secs)
            raise SystemExit(rc)
        except subprocess.TimeoutExpired:
            # Child is in its own session — safe to killpg
            try:
                os.killpg(p.pid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                p.terminate()
            try:
                p.wait(timeout=5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(p.pid, signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    p.kill()
                p.wait()
            raise SystemExit(124)
except FileNotFoundError:
    sys.stderr.write(f"run_with_timeout: command not found: {cmd[0]}\n")
    raise SystemExit(127)
PY
}


normalize_oui() {
  # Clean OUI: converts any MAC to XX:XX:XX format (8 chars)
  local clean; clean=$(echo "$1" | sed 's/[-.]/:/g' | tr '[:lower:]' '[:upper:]')
  # Extract parts 1, 2, 3 and ensure they are 2-digits
  echo "$clean" | awk -F: '{printf("%02s:%02s:%02s\n", $1, $2, $3)}' | sed 's/ /0/g'
}

# ---------------- Deep confirm ----------------
deep_fingerprint() {
  local ip="$1"
  if ! have nmap; then
    echo "❌ nmap not found. Install: brew install nmap"; exit 1
  fi
  echo "${CYN}▶ deep scan${RST} ${YLW}${ip}${RST}"
  echo "${DIM}  nmap -sV + light scripts (http-title, ssl-cert, banner)${RST}"
  echo
  sudo nmap -sS -sV -Pn -p 22,80,443,623,17988,17990,902,903,5480,9443 \
    --script http-title,ssl-cert,banner \
    "$ip"
}

if [[ -n "$DEEP_IP" ]]; then
  deep_fingerprint "$DEEP_IP"
  exit 0
fi

# ---------------- Engine selection ----------------
if [[ "$ENGINE" == "auto" ]]; then
  if have naabu; then ENGINE="naabu"
  elif have rustscan; then ENGINE="rustscan"
  else ENGINE="nmap"
  fi
fi

# ---------------- Count hosts in subnet for dynamic timeout ----------------
count_subnet_hosts() {
  local subnet="$1"
  if [[ "$subnet" == *"/"* ]]; then
    local cidr="${subnet##*/}"
    if [[ "$cidr" =~ ^[0-9]+$ ]] && [[ "$cidr" -ge 0 && "$cidr" -le 32 ]]; then
      local hosts=$(( (1 << (32 - cidr)) ))
      # subtract network + broadcast for /30 and larger
      [[ "$hosts" -gt 2 ]] && hosts=$((hosts - 2))
      echo "$hosts"
      return
    fi
  fi
  # single host or unparseable
  echo "1"
}

# Auto-calculate naabu hard timeout if not set
if [[ -z "$NAABU_HARD_TIMEOUT" ]]; then
  _host_count="$(count_subnet_hosts "$SUBNET")"
  _port_count="$(echo "$PORTS" | tr ',' '\n' | wc -l | tr -d ' ')"
  # Formula: (hosts × ports) / rate × 5 safety margin, minimum 90s, max 450s
  _probes=$((_host_count * _port_count))
  _calc_timeout=$(( (_probes / ${RATE:-3000}) * 5 + 60 ))
  [[ "$_calc_timeout" -lt 90 ]] && _calc_timeout=90
  [[ "$_calc_timeout" -gt 450 ]] && _calc_timeout=450
  NAABU_HARD_TIMEOUT="$_calc_timeout"
  unset _host_count _port_count _probes _calc_timeout
fi

# ---------------- Stealth Adjustments ----------------
if [[ "$STEALTH" -eq 1 ]]; then
  RATE="150"
  HTTPX_THREADS="2"
  HTTPX_TIMEOUT="5"
fi

# ---------------- Announce ----------------
BANNER_ART=$(cat <<'EOF'
░█░█░█▀█░█▀▀░▀█▀░░░░░█▀█░█░█░█▀▀░▀█▀░█▀▀░▀█▀
░█▀█░█░█░▀▀█░░█░░▄▄▄░█▀█░▀▄▀░█░░░░█░░▀▀█░░█░
░▀░▀░▀▀▀░▀▀▀░░▀░░░░░░▀░▀░░▀░░▀▀▀░▀▀▀░▀▀▀░▀▀▀
EOF
)
echo "${ORG}${BANNER_ART}${RST}"
echo " "
echo "${RED}github@goktugorgn${RST}"
if [[ "$STEALTH" -eq 1 ]]; then
  echo "${ORG}▶ host-avcisi${RST}  subnet=${YLW}${SUBNET}${RST}  ${RED}[STEALTH MODE]${RST}"
else
  echo "${ORG}▶ host-avcisi${RST}  subnet=${YLW}${SUBNET}${RST}"
fi
echo "  ${ORG}engine=${RST}${YLW}${ENGINE}${RST}  ${ORG}ports=${RST}${YLW}${PORTS}${RST}"

if [[ "$ENGINE" == "naabu" ]]; then
  echo "  ${ORG}naabu:${RST} rate=${YLW}${RATE}${RST} timeout=${YLW}${NAABU_TIMEOUT}ms${RST} retries=${YLW}${NAABU_RETRIES}${RST} hard_timeout=${YLW}${NAABU_HARD_TIMEOUT}s${RST}"
fi

if [[ -n "$VENDOR_FILE" ]]; then
  echo "  ${ORG}mac-vendor=${RST}${YLW}${VENDOR_FILE}${RST}"
else
  echo "  ${ORG}mac-vendor=${RST}${DIM}not found (optional)${RST}"
fi

if [[ "$NO_INTEL" -eq 0 ]]; then
  if have httpx; then
    echo "  ${ORG}intel=${RST}${YLW}httpx${RST} (timeout=${YLW}${HTTPX_TIMEOUT}s${RST} threads=${YLW}${HTTPX_THREADS}${RST})"
  else
    echo "  ${ORG}intel=${RST}${RED}httpx not found → disabled${RST}"
    NO_INTEL=1
  fi
else
  echo "  ${ORG}intel=${RST}${DIM}off${RST}"
fi
echo

# ---------------- Host discovery (fast ping sweep via nmap if available) ----------------
HOSTS=()
if [[ "$STEALTH" -eq 1 ]]; then
  echo "${YLW}[!] Stealth mode: using ARP cache discovery...${RST}"
  
  if [[ "$WARM_ARP" -eq 1 ]]; then
    echo "${BLU}[*] Warming ARP cache for entire subnet (Stealthy/Randomized)...${RST}"
    if have nmap; then
      # Stealthy ping scan: fragmented, slow timing (T2), decoys
      nmap -sn -T2 -f -D RND:10 --max-retries 1 "$SUBNET" >/dev/null 2>&1
    else
      # Portable randomized ping sweep
      _prefix="${SUBNET%.*}."
      for i in $(seq 1 254 | sort -R); do
        ping -c 1 -W 1 "${_prefix}${i}" >/dev/null 2>&1 &
        [[ $((i % 20)) -eq 0 ]] && sleep 0.2
      done
      wait
    fi
  fi

  # Gather from ARP table (arp -an is faster/no DNS)
  while IFS= read -r line; do
    _ip=$(echo "$line" | grep -oE "\b([0-9]{1,3}\.){3}[0-9]{1,3}\b" | head -1)
    # Check if IP is in our subnet prefix
    if [[ -n "$_ip" && "$_ip" == "${SUBNET%.*}."* ]]; then
      HOSTS+=("$_ip")
    fi
  done < <(arp -an 2>/dev/null || arp -a 2>/dev/null)
  
  # Deduplicate to get final list
  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    HOSTS=($(printf "%s\n" "${HOSTS[@]}" | sort -u))
  fi
  echo "${GRN}[+] Discovered via ARP:${RST} ${#HOSTS[@]}"

elif have nmap; then
  echo "${BLU}[*] Discovering alive hosts...${RST}"
  # Remove -n to allow hostname resolution
  DISCOVERY_ARGS=(-sn)
  while IFS= read -r line; do
    if [[ "$line" == "Nmap scan report for "* ]]; then
      # Extract Hostname and IP
      name=$(echo "$line" | sed 's/Nmap scan report for //')
      if [[ "$name" == *"("* ]]; then
         ip=$(echo "$name" | awk -F'[()]' '{print $2}')
         hostname=$(echo "$name" | awk '{print $1}')
      else
         ip="$name"
         hostname=""
      fi
      if [[ -n "$ip" ]]; then
        HOSTS+=("$ip")
        if [[ -n "$hostname" && "$hostname" != "$ip" ]]; then
           echo "${ip}|${hostname}" >> "$(track_tmp "/tmp/sh_names.tsv")"
        fi
      fi
    fi
  done < <(nmap "${DISCOVERY_ARGS[@]}" "$SUBNET" 2>/dev/null)
  echo "${GRN}[+] Alive hosts:${RST} ${#HOSTS[@]}"
else
  echo "${YLW}[!] nmap not found → skipping ping discovery (MAC/Vendor may be limited).${RST}"
fi

if [[ "${#HOSTS[@]}" -gt 0 && "${#HOSTS[@]}" -le 40 ]]; then
  printf '  %s\n' "${HOSTS[@]}"
  echo
fi

# Optional: warm ARP cache
# macOS ping -W is in SECONDS (not ms like Linux), so use -W 1 (1 second)
if [[ "$WARM_ARP" -eq 1 && "${#HOSTS[@]}" -gt 0 ]]; then
  echo "${BLU}[*] Warming ARP cache (parallel)...${RST}"
  # Ping everyone in the background for high speed
  for ip in "${HOSTS[@]}"; do
    ping -c 1 -W 1 "$ip" >/dev/null 2>&1 &
  done
  wait # wait for background pings to finish
  echo
fi

# ---------------- Port discovery ----------------
echo "${BLU}[*] Probing ports (open only)...${RST}"

RESULTS=() # "IP|p1,p2,p3"
PORTMAP_JSON="$(track_tmp "$(mktemp -t sh_ports.XXXXXX)")"
: > "$PORTMAP_JSON"

# --- Rustscan helper function (used in fallback and direct mode) ---
run_rustscan_scan() {
  local outfile="$1"
  local rs_err
  rs_err="$(track_tmp "$(mktemp -t sh_rustscan.err.XXXXXX)")"

  if ! have rustscan; then
    echo "${YLW}[!] rustscan not found.${RST}"
    rm -f "$rs_err" >/dev/null 2>&1 || true
    return 1
  fi

  : > "$outfile"

  local rs_raw
  rs_raw="$(track_tmp "$(mktemp -t sh_rustscan_raw.XXXXXX)")"

  set +e
  run_with_timeout_capture "$RUSTSCAN_HARD_TIMEOUT" "$rs_raw" \
    rustscan -a "$SUBNET" -p "$PORTS" --ulimit "$RUSTSCAN_ULIMIT" 2>"$rs_err"
  local rs_rc=$?
  set -e

  if [[ "$rs_rc" -eq 124 ]]; then
    echo "${YLW}[!] rustscan hard-timeout (${RUSTSCAN_HARD_TIMEOUT}s).${RST}"
  fi

  # Parse rustscan output → JSON lines
  if [[ -s "$rs_raw" ]]; then
    python3 - "$rs_raw" > "$outfile" <<'PY'
import json, re, sys
path = sys.argv[1]
with open(path, 'r', encoding='utf-8', errors='ignore') as f:
    for line in f:
        m = re.search(r"Open\s+(\d+\.\d+\.\d+\.\d+):(\d+)", line)
        if m:
            ip, port = m.group(1), int(m.group(2))
            print(json.dumps({"ip": ip, "port": port}))
PY
  fi

  rm -f "$rs_raw" >/dev/null 2>&1 || true

  if [[ "$rs_rc" -ne 0 && ! -s "$outfile" ]]; then
    echo "${YLW}[!] rustscan failed (rc=$rs_rc).${RST}"
    if [[ -s "$rs_err" ]]; then
      echo "${DIM}  rustscan stderr (last 10 lines):${RST}"
      tail -n 10 "$rs_err" 2>/dev/null || true
    fi
    rm -f "$rs_err" >/dev/null 2>&1 || true
    return 1
  fi

  rm -f "$rs_err" >/dev/null 2>&1 || true
  return 0
}

if [[ "$ENGINE" == "naabu" ]]; then
  if ! have naabu; then echo "❌ naabu not found. brew install naabu"; exit 1; fi

  # Naabu Sudo/Root Check for performance
  if [[ "$EUID" -ne 0 ]]; then
    echo "${YLW}[!] Warning: naabu performs better with sudo for SYN scans.${RST}"
  fi

  # Port Shuffling if stealth is active
  _ports_input="$PORTS"
  if [[ "$STEALTH" -eq 1 ]]; then
    _ports_input="$(echo "$PORTS" | tr ',' '\n' | python3 -c "import sys, random; l=sys.stdin.readlines(); random.shuffle(l); sys.stdout.write(','.join(x.strip() for x in l))")"
  fi

  # Use discovered hosts list if nmap found any, otherwise fallback to subnet
  _target_input="$SUBNET"
  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    # Create temp file for naabu -list input
    _tmp_list="$(track_tmp "$(mktemp -t sh_naabu_list.XXXXXX)")"
    
    # Stealth: Shuffle the hosts before scanning
    if [[ "$STEALTH" -eq 1 ]]; then
      printf "%s\n" "${HOSTS[@]}" | python3 -c "import sys, random; l=sys.stdin.readlines(); random.shuffle(l); sys.stdout.write(''.join(l))" > "$_tmp_list"
    else
      printf "%s\n" "${HOSTS[@]}" > "$_tmp_list"
    fi
    
    _target_input="$_tmp_list"
    NAABU_ARGS=( -list "$_target_input" -p "$_ports_input" -rate "$RATE" -timeout "$NAABU_TIMEOUT" -retries "$NAABU_RETRIES" -json -silent )
  else
    NAABU_ARGS=( -host "$SUBNET" -p "$_ports_input" -rate "$RATE" -timeout "$NAABU_TIMEOUT" -retries "$NAABU_RETRIES" -json -silent )
  fi

  NAABU_RC=0
  set +e
  run_with_timeout_capture "$NAABU_HARD_TIMEOUT" "$PORTMAP_JSON" naabu "${NAABU_ARGS[@]}" 2>/tmp/sh_naabu.err
  NAABU_RC=$?
  set -e

  [[ -f "${_tmp_list:-}" ]] && rm -f "$_tmp_list"

  if [[ "$NAABU_RC" -eq 124 ]]; then
    echo "${YLW}[!] naabu hard-timeout (${NAABU_HARD_TIMEOUT}s). Falling back...${RST}"
    ENGINE="rustscan"
  elif [[ "$NAABU_RC" -ne 0 ]]; then
    if [[ ! -s "$PORTMAP_JSON" ]]; then
      echo "${YLW}[!] naabu failed (rc=$NAABU_RC). Falling back...${RST}"
      ENGINE="rustscan"
    fi
  fi

  if [[ "$NAABU_RC" -ne 0 ]]; then
    if [[ -s /tmp/sh_naabu.err ]]; then
      echo "${DIM}  naabu stderr (last 10 lines):${RST}"
      tail -n 10 /tmp/sh_naabu.err 2>/dev/null || true
    fi
  fi
  rm -f /tmp/sh_naabu.err >/dev/null 2>&1 || true

  # Fallback: naabu → rustscan → nmap
  if [[ "$ENGINE" == "rustscan" ]]; then
    # Clean partial naabu output before rustscan writes
    : > "$PORTMAP_JSON"

    if ! run_rustscan_scan "$PORTMAP_JSON"; then
      echo "${YLW}[!] Falling back to nmap...${RST}"
      ENGINE="nmap"
    fi
  fi

elif [[ "$ENGINE" == "rustscan" ]]; then
  if ! run_rustscan_scan "$PORTMAP_JSON"; then
    echo "${YLW}[!] Falling back to nmap...${RST}"
    ENGINE="nmap"
  fi
fi

# nmap fallback (also used if others fail)
if [[ "$ENGINE" == "nmap" ]]; then
  if ! have nmap; then echo "❌ nmap not found. brew install nmap"; exit 1; fi
  HOST_LIST=""
  if [[ "${#HOSTS[@]}" -gt 0 ]]; then
    HOST_LIST="$(printf "%s " "${HOSTS[@]}")"
  else
    HOST_LIST="$SUBNET"
  fi
  _nmap_args=(-n --open -p "$PORTS")
  if [[ "$STEALTH" -eq 1 ]]; then
    # Stealth: fragmentation (-f), decoys (-D RND:10), scan delay (--scan-delay 1s), T2 (polite)
    _nmap_args+=(-f -T2 -D RND:10 --scan-delay 1s)
  else
    _nmap_args+=(-T4 --min-rate 500 -sT)
  fi
  RAW="$(nmap "${_nmap_args[@]}" $HOST_LIST 2>/dev/null || true)"
  printf "%s\n" "$RAW" | python3 - <<'PY' > "$PORTMAP_JSON"
import json, re, sys
cur=None
for line in sys.stdin:
    m=re.match(r'^Nmap scan report for (\d+\.\d+\.\d+\.\d+)', line)
    if m:
        cur=m.group(1); continue
    m=re.match(r'^(\d+)/tcp\s+open', line)
    if m and cur:
        print(json.dumps({"ip":cur,"port":int(m.group(1))}))
PY
fi
# Group results by IP
python3 - <<'PY' "$PORTMAP_JSON" "${HOSTS[@]}" > /tmp/sh_grouped.tsv
import json, sys
from collections import defaultdict
path=sys.argv[1]
all_hosts=sys.argv[2:]
d=defaultdict(set)
# Initialize all discovered hosts with empty port set
for h in all_hosts: d[h] = set()
# Parse port results
try:
    with open(path,'r',encoding='utf-8',errors='ignore') as f:
        for line in f:
            line=line.strip()
            if not line: continue
            try:
                obj=json.loads(line)
                ip=obj.get("ip"); port=obj.get("port")
                if ip and port: d[ip].add(int(port))
            except Exception: pass
except Exception: pass
# Sort by IP and print
for ip in sorted(d.keys(), key=lambda s: tuple(int(x) for x in s.split('.'))):
    ports=",".join(str(p) for p in sorted(d[ip]))
    print(f"{ip}\t{ports if ports else '-'}")
PY

while IFS=$'\t' read -r ip ports; do
  RESULTS+=("${ip}|${ports}")
done < /tmp/sh_grouped.tsv
rm -f /tmp/sh_grouped.tsv "$PORTMAP_JSON" || true

FINAL_HOSTS=()
for row in "${RESULTS[@]}"; do FINAL_HOSTS+=("${row%%|*}"); done

echo "${GRN}[+] Targets with open ports:${RST} ${#FINAL_HOSTS[@]}"
echo

# ---------------- ARP / Vendor ----------------
ARP_CACHE="$(arp -a 2>/dev/null || true)"
mac_for_ip() {
  local ip="$1"
  echo "$ARP_CACHE" | awk -v ip="($ip)" '
    $0 ~ ip {
      for (i=1; i<=NF; i++) if ($i=="at") { print $(i+1); exit }
    }'
}

TMP_VENDOR_CACHE=""
build_vendor_cache_for_ouis() {
  [[ -z "$VENDOR_FILE" ]] && return 0
  local tmp ouilist
  tmp="$(track_tmp "$(mktemp -t vendor_cache.XXXXXX)")"; TMP_VENDOR_CACHE="$tmp"
  ouilist="$(track_tmp "$(mktemp -t oui_list.XXXXXX)")"
  local seen=""
  for ip in "${FINAL_HOSTS[@]}"; do
    local mac oui
    mac="$(mac_for_ip "$ip" || true)"; [[ -z "$mac" ]] && continue
    oui="$(normalize_oui "$mac")"
    [[ ${#oui} -ne 8 ]] && continue
    case " $seen " in *" $oui "*) : ;; *) echo "$oui" >> "$ouilist"; seen+=" $oui" ;; esac
  done
  [[ ! -s "$ouilist" ]] && { rm -f "$ouilist"; return 0; }
  awk 'NR==FNR{want[$1]=1; next} (want[$1]){print $0}' "$ouilist" "$VENDOR_FILE" > "$tmp" || true
  rm -f "$ouilist" || true
}

vendor_for_mac() {
  local mac="$1"
  [[ -z "$mac" || "$mac" == "-" ]] && { echo "-"; return; }
  
  local oui; oui="$(normalize_oui "$mac")"
  local src; src="${VENDOR_FILE:-./mac-vendor.txt}"
  
  [[ ! -f "$src" ]] && { echo "($oui)"; return; }
  [[ -n "${TMP_VENDOR_CACHE:-}" && -f "$TMP_VENDOR_CACHE" ]] && src="$TMP_VENDOR_CACHE"
  
  # Try matching XX:XX:XX OR XX-XX-XX
  local line; line=""
  line=$(grep -m1 -i "^${oui}" "$src" 2>/dev/null || true)
  if [[ -z "$line" ]]; then
    local oui_dash; oui_dash=${oui//:/-}
    line=$(grep -m1 -i "^${oui_dash}" "$src" 2>/dev/null || true)
  fi
  
  if [[ -n "$line" ]]; then
    # Strip OUI and show vendor (handles TAB or space delimiters)
    echo "$line" | sed -E 's/^[0-9A-Fa-f:,-]{6,12}[[:space:]]+//' | xargs
  else
    # Check for Randomized MAC (Locally Administered)
    # Second hex digit of the first byte must be 2, 6, A, or E
    if [[ "${oui:1:1}" =~ [26AEae] ]]; then
       echo "${YLW}Randomized MAC${RST}"
    else
       echo "($oui)"
    fi
  fi
}
build_vendor_cache_for_ouis

# ---------------- Labels & Confidence ----------------
label_ports() {
  local p="$1" out=""
  has(){ [[ ",$p," == *",$1,"* ]]; }
  # --- Enterprise & Management ---
  if has "17988" || has "17990"; then out+="🛠️ iLO,"; fi
  if has "623"; then out+="🔧 IPMI,"; fi
  if (has "902" || has "903") && has "443"; then out+="☁️ ESXi,"; fi
  if has "5480" && has "443"; then out+="⚙️ vCenter,"; fi
  if has "8006"; then out+="💎 Proxmox,"; fi
  if has "3389"; then out+="🖥️ RDP,"; fi
  if has "5985" || has "5986"; then out+="📜 WinRM,"; fi
  # --- Infrastructure ---
  if has "22"; then out+="🔐 SSH,"; fi
  if has "23"; then out+="📟 Telnet,"; fi
  if has "161"; then out+="📡 SNMP,"; fi
  # --- Databases ---
  if has "1433" || has "1521" || has "3306" || has "5432" || has "6379" || has "27017"; then out+="🗄️ DB,"; fi
  # --- DevOps & Web ---
  if has "2375" || has "2376"; then out+="🐳 Docker,"; fi
  if has "3000"; then out+="📊 Grafana,"; fi
  if has "9100" || has "9090"; then out+="📈 Prom,"; fi
  if has "80" || has "443" || has "8080" || has "8081" || has "8443"; then out+="🌐 WEB,"; fi
  # --- Storage & Backup ---
  if has "445" || has "139"; then out+="📁 SMB,"; fi
  if has "6161"; then out+="🎒 Veeam,"; fi
  if has "5000" || has "5001"; then out+="📦 NAS,"; fi
  # --- IoT & Misc ---
  if has "8123"; then out+="🏠 HomeAsst,"; fi
  
  out="${out%,}"; [[ -z "$out" ]] && out="-"; echo "$out"
}

label_vendor_context() {
  local v; v="$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')"
  local out=""
  [[ "$v" == *"dell"* || "$v" == *"hewlett"* || "$v" == *"hp "* || "$v" == *"lenovo"* || "$v" == *"supermicro"* ]] && out+="🏗️ Enterprise,"
  [[ "$v" == *"cisco"* || "$v" == *"juniper"* || "$v" == *"mikrotik"* || "$v" == *"aruba"* || "$v" == *"ubiquiti"* ]] && out+="🔌 Network,"
  [[ "$v" == *"vmware"* ]] && out+="🧊 Virt,"
  [[ "$v" == *"synology"* || "$v" == *"qnap"* ]] && out+="🗃️ Storage,"
  [[ "$v" == *"apple"* ]] && out+="🍎 Apple,"
  [[ "$v" == *"espressif"* || "$v" == *"shelly"* || "$v" == *"tasmota"* ]] && out+="🏠 IoT,"
  [[ "$v" == *"hikvision"* || "$v" == *"dahua"* ]] && out+="📹 CCTV,"
  echo "${out%,}"
}

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

  if [[ "$tlow" == *"vmware"* || "$tlow" == *"vcenter"* || "$tlow" == *"ilo"* || "$tlow" == *"idrac"* || "$tlow" == *"cimc"* || "$tlow" == *"xcc"* || "$tlow" == *"supermicro"* || "$tlow" == *"synology"* || "$tlow" == *"proxmox"* || "$tlow" == *"qnap"* ]]; then bump 25; fi
  if [[ "$vlow" == *"cisco"* || "$vlow" == *"juniper"* || "$vlow" == *"aruba"* || "$vlow" == *"h3c"* || "$vlow" == *"hewlett"* || "$vlow" == *"dell"* || "$vlow" == *"vmware"* ]]; then bump 10; fi

  [[ $score -gt 100 ]] && score=100
  echo "$score"
}

# ---------------- Intel via httpx ----------------
INTEL_TSV=""
if [[ "$NO_INTEL" -eq 0 ]]; then
  INTEL_TSV="$(track_tmp "$(mktemp -t sh_httpx.XXXXXX)")"

  URLS_FILE="$(track_tmp "$(mktemp -t sh_urls.XXXXXX)")"
  : > "$URLS_FILE"

  port_in_httpx_set() {
    local p=",$HTTPX_PORTS,"
    [[ "$p" == *",$1,"* ]]
  }

  for row in "${RESULTS[@]}"; do
    ip="${row%%|*}"
    ports="${row#*|}"
    IFS=',' read -r -a plist <<< "$ports"
    for prt in "${plist[@]}"; do
      port_in_httpx_set "$prt" || continue
      case "$prt" in
        443|8443|9443|5480|17988|17990|5001) echo "https://${ip}:${prt}" >> "$URLS_FILE" ;;
        *) echo "http://${ip}:${prt}" >> "$URLS_FILE" ;;
      esac
    done
  done

  if [[ -s "$URLS_FILE" ]]; then
    echo "${BLU}[*] Intel scan (httpx) on $(wc -l < "$URLS_FILE" | tr -d ' ') url(s)...${RST}"

    HTTPX_JSON="$(track_tmp "$(mktemp -t sh_httpxjson.XXXXXX)")"
    
    # Build httpx arguments
    HTTPX_ARGS=( -silent -json -title -status-code -tech-detect -tls-grab 
                 -threads "$HTTPX_THREADS" -timeout "$HTTPX_TIMEOUT" )
    
    if [[ "$STEALTH" -eq 1 ]]; then
      # Ultimate HTTP stealth mask
      HTTPX_ARGS+=( -random-agent -rl 5 -header "Referer: https://www.google.com" 
                    -header "Accept: text/html,application/xhtml+xml,xml;q=0.9,image/avif,webp,*/*;q=0.8"
                    -header "Accept-Language: en-US,en;q=0.5"
                    -header "Cache-Control: no-cache"
                    -header "Connection: keep-alive" )
      # Random jitter before starting intel scan
      sleep $((RANDOM % 10 + 2))
    fi

    httpx "${HTTPX_ARGS[@]}" -l "$URLS_FILE" > "$HTTPX_JSON" 2>/dev/null || true

    python3 - <<'PY' "$HTTPX_JSON" > "$INTEL_TSV"
import json, re, sys
path=sys.argv[1]

def pick(o, *keys):
    for k in keys:
        if k in o and o[k] is not None and o[k] != "":
            return o[k]
    return ""

def to_text(v):
    # Convert any JSON value into a safe, single-line string
    if v is None:
        return ""
    if isinstance(v, (dict, list)):
        try:
            return json.dumps(v, ensure_ascii=False)
        except Exception:
            return str(v)
    return str(v)

def clean(v):
    s = to_text(v)
    return s.replace("\t"," ").replace("\r"," ").replace("\n"," ").strip()

def extract_cn(v):
    # httpx may return tls as dict; try to extract a meaningful CN-like value
    if v is None:
        return ""
    if isinstance(v, dict):
        # common direct keys
        for k in ("subject_cn","subjectCN","cn","common_name","subject_common_name"):
            if k in v and v[k]:
                return clean(v[k])
        # subject_dn like: 'CN=...,O=...'
        subj = v.get("subject_dn") or v.get("subjectDN") or v.get("subject") or ""
        subj_s = to_text(subj)
        m = re.search(r"CN=([^,\/]+)", subj_s)
        if m:
            return clean(m.group(1))
        # fallback: best-effort compact string
        return clean(subj_s) or clean(v)
    # already scalar
    s = to_text(v)
    m = re.search(r"CN=([^,\/]+)", s)
    return clean(m.group(1) if m else s)

with open(path,'r',encoding='utf-8',errors='ignore') as f:
    for line in f:
        line=line.strip()
        if not line:
            continue
        try:
            o=json.loads(line)
        except Exception:
            continue

        url = pick(o,"url","input") or ""
        ip  = pick(o,"ip") or ""
        if not ip:
            m=re.match(r'^\w+://([^/:]+)', url)
            ip=m.group(1) if m else ""

        title = pick(o,"title")
        tech  = pick(o,"tech","technologies","techs")

        # tls may be dict or string depending on httpx version/flags
        tls_raw = pick(o,"tls","tls_grab","tls-grab","tls_subject_cn","subject_cn","cn","tls_subject","subject_dn")

        if isinstance(tech, list):
            tech=",".join(str(x) for x in tech if x is not None)
        elif isinstance(tech, dict):
            # keep it readable
            tech=to_text(tech)

        print(f"{clean(ip)}\t{clean(title)}\t{extract_cn(tls_raw)}\t{clean(tech)}")

PY

    rm -f "$HTTPX_JSON" || true
    echo
  fi

  rm -f "$URLS_FILE" || true
fi

intel_for_ip() {
  local ip="$1" col="$2"
  [[ -z "${INTEL_TSV:-}" || ! -f "$INTEL_TSV" ]] && { echo "-"; return; }
  awk -F'\t' -v ip="$ip" -v c="$col" '$1==ip{print $c; exit}' "$INTEL_TSV"
}
intel_title(){ intel_for_ip "$1" 2; }
intel_tls(){ intel_for_ip "$1" 3; }
intel_tech(){ intel_for_ip "$1" 4; }

label_from_intel() {
  local base="$1" title="$2" tls="$3" tech="$4" vendor="$5"
  local out="$base"
  add(){
    local tag="$1"
    [[ "$out" == "-" || -z "$out" ]] && { out="$tag"; return; }
    case ",${out}," in *",${tag},"*) : ;; *) out="${out},${tag}" ;; esac
  }
  local t c g v
  t="$(echo "${title:-}" | tr '[:upper:]' '[:lower:]')"
  c="$(echo "${tls:-}" | tr '[:upper:]' '[:lower:]')"
  g="$(echo "${tech:-}" | tr '[:upper:]' '[:lower:]')"
  v="$(echo "${vendor:-}" | tr '[:upper:]' '[:lower:]')"

  # Primary detections
  [[ "$t" == *"synology"* || "$c" == *"synology"* ]] && add "Synology*"
  [[ "$t" == *"qnap"* || "$t" == *"qts"* ]] && add "QNAP*"
  [[ "$t" == *"truenas"* ]] && add "TrueNAS*"
  [[ "$t" == *"pi-hole"* || "$t" == *"pihole"* ]] && add "Pi-hole*"
  [[ "$t" == *"keenetic"* ]] && add "Keenetic*"
  [[ "$t" == *"pfsense"* ]] && add "pfSense*"
  [[ "$t" == *"fortigate"* || "$t" == *"fortinet"* ]] && add "FortiGate*"
  [[ "$t" == *"sophos"* ]] && add "Sophos*"
  [[ "$t" == *"mikrotik"* || "$t" == *"routeros"* ]] && add "MikroTik*"
  [[ "$t" == *"ubiquiti"* || "$t" == *"unifi"* ]] && add "UniFi*"
  [[ "$t" == *"asuswrt"* || "$t" == *"asus router"* ]] && add "ASUS-Router*"
  [[ "$t" == *"tp-link"* || "$t" == *"tplink"* ]] && add "TP-Link*"
  
  [[ "$t" == *"airplay"* || "$t" == *"airtunes"* || "$v" == *"apple"* ]] && add "Apple/AirPlay*"
  [[ "$t" == *"vmware esxi"* || "$g" == *"vmware"* ]] && add "ESXi*"
  [[ "$t" == *"vcenter"* || "$t" == *"vami"* ]] && add "vCenter*"
  [[ "$t" == *"integrated lights-out"* || "$t" == *"hpe ilo"* ]] && add "iLO*"
  [[ "$t" == *"idrac"* ]] && add "iDRAC*"
  [[ "$t" == *"proxmox"* ]] && add "Proxmox*"
  
  # DevOps / Apps
  [[ "$t" == *"jenkins"* || "$g" == *"jenkins"* ]] && add "Jenkins*"
  [[ "$t" == *"portainer"* ]] && add "Portainer*"
  [[ "$t" == *"kubernetes"* || "$t" == *"k8s"* ]] && add "K8s*"
  [[ "$t" == *"grafana"* ]] && add "Grafana*"
  [[ "$t" == *"prometheus"* ]] && add "Prometheus*"
  [[ "$t" == *"wordpress"* ]] && add "WordPress*"
  [[ "$t" == *"apache"* || "$g" == *"apache"* ]] && add "Apache*"
  [[ "$t" == *"nginx"* || "$g" == *"nginx"* ]] && add "Nginx*"
  
  # IoT / Home
  [[ "$t" == *"shelly"* ]] && add "Shelly*"
  [[ "$t" == *"tasmota"* ]] && add "Tasmota*"
  [[ "$t" == *"home assistant"* || "$t" == *"homeassistant"* ]] && add "HomeAssistant*"
  
  # Vendor contextual addition
  v_ctx="$(label_vendor_context "$vendor")"
  if [[ -n "$v_ctx" ]]; then
    IFS=',' read -r -a v_tags <<< "$v_ctx"
    for tag in "${v_tags[@]}"; do add "$tag"; done
  fi

  [[ -z "$out" ]] && echo "-" || echo "$out"
}

# ---------------- Table width & printing (no overflow) ----------------
TERM_COLS="$(tput cols 2>/dev/null || echo 150)"
if ! [[ "$TERM_COLS" =~ ^[0-9]+$ ]]; then TERM_COLS=150; fi
[[ "$TERM_COLS" -lt 100 ]] && TERM_COLS=100

# trunc() helper removed in favor of dynamic fitting

W_IP=15; W_MAC=17; W_VENDOR=25; W_PORTS=20; W_CF=4; W_TITLE=30; W_TLS=30; W_LABELS=30
HAS_INTEL=0
if [[ "$NO_INTEL" -eq 0 && -n "${INTEL_TSV:-}" && -f "$INTEL_TSV" ]]; then HAS_INTEL=1; fi

# calc_widths() removed in favor of content-aware auto-fit

# ---------------- Dynamic Table (Auto-fit to content) ----------------
# We collect all row data first to calculate maximum required widths
declare -a TABLE_DATA
# Add header to calculations
TABLE_DATA+=("IP|MAC|VENDOR|OPEN_PORTS|CF|TITLE|SSL/TLS|LABELS")

for row in "${RESULTS[@]}"; do
  ip="${row%%|*}"
  ports="${row#*|}"
  mac="$(mac_for_ip "$ip" || true)"
  if [[ -n "$mac" ]]; then
    # Normalize for display (add missing leading zeros)
    _m_parts=()
    IFS=':.- ' read -r -a _m_parts <<< "$mac"
    _m_norm=""
    for _p in "${_m_parts[@]}"; do
      [[ ${#_p} -eq 1 ]] && _m_norm+="0${_p}:" || _m_norm+="${_p}:"
    done
    mac="${_m_norm%:}"
  else
    mac="-"
  fi
  
  # Try to find hostname from our temporary file
  hname=""
  if [[ -f "/tmp/sh_names.tsv" ]]; then
    hname=$(grep "^${ip}|" "/tmp/sh_names.tsv" | cut -d'|' -f2 || true)
  fi
  if [[ -n "$hname" ]]; then
    _ip_disp="${ip} (${hname})"
  else
    _ip_disp="$ip"
  fi

  ven="$(vendor_for_mac "$mac")"
  lbl="$(label_ports "$ports")"

  if [[ "$HAS_INTEL" -eq 1 ]]; then
    title="$(intel_title "$ip")"; title="${title:-"-"}"
    tls="$(intel_tls "$ip")"; tls="${tls:-"-"}"
    tech="$(intel_tech "$ip")"
    lbl="$(label_from_intel "$lbl" "$title" "$tls" "$tech" "$ven")"
    cf="$(confidence_score "$ports" "$ven" "$title" "$tls" "$tech")"
    TABLE_DATA+=("$_ip_disp|$mac|$ven|$ports|$cf|$title|$tls|$lbl")
  else
    lbl="$(label_vendor_context "$ven")"
    TABLE_DATA+=("$_ip_disp|$mac|$ven|$ports| | | |${lbl:-"-"}")
  fi
done

# Strip ANSI colors before calculating length
len_no_color() {
  local clean
  clean=$(echo "$1" | sed 's/\x1B\[[0-9;]*[mK]//g')
  echo "${#clean}"
}

# Calculate max width for each column
W_IP=2; W_MAC=3; W_VENDOR=6; W_PORTS=10; W_CF=2; W_TITLE=5; W_TLS=7; W_LABELS=6

for row in "${TABLE_DATA[@]}"; do
  IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 <<< "$row"
  l1=$(len_no_color "$c1"); [[ $l1 -gt $W_IP ]] && W_IP=$l1
  l2=$(len_no_color "$c2"); [[ $l2 -gt $W_MAC ]] && W_MAC=$l2
  l3=$(len_no_color "$c3"); [[ $l3 -gt $W_VENDOR ]] && W_VENDOR=$l3
  l4=$(len_no_color "$c4"); [[ $l4 -gt $W_PORTS ]] && W_PORTS=$l4
  l5=$(len_no_color "$c5"); [[ $l5 -gt $W_CF ]] && W_CF=$l5
  l6=$(len_no_color "$c6"); [[ $l6 -gt $W_TITLE ]] && W_TITLE=$l6
  l7=$(len_no_color "$c7"); [[ $l7 -gt $W_TLS ]] && W_TLS=$l7
  l8=$(len_no_color "$c8"); [[ $l8 -gt $W_LABELS ]] && W_LABELS=$l8
done

line_gen() { printf "%.0s-" $(seq 1 "$1"); }

echo "${GRN}[+] Findings${RST}"
# Print Header
if [[ "$HAS_INTEL" -eq 1 ]]; then
  printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_CF}s  %-${W_TITLE}s  %-${W_TLS}s  %-${W_LABELS}s\n" \
    "IP" "MAC" "VENDOR" "OPEN_PORTS" "CF" "TITLE" "SSL/TLS" "LABELS"
  printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_CF}s  %-${W_TITLE}s  %-${W_TLS}s  %-${W_LABELS}s\n" \
    "$(line_gen $W_IP)" "$(line_gen $W_MAC)" "$(line_gen $W_VENDOR)" "$(line_gen $W_PORTS)" "$(line_gen $W_CF)" "$(line_gen $W_TITLE)" "$(line_gen $W_TLS)" "$(line_gen $W_LABELS)"
else
  printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_LABELS}s\n" \
    "IP" "MAC" "VENDOR" "OPEN_PORTS" "LABELS"
  printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_LABELS}s\n" \
    "$(line_gen $W_IP)" "$(line_gen $W_MAC)" "$(line_gen $W_VENDOR)" "$(line_gen $W_PORTS)" "$(line_gen $W_LABELS)"
fi

# Print Rows (skipping the header we added to the array)
for (( i=1; i<${#TABLE_DATA[@]}; i++ )); do
  IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 <<< "${TABLE_DATA[$i]}"
  if [[ "$HAS_INTEL" -eq 1 ]]; then
    printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_CF}s  %-${W_TITLE}s  %-${W_TLS}s  %-${W_LABELS}s\n" \
      "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8"
  else
    printf "%-${W_IP}s  %-${W_MAC}s  %-${W_VENDOR}s  %-${W_PORTS}s  %-${W_LABELS}s\n" \
      "$c1" "$c2" "$c3" "$c4" "$c8"
  fi
done

# --- Final Infrastructure Summary (Clean Alignment) ---
SC_END=$(date +%s); SC_DIFF=$((SC_END - SC_START))

# Sanitize counts to ensure they are pure numbers
H_COUNT=$(echo "${#FINAL_HOSTS[@]}" | tr -dc '0-9')
P_COUNT=$(printf "%s" "${RESULTS[@]}" | grep -o "," | wc -l | tr -dc '0-9')
ENT_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "Enterprise" | tr -dc '0-9' || echo 0)
IOT_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "IoT" | tr -dc '0-9' || echo 0)
VIRT_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "Virt" | tr -dc '0-9' || echo 0)
STOR_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "Storage" | tr -dc '0-9' || echo 0)
NET_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "Network" | tr -dc '0-9' || echo 0)
APPLE_COUNT=$(printf "%s\n" "${TABLE_DATA[@]}" | grep -c "Apple" | tr -dc '0-9' || echo 0)

echo
echo "${MAG}============================================================${RST}"
echo "${GRN}         Ultimate Infrastructure Discovery Report${RST}"
echo "${MAG}============================================================${RST}"
printf "  %-20s: %-10s | %-15s: %-10s\n" "Target Subnet" "$SUBNET" "Duration" "${SC_DIFF}s"
printf "  %-20s: %-10s | %-15s: %-10s\n" "Total Alive" "$H_COUNT" "Live Services" "$P_COUNT"
echo "${MAG}------------------------------------------------------------${RST}"
printf "  %-20s: %-10s | %-15s: %-10s\n" "Enterprise Assets" "$ENT_COUNT" "Virtualization" "$VIRT_COUNT"
printf "  %-20s: %-10s | %-15s: %-10s\n" "Network Gear" "$NET_COUNT" "Storage/NAS" "$STOR_COUNT"
printf "  %-20s: %-10s | %-15s: %-10s\n" "IoT/Smart Home" "$IOT_COUNT" "Apple/AirPlay" "$APPLE_COUNT"
echo "${MAG}============================================================${RST}"

# Cleanup
[[ -n "${TMP_VENDOR_CACHE:-}" && -f "$TMP_VENDOR_CACHE" ]] && rm -f "$TMP_VENDOR_CACHE" || true
[[ -n "${INTEL_TSV:-}" && -f "$INTEL_TSV" ]] && rm -f "$INTEL_TSV" || true
[[ -f "/tmp/sh_names.tsv" ]] && rm -f "/tmp/sh_names.tsv" || true

[[ -n "${TMP_VENDOR_CACHE:-}" && -f "$TMP_VENDOR_CACHE" ]] && rm -f "$TMP_VENDOR_CACHE" || true
[[ -n "${INTEL_TSV:-}" && -f "$INTEL_TSV" ]] && rm -f "$INTEL_TSV" || true
[[ -f "/tmp/sh_names.tsv" ]] && rm -f "/tmp/sh_names.tsv" || true

echo
echo "${ORG}Quick Tips & Tricks${RST}"
echo "  ${ORG}• Management:${RST} iLO / iDRAC / CIMC / XCC / IPMI: ${YLW}443/22/623${RST} | ESXi: ${YLW}443+902${RST} | vCenter: ${YLW}5480${RST}"
echo "  ${ORG}• Storage   :${RST} Synology (${YLW}5000${RST}) | QNAP (${YLW}8080${RST}) | TrueNAS | Veeam (${YLW}6161${RST}) | MSSQL (${YLW}1433${RST})"
echo "  ${ORG}• Networking:${RST} Cisco / Juniper / H3C / Aruba / Keenetic: genelde ${YLW}22/443${RST} (SNMP ${YLW}161${RST} is key)"
echo "  ${ORG}• DevOps    :${RST} Docker (${YLW}2375${RST}) | Prometheus (${YLW}9100${RST}) | Grafana (${YLW}3000${RST}) | Proxmox (${YLW}8006${RST})"
echo "  ${ORG}• Discovery :${RST} Apple Port 5000 is AirPlay. No Vendor? Use ${YLW}--warm-arp${RST} | Stealth? Use ${YLW}--stealth${RST}"
echo "  ${ORG}• Excel Fix :${RST} If CSV looks messy, ensure delimiter is ${YLW}semicolon (;)${RST} and quotes are handled."
echo "  ${ORG}• Deep Scan :${RST} Confirm with ${YLW}./host_avcisi.sh $SUBNET --deep <ip>${RST}"

# ---------------- CSV Output ----------------
if [[ "$SAVE_CSV" -eq 1 ]]; then
  TIMESTAMP="$(date +"%d-%m-%Y-%H-%M")"
  CSV_NAME="host-avcisi-${TIMESTAMP}.csv"
  CSV_PATH="$HOME/Desktop/$CSV_NAME"
  
  # Professional CSV Export using Python (Quotes + Semicolon + Excel Hint)
  python3 - <<'PY' "$CSV_PATH" "${TABLE_DATA[@]}"
import csv, sys
path = sys.argv[1]
data = sys.argv[2:]
with open(path, 'w', encoding='utf-8-sig', newline='') as f:
    # Add 'sep=;' so Excel doesn't ask and correctly splits columns instantly
    f.write("sep=;\n")
    writer = csv.writer(f, delimiter=';', quotechar='"', quoting=csv.QUOTE_ALL)
    for row in data:
        if row and '|' in row:
            # Clean any accidental newlines inside fields
            fields = [f.replace('\n', ' ').replace('\r', ' ').strip() for f in row.split('|')]
            writer.writerow(fields)
PY
  
  echo
  echo "${GRN}[+] CSV saved (Excel-ready):${RST} ${YLW}${CSV_PATH}${RST}"
fi