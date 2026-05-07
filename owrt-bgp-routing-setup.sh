#!/bin/sh
# BGP selective routing setup for OpenWrt + AmneziaWG + BIRD2
# Run directly on router: wget -O /tmp/bgp-setup.sh <URL> && sh /tmp/bgp-setup.sh

set -e

CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD='\033[1m'
NC='\033[0m'

info()  { printf "%b" "${CYAN}${BOLD}[?]${NC} $1 " >&2; }
ok()    { printf "%b\n" "${GREEN}${BOLD}[✓]${NC} $1"; }
warn()  { printf "%b\n" "${YELLOW}${BOLD}[!]${NC} $1"; }
err()   { printf "%b\n" "${RED}${BOLD}[✗]${NC} $1" >&2; }
header(){ printf "%b\n" "\n${BOLD}═══ $1 ═══${NC}"; }

ask() {
    _prompt="$1"
    _default="$2"
    if [ -n "$_default" ]; then
        info "$_prompt [$_default]:"
    else
        info "$_prompt:"
    fi
    read -r _answer
    [ -z "$_answer" ] && _answer="$_default"
    printf "%s" "$_answer"
}

ask_yesno() {
    _prompt="$1"
    _default="${2:-y}"
    info "$_prompt [${_default}]?"
    read -r _answer
    [ -z "$_answer" ] && _answer="$_default"
    case "$_answer" in y|Y|yes|YES) return 0;; *) return 1;; esac
}

validate_bird_name() {
    case "$1" in
        *[!A-Za-z0-9_]*) return 1;;
        "") return 1;;
        *) return 0;;
    esac
}

require_uint() {
    case "$1" in
        ""|*[!0-9]*) return 1;;
        *) return 0;;
    esac
}

require_prefix() {
    require_uint "$1" || return 1
    [ "$1" -le 32 ]
}

require_ipv4() {
    OLDIFS="$IFS"
    IFS=.
    set -- $1
    IFS="$OLDIFS"
    [ "$#" -eq 4 ] || return 1
    for _octet in "$@"; do
        require_uint "$_octet" || return 1
        [ "$_octet" -ge 0 ] && [ "$_octet" -le 255 ] || return 1
    done
}

require_iface() {
    case "$1" in
        ""|*[!A-Za-z0-9_.:-]*) return 1;;
        *) return 0;;
    esac
}

require_cron_minutes() {
    require_uint "$1" || return 1
    [ "$1" -ge 1 ] && [ "$1" -le 59 ]
}

prefix_to_netmask() {
    _p="$1"
    _mask=""
    _i=1
    while [ "$_i" -le 4 ]; do
        if [ "$_p" -ge 8 ]; then
            _oct=255
            _p=$((_p - 8))
        elif [ "$_p" -gt 0 ]; then
            _oct=$((256 - (1 << (8 - _p))))
            _p=0
        else
            _oct=0
        fi
        [ -n "$_mask" ] && _mask="$_mask."
        _mask="$_mask$_oct"
        _i=$((_i + 1))
    done
    printf "%s" "$_mask"
}

calc_network() {
    _ip="$1"
    _prefix="$2"
    require_prefix "$_prefix" || { echo "$_ip" | sed 's/\.[0-9]*$/.0/'; return; }
    if command -v ipcalc.sh >/dev/null 2>&1; then
        _netmask=$(prefix_to_netmask "$_prefix")
        # shellcheck disable=SC2046
        eval $(ipcalc.sh "$_ip" "$_netmask" 2>/dev/null | grep '^NETWORK=')
        [ -n "$NETWORK" ] && { printf "%s" "$NETWORK"; return; }
    fi
    # Conservative fallback for common home LAN / tunnel layouts.
    echo "$_ip" | sed 's/\.[0-9]*$/.0/'
}

calc_default_gw() {
    _ip="$1"
    _prefix="$2"
    # Only guess safely for the common /24 case. For other prefixes, ask explicitly.
    [ "$_prefix" = "24" ] || return 1
    printf "%s" "${_ip%.*}.1"
}

detect_tunnel_iface() {
    # Prefer an interface that already has IPv4 and looks like WG/AmneziaWG.
    for _dev in $(ip -o -4 addr show 2>/dev/null | awk '{print $2}' | sort -u); do
        case "$_dev" in
            wg*|awg*|amnezia*|amwg*) printf "%s" "$_dev"; return 0;;
        esac
    done
    for _dev in $(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | cut -d@ -f1 | sort -u); do
        case "$_dev" in
            wg*|awg*|amnezia*|amwg*) printf "%s" "$_dev"; return 0;;
        esac
    done
    return 1
}

detect_iface_ipv4_cidr() {
    ip -o -4 addr show "$1" 2>/dev/null | awk '{print $4}' | head -1
}

# ============================
clear
printf "${BOLD}"
cat << 'BANNER'

  ╔═══════════════════════════════════════════════╗
  ║   BGP Selective Routing Setup                ║
  ║   OpenWrt + WireGuard/AmneziaWG + BIRD2      ║
  ╚═══════════════════════════════════════════════╝
BANNER
printf "${NC}\n"

# ============================
# Detect
# ============================
header "Auto-detecting network"
WAN_GW=$(ip route show default 2>/dev/null | awk '{print $3}' | head -1)
WAN_DEV=$(ip route show default 2>/dev/null | awk '{print $5}' | head -1)
LAN_IP=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f1 | head -1)
LAN_MASK=$(ip -4 addr show br-lan 2>/dev/null | grep inet | awk '{print $2}' | cut -d/ -f2 | head -1)

if [ -z "$WAN_GW" ] || [ -z "$WAN_DEV" ] || [ -z "$LAN_IP" ] || [ -z "$LAN_MASK" ]; then
    err "Cannot detect WAN/LAN. Configure manually."
    exit 1
fi
require_ipv4 "$WAN_GW" || { err "Detected WAN gateway is not valid IPv4"; exit 1; }
require_iface "$WAN_DEV" || { err "Detected WAN device name is invalid"; exit 1; }
require_ipv4 "$LAN_IP" || { err "Detected LAN IP is not valid IPv4"; exit 1; }
require_prefix "$LAN_MASK" || { err "Detected LAN prefix is invalid"; exit 1; }

LAN_SUBNET=$(calc_network "$LAN_IP" "$LAN_MASK")

printf "  WAN:     ${GREEN}${WAN_DEV}${NC} gw ${GREEN}${WAN_GW}${NC}\n"
printf "  LAN:     ${GREEN}${LAN_IP}/${LAN_MASK}${NC}\n"

# ============================
# Basic config
# ============================
header "WireGuard / Tunnel"
AUTO_WG_DEV=$(detect_tunnel_iface || true)
if [ -n "$AUTO_WG_DEV" ]; then
    AUTO_WG_CIDR=$(detect_iface_ipv4_cidr "$AUTO_WG_DEV")
    if [ -n "$AUTO_WG_CIDR" ]; then
        printf "  Detected tunnel: ${GREEN}${AUTO_WG_DEV}${NC} (${GREEN}${AUTO_WG_CIDR}${NC})\n"
    else
        printf "  Detected tunnel: ${GREEN}${AUTO_WG_DEV}${NC} (${YELLOW}no IPv4 yet${NC})\n"
    fi
    if ask_yesno "Use detected tunnel interface ${AUTO_WG_DEV}" "y"; then
        WG_DEV="$AUTO_WG_DEV"
    else
        WG_DEV=$(ask "Tunnel interface" "$AUTO_WG_DEV")
        printf "\n"
    fi
else
    WG_DEV=$(ask "Tunnel interface" "wg0")
    printf "\n"
fi
require_iface "$WG_DEV" || { err "Tunnel interface name is invalid"; exit 1; }

WG_CIDR=$(detect_iface_ipv4_cidr "$WG_DEV")
WG_LOCAL_IP=$(printf "%s" "$WG_CIDR" | cut -d/ -f1)
WG_PREFIX=$(printf "%s" "$WG_CIDR" | cut -d/ -f2)
if [ -n "$WG_LOCAL_IP" ] && [ -n "$WG_PREFIX" ]; then
    printf "  Router tunnel IP: ${GREEN}${WG_LOCAL_IP}/${WG_PREFIX}${NC}\n"
else
    WG_LOCAL_IP=$(ask "Router tunnel IP" "10.8.0.2")
    printf "\n"
    WG_PREFIX=$(ask "Tunnel prefix length" "24")
    printf "\n"
fi
require_ipv4 "$WG_LOCAL_IP" || { err "Router tunnel IP must be valid IPv4"; exit 1; }
require_prefix "$WG_PREFIX" || { err "Tunnel prefix length must be 0..32"; exit 1; }

WG_SUBNET=$(calc_network "$WG_LOCAL_IP" "$WG_PREFIX")
WG_GW_DEFAULT=$(calc_default_gw "$WG_LOCAL_IP" "$WG_PREFIX" 2>/dev/null || true)
WG_GW=$(ask "Tunnel gateway (server IP)" "$WG_GW_DEFAULT")
printf "\n"
require_ipv4 "$WG_GW" || { err "Tunnel gateway must be valid IPv4"; exit 1; }

TABLE=$(ask "Kernel routing table" "100")
printf "\n"
require_uint "$TABLE" || { err "Kernel routing table must be numeric"; exit 1; }
PRIORITY=$(ask "ip rule priority" "1000")
printf "\n"
require_uint "$PRIORITY" || { err "ip rule priority must be numeric"; exit 1; }

LOCAL_AS=$(ask "Local AS number" "65433")
printf "\n"
require_uint "$LOCAL_AS" || { err "Local AS number must be numeric"; exit 1; }

# ============================
# BGP Peers
# ============================
header "BGP Peers"

TOTAL_PEERS=0
PEER_NAMES=""
PEER_IPS=""
PEER_ASS=""
PEER_COMMS=""

add_peer() {
    _n="$1"
    printf "\n${BOLD}── Peer $((_n + 1)) ──${NC}\n"

    peer_name=$(ask "Name (letters, digits, underscore)" "peer$((_n + 1))")
    printf "\n"
    validate_bird_name "$peer_name" || { err "Invalid peer name. Use only letters, digits, underscore."; return 1; }
    peer_ip=$(ask "Peer IP address" "")
    printf "\n"
    require_ipv4 "$peer_ip" || { err "Peer IP must be valid IPv4"; return 1; }
    peer_as=$(ask "Peer AS number" "")
    printf "\n"
    require_uint "$peer_as" || { err "AS number must be numeric"; return 1; }

    peer_comm=""
    if ask_yesno "Filter by BGP communities?" "n"; then
        printf "  Format: AS:NN,AS:NN  (example: 65432:100,65432:200)\n"
        peer_raw=$(ask "Communities" "")
        printf "\n"
        if [ -n "$peer_raw" ]; then
            peer_first=1
            OLDIFS="$IFS"
            IFS=','
            for c in $peer_raw; do
                peer_a=$(echo "$c" | cut -d: -f1)
                peer_nn=$(echo "$c" | cut -d: -f2)
                require_uint "$peer_a" && require_uint "$peer_nn" || { IFS="$OLDIFS"; err "Community must be AS:NN numeric"; return 1; }
                if [ "$peer_first" = 1 ]; then
                    peer_comm="($peer_a, $peer_nn)"
                    peer_first=0
                else
                    peer_comm="$peer_comm, ($peer_a, $peer_nn)"
                fi
            done
            IFS="$OLDIFS"
        fi
    fi

    PEER_NAMES="${PEER_NAMES}${peer_name}
"
    PEER_IPS="${PEER_IPS}${peer_ip}
"
    PEER_ASS="${PEER_ASS}${peer_as}
"
    PEER_COMMS="${PEER_COMMS}${peer_comm}
"
    TOTAL_PEERS=$((TOTAL_PEERS + 1))
}

add_peer 0

while ask_yesno "Add another BGP peer?" "n"; do
    add_peer $TOTAL_PEERS
done

# ============================
# Options
# ============================
header "Options"

ENABLE_FALLBACK=0
if ask_yesno "Enable fallback (flush BGP routes when tunnel is down)?" "y"; then
    ENABLE_FALLBACK=1
    FALLBACK_INTERVAL=$(ask "Check interval (minutes)" "1")
    printf "\n"
    require_cron_minutes "$FALLBACK_INTERVAL" || { err "Check interval must be 1..59 minutes"; exit 1; }
fi

ENABLE_SYSCTL=0
if ask_yesno "Optimize sysctl net buffers?" "y"; then
    ENABLE_SYSCTL=1
fi

# ============================
# Summary
# ============================
header "Summary"

printf "  Router ID:  ${GREEN}${LAN_IP}${NC}\n"
printf "  Tunnel:     ${GREEN}${WG_DEV}${NC} (${WG_LOCAL_IP}) gw ${WG_GW}\n"
printf "  Table:      ${GREEN}${TABLE}${NC} priority ${GREEN}${PRIORITY}${NC}\n"
printf "  LAN → BGP:  ${GREEN}${LAN_SUBNET}/${LAN_MASK}${NC}\n"
printf "  Local AS:   ${GREEN}${LOCAL_AS}${NC}\n"
printf "  BGP peers:  ${GREEN}${TOTAL_PEERS}${NC}\n"

_names=$(echo "$PEER_NAMES" | head -$TOTAL_PEERS)
_ips=$(echo "$PEER_IPS" | head -$TOTAL_PEERS)
_ass=$(echo "$PEER_ASS" | head -$TOTAL_PEERS)
_comms=$(echo "$PEER_COMMS" | head -$TOTAL_PEERS)

_i=1
for _pname in $_names; do
    _pip=$(echo "$_ips" | sed -n "${_i}p")
    _pas=$(echo "$_ass" | sed -n "${_i}p")
    _pcom=$(echo "$_comms" | sed -n "${_i}p")
    printf "    ${BOLD}%s${NC}: %s AS%s" "$_pname" "$_pip" "$_pas"
    [ -n "$_pcom" ] && printf " [communities]"
    printf "\n"
    _i=$((_i + 1))
done

[ "$ENABLE_FALLBACK" = "1" ] && printf "  Fallback:   ${GREEN}every ${FALLBACK_INTERVAL} min${NC}\n"
[ "$ENABLE_SYSCTL" = "1" ] && printf "  Sysctl:     ${GREEN}optimized${NC}\n"
printf "\n"

if ! ask_yesno "Apply?" "y"; then
    warn "Aborted."
    exit 0
fi

# ============================
# Build configs
# ============================
header "Deploying"

# Build static routes string (outside subshell)
STATIC_STR=""
for _pip in $(echo "$_ips" | head -$TOTAL_PEERS); do
    [ -z "$_pip" ] && continue
    STATIC_STR="${STATIC_STR}    route ${_pip}/32 via ${WAN_GW};
"
done

# Build BGP blocks string (outside subshell)
BGP_STR=""
_i=1
for _pname in $(echo "$_names" | head -$TOTAL_PEERS); do
    _pip=$(echo "$_ips" | sed -n "${_i}p")
    _pas=$(echo "$_ass" | sed -n "${_i}p")
    _pcom=$(echo "$_comms" | sed -n "${_i}p")
    [ -z "$_pname" ] && { _i=$((_i + 1)); continue; }

    if [ -n "$_pcom" ]; then
        _import="import filter {
                if bgp_community ~ [${_pcom}] then {
                    gw = ${WG_GW};
                    accept;
                }
                reject;
            }"
    else
        _import="import filter {
                gw = ${WG_GW};
                accept;
            }"
    fi

    BGP_STR="${BGP_STR}
protocol bgp ${_pname} {
    local as ${LOCAL_AS};
    neighbor ${_pip} as ${_pas};
    multihop;
    hold time 240;
    keepalive time 80;

    ipv4 {
        ${_import};
        export none;
    };
    graceful restart on;
}
"
    _i=$((_i + 1))
done

# ===== Install packages =====
printf "${CYAN}Installing BIRD2...${NC}\n"
if command -v apk >/dev/null 2>&1; then
    apk update -q
    apk add bird2
elif command -v opkg >/dev/null 2>&1; then
    opkg update
    opkg install bird2 bird2c || opkg install bird2
else
    err "No supported package manager found (apk/opkg)"
    exit 1
fi
ok "BIRD2 installed"

BIRD_SERVICE=""
for _svc in bird2 bird; do
    [ -x "/etc/init.d/$_svc" ] && { BIRD_SERVICE="$_svc"; break; }
done
[ -n "$BIRD_SERVICE" ] || { err "Neither /etc/init.d/bird2 nor /etc/init.d/bird found"; exit 1; }
BIRDC_BIN="/usr/sbin/birdc"
[ -x "$BIRDC_BIN" ] || BIRDC_BIN="$(command -v birdc 2>/dev/null || true)"
[ -n "$BIRDC_BIN" ] || { err "birdc not found"; exit 1; }

# ===== Write bird.conf =====
printf "${CYAN}Writing /etc/bird.conf...${NC}\n"
BIRD_CONF_TMP=/tmp/bird.conf.bgp
BIRD_CONF_BAK=/etc/bird.conf.bak.bgp-setup
cat > "$BIRD_CONF_TMP" << BIRDEOF
log syslog all;
router id ${LAN_IP};

protocol device {
    scan time 60;
}

protocol direct {
    disabled;
    ipv4;
}

protocol static s_uplink {
    ipv4;
${STATIC_STR}}

${BGP_STR}
protocol kernel kbgp {
    kernel table ${TABLE};
    learn;
    scan time 15;
    graceful restart on;
    ipv4 {
        import none;
        export filter {
            if source = RTS_BGP then {
                krt_prefsrc = ${WG_LOCAL_IP};
                accept;
            }
            reject;
        };
    };
}
BIRDEOF

BIRD_BIN="$(command -v bird 2>/dev/null || command -v bird2 2>/dev/null || true)"
[ -n "$BIRD_BIN" ] || { err "bird/bird2 binary not found"; exit 1; }
"$BIRD_BIN" -p -c "$BIRD_CONF_TMP" >/dev/null || { err "Generated BIRD config failed validation"; exit 1; }
[ -f /etc/bird.conf ] && cp /etc/bird.conf "$BIRD_CONF_BAK"
mv "$BIRD_CONF_TMP" /etc/bird.conf
ok "bird.conf written"

# ===== rc.local =====
printf "${CYAN}Updating /etc/rc.local...${NC}\n"
[ -f /etc/rc.local ] || printf '#!/bin/sh\n\nexit 0\n' > /etc/rc.local
awk '
    /^# BEGIN bgp-setup$/ { skip=1; next }
    /^# END bgp-setup$/ { skip=0; next }
    !skip { print }
' /etc/rc.local > /tmp/rc.local.bgp
awk '
    /^exit 0$/ && !done {
        print "# BEGIN bgp-setup"
        print "ip route replace '${WG_SUBNET}'/'${WG_PREFIX}' dev '${WG_DEV}' table '${TABLE}'"
        print "ip rule add from '${LAN_SUBNET}'/'${LAN_MASK}' lookup '${TABLE}' priority '${PRIORITY}' 2>/dev/null || true"
        print "# END bgp-setup"
        done=1
    }
    { print }
    END {
        if (!done) {
            print "# BEGIN bgp-setup"
            print "ip route replace '${WG_SUBNET}'/'${WG_PREFIX}' dev '${WG_DEV}' table '${TABLE}'"
            print "ip rule add from '${LAN_SUBNET}'/'${LAN_MASK}' lookup '${TABLE}' priority '${PRIORITY}' 2>/dev/null || true"
            print "# END bgp-setup"
            print "exit 0"
        }
    }
' /tmp/rc.local.bgp > /etc/rc.local
chmod +x /etc/rc.local
ok "rc.local updated"

# ===== Hotplug =====
printf "${CYAN}Writing hotplug...${NC}\n"
mkdir -p /etc/hotplug.d/iface
cat > /etc/hotplug.d/iface/90-bgp-routing << HPEOF
#!/bin/sh
[ "\$INTERFACE" = "${WG_DEV}" ] || exit 0

case "\$ACTION" in
    ifup)
        logger -t bgp-setup "${WG_DEV} up - restoring table ${TABLE}"
        sleep 5
        ip route replace ${WG_SUBNET}/${WG_PREFIX} dev ${WG_DEV} table ${TABLE} 2>/dev/null || true
        ip rule add from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
        "${BIRDC_BIN}" configure soft 2>/dev/null || true
        sleep 10
        logger -t bgp-setup "table ${TABLE}: \$(ip route show table ${TABLE} | wc -l) routes"
        ;;
    ifdown)
        logger -t bgp-setup "${WG_DEV} down - flushing table ${TABLE}"
        ip route flush table ${TABLE} proto bird 2>/dev/null || ip route flush table ${TABLE} 2>/dev/null || true
        ip rule del from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
        "${BIRDC_BIN}" configure soft 2>/dev/null || true
        ;;
esac
HPEOF
chmod +x /etc/hotplug.d/iface/90-bgp-routing
ok "hotplug written"

# ===== Fallback =====
if [ "$ENABLE_FALLBACK" = "1" ]; then
    printf "${CYAN}Setting up fallback...${NC}\n"
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/wg-fallback.sh << FBEOF
#!/bin/sh
GW=${WG_GW}
BIRDC=${BIRDC_BIN}
TABLE=${TABLE}
WG_DEV=${WG_DEV}
WG_SUBNET=${WG_SUBNET}
WG_PREFIX=${WG_PREFIX}

# Check tunnel reachability
if ! ping -c 1 -W 2 "\$GW" > /dev/null 2>&1; then
    COUNT=\$(ip route show table "\$TABLE" | wc -l)
    if [ "\$COUNT" -gt 1 ]; then
        logger -t wg-fallback "GW \$GW unreachable, flushing \$COUNT routes from table \$TABLE"
        ip route flush table "\$TABLE" proto bird 2>/dev/null || ip route flush table "\$TABLE" 2>/dev/null || true
        ip route replace "\$WG_SUBNET/\$WG_PREFIX" dev "\$WG_DEV" table "\$TABLE" 2>/dev/null
    fi
    exit 0
fi

# Tunnel is up - check if any BGP session is established
if "\$BIRDC" show protocols 2>/dev/null | grep -q "BGP.*Established"; then
    exit 0
fi

# Tunnel reachable but no BGP session - reconfigure bird
logger -t wg-fallback "Tunnel up but no BGP Established, triggering birdc configure"
"\$BIRDC" configure soft 2>/dev/null || true
FBEOF
    chmod +x /usr/local/bin/wg-fallback.sh
    (crontab -l 2>/dev/null | grep -v wg-fallback; echo "*/${FALLBACK_INTERVAL} * * * * /usr/local/bin/wg-fallback.sh") | crontab -
    ok "fallback cron (every ${FALLBACK_INTERVAL} min)"
fi

# ===== Sysctl =====
if [ "$ENABLE_SYSCTL" = "1" ]; then
    printf "${CYAN}Configuring sysctl...${NC}\n"
    sysctl -w net.core.rmem_default=4194304 net.core.wmem_default=4194304 \
           net.core.rmem_max=4194304 net.core.wmem_max=4194304 > /dev/null
    awk '!/^net\.core\.(rmem_default|wmem_default|rmem_max|wmem_max)=/' /etc/sysctl.conf 2>/dev/null > /tmp/sysctl.conf.bgp || true
    cat >> /tmp/sysctl.conf.bgp << SYSCTLEOF
net.core.rmem_default=4194304
net.core.wmem_default=4194304
net.core.rmem_max=4194304
net.core.wmem_max=4194304
SYSCTLEOF
    mv /tmp/sysctl.conf.bgp /etc/sysctl.conf
    ok "sysctl configured"
fi

# ===== Apply now =====
printf "${CYAN}Applying rules...${NC}\n"
ip route replace ${WG_SUBNET}/${WG_PREFIX} dev ${WG_DEV} table ${TABLE} 2>/dev/null || true
ip rule del from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
ip rule add from ${LAN_SUBNET}/${LAN_MASK} lookup ${TABLE} priority ${PRIORITY} 2>/dev/null || true
# Remove stale WG route for LAN subnet if exists
ip route show | grep "${LAN_SUBNET}/.*dev ${WG_DEV}" 2>/dev/null | while IFS= read -r _line; do
    _prefix=$(printf '%s' "$_line" | awk '{print $1}')
    [ -n "$_prefix" ] && ip route del "$_prefix" 2>/dev/null || true
done || true
ok "ip rules applied"

# ===== Start BIRD =====
printf "${CYAN}Starting BIRD...${NC}\n"
/etc/init.d/${BIRD_SERVICE} enable || { err "Failed to enable ${BIRD_SERVICE}"; exit 1; }
if ! /etc/init.d/${BIRD_SERVICE} restart; then
    err "BIRD restart failed"
    if [ -f "$BIRD_CONF_BAK" ]; then
        warn "Restoring previous /etc/bird.conf"
        cp "$BIRD_CONF_BAK" /etc/bird.conf
        /etc/init.d/${BIRD_SERVICE} restart || true
    fi
    exit 1
fi
sleep 5

# ===== Done =====
header "Result"
printf "  ${BOLD}BIRD:${NC}\n"
"${BIRDC_BIN}" show protocols 2>&1 | sed 's/^/    /'
printf "\n  ${BOLD}Table %s:${NC} %s routes\n" "$TABLE" "$(ip route show table $TABLE | wc -l)"
printf "  ${BOLD}ip rules:${NC}\n"
ip rule show | sed 's/^/    /'

printf "\n${GREEN}${BOLD}Done!${NC}\n"
