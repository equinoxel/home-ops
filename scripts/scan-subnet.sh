#!/usr/bin/env bash
#
# Discover live hosts on one or more subnets and print a table of
# IP address, hostname and (best-effort) operating system.
#
# Usage:
#   scan-subnet.sh [CIDR ...]
#
# Arguments:
#   CIDR  - One or more subnets to scan. Only /24 (or longer) IPv4
#           subnets are swept host-by-host; a /16 is expanded into its
#           256 /24s only when explicitly requested via 192.168.x.
#           Defaults to the common 192.168.x.x home ranges.
#
# Discovery strategy (uses whatever is available, best first):
#   1. nmap -sn                (if a working nmap is installed)
#   2. parallel ICMP ping sweep + kernel neighbor table (ip neigh)
#
# Hostname resolution: reverse DNS (getent) + mDNS (avahi-resolve).
#
# OS detection:
#   - nmap -O                  (needs root AND a working nmap)
#   - otherwise a TTL-based heuristic from ping
#
# Talos detection (TALOS column):
#   - Probes TCP 50000 (apid, the Talos machine API) via a bash /dev/tcp
#     connect test - no nmap or root required.
#   - "yes"    -> talosctl (using $TALOSCONFIG) confirmed a Talos node.
#   - "likely" -> apid:50000 open and SSH:22 closed (Talos ships no SSH).
#   - "maybe"  -> apid:50000 open but SSH also open (ambiguous).
#

set -euo pipefail

log()  { echo "$(date -u '+%H:%M:%S') [scan-subnet] $*" >&2; }
die()  { echo "$(date -u '+%H:%M:%S') [scan-subnet] ERROR: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Which subnets to scan.
# ---------------------------------------------------------------------------
if [[ $# -gt 0 ]]; then
    SUBNETS=("$@")
else
    # Common home ranges. Broad /16s are only fully swept for 192.168.
    SUBNETS=("192.168.0.0/16")
fi

# ---------------------------------------------------------------------------
# Is nmap actually usable? (A shim may exist that isn't really installed.)
# ---------------------------------------------------------------------------
HAVE_NMAP=0
if command -v nmap >/dev/null 2>&1 && nmap --version >/dev/null 2>&1; then
    HAVE_NMAP=1
fi

IS_ROOT=0
[[ "$(id -u)" -eq 0 ]] && IS_ROOT=1

if [[ "$HAVE_NMAP" -eq 0 ]]; then
    log "nmap not usable; falling back to ping sweep + neighbor table."
fi
if [[ "$IS_ROOT" -eq 0 ]]; then
    log "Not root: OS column is a TTL-based best-effort guess (run with sudo + nmap for accuracy)."
fi

# ---------------------------------------------------------------------------
# Expand a CIDR into the list of /24 prefixes we will sweep.
# For anything /24 or longer we sweep that single /24.
# For a /16 we only auto-expand 192.168.* to keep the scan bounded.
# ---------------------------------------------------------------------------
prefixes_for_cidr() {
    local cidr="$1" base mask a b c
    base="${cidr%/*}"
    mask="${cidr#*/}"
    IFS=. read -r a b c _ <<<"$base"

    if [[ "$mask" -ge 24 ]]; then
        echo "${a}.${b}.${c}"
    elif [[ "$mask" -ge 16 ]]; then
        local i
        for ((i = 0; i < 256; i++)); do echo "${a}.${b}.${i}"; done
    else
        die "Refusing to sweep a subnet larger than /16: ${cidr}"
    fi
}

# ---------------------------------------------------------------------------
# Ping-sweep a single /24 in parallel; prints IPs that answer.
# Also warms the kernel neighbor (ARP) table.
# ---------------------------------------------------------------------------
ping_sweep_24() {
    local prefix="$1" i
    # Fire all 254 pings concurrently; each caps at 1s, so a /24 takes ~1-8s.
    for ((i = 1; i < 255; i++)); do
        ( ping -c1 -W1 "${prefix}.${i}" >/dev/null 2>&1 && echo "${prefix}.${i}" ) &
    done
    wait
}

# ---------------------------------------------------------------------------
# Discover live hosts across all requested subnets.
# ---------------------------------------------------------------------------
declare -a HOSTS=()

# Returns 0 if $ip falls inside CIDR (only /16 and /24+ are handled).
ip_in_cidr() {
    local ip="$1" cidr="$2" base mask a b c
    base="${cidr%/*}"; mask="${cidr#*/}"
    IFS=. read -r a b c _ <<<"$base"
    if [[ "$mask" -ge 24 ]]; then
        [[ "$ip" == "${a}.${b}.${c}."* ]]
    else
        [[ "$ip" == "${a}.${b}."* ]]
    fi
}

for cidr in "${SUBNETS[@]}"; do
    log "Discovering live hosts on ${cidr} ..."
    if [[ "$HAVE_NMAP" -eq 1 ]]; then
        # nmap does its own reliable host discovery (incl. ARP on local nets).
        while IFS= read -r ip; do
            [[ -n "$ip" ]] && HOSTS+=("$ip")
        done < <(nmap -n -sn "$cidr" 2>/dev/null \
            | awk '/Nmap scan report/ {print $NF}' \
            | tr -d '()')
    else
        # No nmap: ping-sweep to populate the ARP/neighbor table, then trust
        # only IPs that resolved to a MAC. A bare ICMP reply is unreliable
        # (proxy-ARP / captive gateways answer for non-existent addresses),
        # but a real MAC in the neighbor table means a device actually replied.
        while IFS= read -r prefix; do
            ping_sweep_24 "$prefix" >/dev/null
        done < <(prefixes_for_cidr "$cidr")
    fi
done

# Take the authoritative on-link host list from the neighbor table: only
# entries that have a MAC (lladdr) and are not FAILED/INCOMPLETE.
while IFS= read -r ip; do
    for cidr in "${SUBNETS[@]}"; do
        ip_in_cidr "$ip" "$cidr" && { HOSTS+=("$ip"); break; }
    done
done < <(ip -4 neigh show 2>/dev/null \
    | awk '$1 ~ /^[0-9]+\./ && /lladdr/ && !/FAILED|INCOMPLETE/ {print $1}')

# Always include our own addresses that sit in a requested subnet.
while IFS= read -r ip; do
    for cidr in "${SUBNETS[@]}"; do
        ip_in_cidr "$ip" "$cidr" && { HOSTS+=("$ip"); break; }
    done
done < <(ip -4 -o addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}')

# De-duplicate and sort numerically.
if [[ ${#HOSTS[@]} -eq 0 ]]; then
    log "No live hosts found on: ${SUBNETS[*]}"
    exit 0
fi
mapfile -t HOSTS < <(printf '%s\n' "${HOSTS[@]}" | sort -u -t. -k1,1n -k2,2n -k3,3n -k4,4n)
log "Found ${#HOSTS[@]} host(s). Resolving names and OS ..."

# ---------------------------------------------------------------------------
# Resolve a hostname for an IP (first hit wins).
# ---------------------------------------------------------------------------
resolve_name() {
    local ip="$1" name=""
    name=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}' | head -n1 || true)
    if [[ -z "$name" ]] && command -v avahi-resolve >/dev/null 2>&1; then
        # avahi blocks ~5s when there is no mDNS record; cap it hard.
        name=$(timeout 1 avahi-resolve -a "$ip" 2>/dev/null | awk '{print $2}' | head -n1 || true)
    fi
    [[ -n "$name" ]] && echo "$name" || echo "-"
}

# ---------------------------------------------------------------------------
# TTL-based OS guess (fallback when nmap -O is unavailable).
# ---------------------------------------------------------------------------
guess_os_from_ttl() {
    local ip="$1" ttl=""
    ttl=$(ping -c1 -W1 "$ip" 2>/dev/null | grep -oE 'ttl=[0-9]+' | head -n1 | cut -d= -f2 || true)
    [[ -z "$ttl" ]] && { echo "unknown"; return; }
    if   (( ttl <= 64 ));  then echo "Linux/Unix (ttl=${ttl})"
    elif (( ttl <= 128 )); then echo "Windows (ttl=${ttl})"
    else echo "Network/Other (ttl=${ttl})"
    fi
}

os_for_ip() {
    local ip="$1" os=""
    if [[ "$HAVE_NMAP" -eq 1 && "$IS_ROOT" -eq 1 ]]; then
        os=$(nmap -n -O --osscan-guess "$ip" 2>/dev/null \
            | grep -E 'Running:|OS details:|Aggressive OS guesses:' \
            | head -n1 | cut -d: -f2- | sed 's/^ *//' || true)
    fi
    [[ -z "$os" ]] && os=$(guess_os_from_ttl "$ip")
    echo "$os"
}

# ---------------------------------------------------------------------------
# Is a TCP port open? Pure-bash connect probe via /dev/tcp (no nmap/root).
# Returns 0 (open) / 1 (closed) within ~1s.
# ---------------------------------------------------------------------------
tcp_open() {
    local ip="$1" port="$2"
    timeout 1 bash -c ": < /dev/tcp/${ip}/${port}" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Talos Linux fingerprint.
#   - TCP 50000 (apid, the Talos machine API) open on every Talos node.
#   - TCP 22 (SSH) closed  -> Talos ships no SSH, strong corroboration.
#   - Optional: if talosctl + TALOSCONFIG are present, `talosctl version`
#     succeeds only against a trusted Talos node -> definitive "yes".
# Prints: "yes" (confirmed), "likely" (ports match), or "-".
# ---------------------------------------------------------------------------
talos_for_ip() {
    local ip="$1"
    if ! tcp_open "$ip" 50000; then
        echo "-"; return
    fi
    # apid is open. Try an authenticated, definitive check if we can.
    if [[ -n "${TALOSCONFIG:-}" && -f "${TALOSCONFIG:-/nonexistent}" ]] \
        && command -v talosctl >/dev/null 2>&1; then
        if timeout 5 talosctl --nodes "$ip" version --short >/dev/null 2>&1; then
            echo "yes"; return
        fi
    fi
    # No auth confirmation: use the port heuristic. Talos has no SSH.
    if tcp_open "$ip" 22; then
        echo "maybe (50000 open, but 22 open too)"
    else
        echo "likely (apid:50000, no ssh)"
    fi
}

# ---------------------------------------------------------------------------
# Build and print the table.
# ---------------------------------------------------------------------------
export -f resolve_name guess_os_from_ttl os_for_ip tcp_open talos_for_ip
export HAVE_NMAP IS_ROOT TALOSCONFIG

row_for_ip() {
    local ip="$1"
    printf '%s\t%s\t%s\t%s\n' \
        "$ip" "$(resolve_name "$ip")" "$(os_for_ip "$ip")" "$(talos_for_ip "$ip")"
}
export -f row_for_ip

{
    printf 'IP\tHOSTNAME\tOS\tTALOS\n'
    # Resolve rows in parallel (bounded).
    # Ordering: hosts WITHOUT a resolved hostname first, hosts WITH a
    # hostname last; each group sorted by IP address.
    #   - Prepend a sort key: group flag (0 = no name, 1 = has name) plus a
    #     zero-padded IP so a plain lexical sort orders numerically.
    #   - Sort on that key, then strip it back off.
    printf '%s\n' "${HOSTS[@]}" \
        | xargs -P 32 -I{} bash -c 'row_for_ip "$@"' _ {} \
        | awk -F'\t' '{
            grp = ($2 == "-") ? 0 : 1
            split($1, o, ".")
            key = sprintf("%d %03d%03d%03d%03d", grp, o[1], o[2], o[3], o[4])
            print key "\t" $0
          }' \
        | sort -k1,1 \
        | cut -f2-
} | column -t -s $'\t'
