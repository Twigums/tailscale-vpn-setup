#!/usr/bin/env bash
 
set -euo pipefail
 
c_red=$'\033[31m'; c_yel=$'\033[33m'; c_grn=$'\033[32m'; c_rst=$'\033[0m'
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s[ok]%s %s\n'   "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[!]%s %s\n'    "$c_yel" "$c_rst" "$*" >&2; }
die()  { printf '%s[x]%s %s\n'    "$c_red" "$c_rst" "$*" >&2; exit 1; }
ask()  {
  local p="$1" d="${2:-}" a
  if [ -n "$d" ]; then read -rp "$p [$d]: " a; printf '%s' "${a:-$d}"
  else read -rp "$p: " a; printf '%s' "$a"; fi
}
 
[ "$(id -u)" -eq 0 ] || die "must run as root"
 
say "starting..."
 
# we define our service as tsvpn
gate_ns="tsvpn_gate_$$"
if ip netns add "$gate_ns" 2>/dev/null; then

  if ip netns exec "$gate_ns" ip link add wgtest type wireguard 2>/dev/null; then
    ip netns exec "$gate_ns" ip link del wgtest 2>/dev/null || true
    ip netns del "$gate_ns" 2>/dev/null || true
    ok "kernel wg works inside a child netns"

  else
    ip netns del "$gate_ns" 2>/dev/null || true
    die "please load the module with:

echo wireguard > /etc/modules-load.d/tsvpn.conf && modprobe wireguard"

  fi

else
  die "did you forget to go through step 2?"

fi
 
CONF="${1:-}"
[ -n "$CONF" ] || CONF="$(ask "path to your wg .conf?" "")"
 
kv() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$CONF" 2>/dev/null | head -n1; }
 
WG_PRESHARED_KEY=""
if [ -n "$CONF" ]; then
  [ -r "$CONF" ] || die "Cannot read '$CONF'."
  WG_PRIVATE_KEY="$(kv PrivateKey)"
  WG_ADDRESS="$(kv Address)"
  WG_PEER_PUBLIC_KEY="$(kv PublicKey)"
  WG_PRESHARED_KEY="$(kv PresharedKey)"
  EP="$(kv Endpoint)"
  WG_ENDPOINT_HOST="${EP%:*}"
  WG_ENDPOINT_PORT="${EP##*:}"

  say "  Address        = ${WG_ADDRESS:-(missing)}"
  say "  Peer PublicKey = ${WG_PEER_PUBLIC_KEY:0:14}$([ -n "$WG_PEER_PUBLIC_KEY" ] && echo ...)"
  say "  Endpoint       = ${WG_ENDPOINT_HOST:-(missing)}:${WG_ENDPOINT_PORT:-(missing)}"
  say "  PresharedKey   = $([ -n "$WG_PRESHARED_KEY" ] && echo present || echo none)"

else
  say "manually enter the values from your wg config:"

  WG_PRIVATE_KEY="$(ask '  [Interface] PrivateKey')"
  WG_ADDRESS="$(ask '  [Interface] Address')"
  WG_PEER_PUBLIC_KEY="$(ask '  [Peer] PublicKey')"
  WG_PRESHARED_KEY="$(ask '  [Peer] PresharedKey (blank if none)' '')"
  WG_ENDPOINT_HOST="$(ask '  [Peer] Endpoint host')"
  WG_ENDPOINT_PORT="$(ask '  [Peer] Endpoint port')"

fi
 
[ -n "$WG_PRIVATE_KEY" ]     || WG_PRIVATE_KEY="$(ask '  PrivateKey (not found in conf)')"
[ -n "$WG_ADDRESS" ]         || WG_ADDRESS="$(ask '  Address (not found in conf)')"
[ -n "$WG_PEER_PUBLIC_KEY" ] || WG_PEER_PUBLIC_KEY="$(ask '  Peer PublicKey (not found in conf)')"
[ -n "$WG_ENDPOINT_HOST" ]   || WG_ENDPOINT_HOST="$(ask '  Endpoint host (not found in conf)')"
[ -n "$WG_ENDPOINT_PORT" ]   || WG_ENDPOINT_PORT="$(ask '  Endpoint port (not found in conf)')"
 
DEF_UPLINK="$(ip route show default 2>/dev/null | awk '/default/{print $5; exit}')"
UPLINK_IF="$(ask 'uplink  interface' "${DEF_UPLINK:-eth0}")"
TAILNET_CIDR="$(ask 'Tailnet CIDR' '100.64.0.0/10')"
 
say ""
say "about to install with this config:"
say "  endpoint=${WG_ENDPOINT_HOST}:${WG_ENDPOINT_PORT}  uplink=${UPLINK_IF}  tailnet=${TAILNET_CIDR}"
case "$(ask 'ok?' 'Y')" in y|Y) ;; *) die "no confirmation" ;; esac
 
# env
mkdir -p /etc/tsvpn
if [ -e /etc/tsvpn/tsvpn.env ]; then

  back="/etc/tsvpn/tsvpn.env.back-$(date +%Y%m%d-%H%M%S)"
  cp -a /etc/tsvpn/tsvpn.env "$back"
  warn "Existing env backed up to $back"

fi

umask 077
cat > /etc/tsvpn/tsvpn.env <<EOF
WG_PRIVATE_KEY="$WG_PRIVATE_KEY"
WG_ADDRESS="$WG_ADDRESS"
WG_PEER_PUBLIC_KEY="$WG_PEER_PUBLIC_KEY"
WG_PRESHARED_KEY="$WG_PRESHARED_KEY"
WG_ENDPOINT_HOST="$WG_ENDPOINT_HOST"
WG_ENDPOINT_PORT="$WG_ENDPOINT_PORT"
UPLINK_IF="$UPLINK_IF"
TAILNET_CIDR="$TAILNET_CIDR"
EOF

chmod 600 /etc/tsvpn/tsvpn.env
ok "wrote /etc/tsvpn/tsvpn.env"
 
# shell script
cat > /usr/local/sbin/tsvpn.sh <<'TSVPN_SH_EOF'
#!/usr/bin/env bash
#
# routes ts exit node traffic out through wg VPN config
#
#   tsvpn.sh up     activate gateway
#   tsvpn.sh down   deactivate gateway
#   tsvpn.sh status show status
 
set -euo pipefail
 
ENV_FILE="${TSVPN_ENV:-/etc/tsvpn/tsvpn.env}"
. "$ENV_FILE"
 
: "${WG_PRIVATE_KEY:?set WG_PRIVATE_KEY in $ENV_FILE}"
: "${WG_PEER_PUBLIC_KEY:?set WG_PEER_PUBLIC_KEY in $ENV_FILE}"
: "${WG_ENDPOINT_HOST:?set WG_ENDPOINT_HOST in $ENV_FILE}"
: "${WG_ENDPOINT_PORT:?set WG_ENDPOINT_PORT in $ENV_FILE}"
: "${WG_ADDRESS:?set WG_ADDRESS in $ENV_FILE}"
 
WG_PRESHARED_KEY="${WG_PRESHARED_KEY:-}"
UPLINK_IF="${UPLINK_IF:-eth0}"
TAILNET_CIDR="${TAILNET_CIDR:-100.64.0.0/10}"
 
# defaults
NS="${NS:-pvpn}"
VETH_HOST_IP="${VETH_HOST_IP:-10.200.0.1}"
VETH_NS_IP="${VETH_NS_IP:-10.200.0.2}"
VETH_CIDR="${VETH_CIDR:-30}"
VETH_NET="${VETH_NET:-10.200.0.0/30}"
GW_TABLE="${GW_TABLE:-200}"
RULE_PREF="${RULE_PREF:-5100}"
WG_MTU="${WG_MTU:-1420}"
VETH_H="${VETH_H:-pvpn0}"
VETH_N="${VETH_N:-pvpn1}"
WG_IF="${WG_IF:-wg0}"
 
ipn() { ip netns exec "$NS" "$@"; }
 
guard_up() {
  iptables  -t mangle -C FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP 2>/dev/null \
    || iptables  -t mangle -A FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -C FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP 2>/dev/null \
      || ip6tables -t mangle -A FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP

  fi
}
 
guard_down() {
  iptables  -t mangle -D FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP 2>/dev/null || true

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -t mangle -D FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP 2>/dev/null || true

  fi
}
 
teardown() {
  ip rule del iif tailscale0 lookup "$GW_TABLE" pref "$RULE_PREF" 2>/dev/null || true
  ip route flush table "$GW_TABLE" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -s "$VETH_NET" -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -i tailscale0 -o "$VETH_H" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$VETH_H" -o tailscale0 -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$VETH_H" -o "$UPLINK_IF" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -i "$UPLINK_IF" -o "$VETH_H" -j ACCEPT 2>/dev/null || true

  ip netns del "$NS" 2>/dev/null || true
  ip link del "$VETH_H" 2>/dev/null || true

}
 
up() {
  guard_up
  teardown
 
  # wait for tailscale0
  local i
  for i in $(seq 1 30); do ip link show tailscale0 >/dev/null 2>&1 && break; sleep 1; done
 
  ip netns add "$NS"
  ipn ip link set lo up
  ip link add "$VETH_H" type veth peer name "$VETH_N"
  ip link set "$VETH_N" netns "$NS"
  ip addr add "${VETH_HOST_IP}/${VETH_CIDR}" dev "$VETH_H"
  ip link set "$VETH_H" up
  ipn ip addr add "${VETH_NS_IP}/${VETH_CIDR}" dev "$VETH_N"
  ipn ip link set "$VETH_N" up
 
  local ep_ip=""
  for i in $(seq 1 10); do
    ep_ip="$(getent ahostsv4 "$WG_ENDPOINT_HOST" | awk 'NR==1{print $1}')" || true
    [ -n "$ep_ip" ] && break
    sleep 2
  done
  [ -n "$ep_ip" ] || { echo "could not resolve $WG_ENDPOINT_HOST after retries" >&2; exit 1; }
 
  ipn ip link add "$WG_IF" type wireguard
  printf '%s\n' "$WG_PRIVATE_KEY" | ipn wg set "$WG_IF" private-key /dev/stdin
  if [ -n "$WG_PRESHARED_KEY" ]; then
    printf '%s\n' "$WG_PRESHARED_KEY" | ipn wg set "$WG_IF" \
      peer "$WG_PEER_PUBLIC_KEY" preshared-key /dev/stdin \
      endpoint "${ep_ip}:${WG_ENDPOINT_PORT}" allowed-ips 0.0.0.0/0 \
      persistent-keepalive 25
  else
    ipn wg set "$WG_IF" \
      peer "$WG_PEER_PUBLIC_KEY" \
      endpoint "${ep_ip}:${WG_ENDPOINT_PORT}" allowed-ips 0.0.0.0/0 \
      persistent-keepalive 25
  fi
 
  ipn ip addr add "$WG_ADDRESS" dev "$WG_IF"
  ipn ip route add "${ep_ip}/32" via "$VETH_HOST_IP" dev "$VETH_N"
  ipn ip route add "$TAILNET_CIDR" via "$VETH_HOST_IP" dev "$VETH_N"
 
  conntrack -D -s "$VETH_NS_IP" 2>/dev/null || true
  iptables -t nat -C POSTROUTING -s "$VETH_NET" -o "$UPLINK_IF" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -s "$VETH_NET" -o "$UPLINK_IF" -j MASQUERADE
 
  ipn ip link set "$WG_IF" mtu "$WG_MTU" up
  ipn ip route add default dev "$WG_IF"
 
  ipn sysctl -q -w net.ipv4.ip_forward=1
  ipn sysctl -q -w net.ipv6.conf.all.disable_ipv6=1 || true
  ipn iptables -F
  ipn iptables -t nat -F
  ipn iptables -t mangle -F
  ipn iptables -P INPUT DROP
  ipn iptables -P FORWARD DROP
  ipn iptables -P OUTPUT ACCEPT
  ipn iptables -A INPUT  -i lo -j ACCEPT
  ipn iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipn iptables -A INPUT  -i "$VETH_N" -j ACCEPT

  ipn iptables -A FORWARD -i "$VETH_N" -o "$WG_IF" -j ACCEPT
  ipn iptables -A FORWARD -i "$WG_IF" -o "$VETH_N" -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  ipn iptables -t nat -A POSTROUTING -o "$WG_IF" -j MASQUERADE
  ipn iptables -t mangle -A FORWARD -o "$WG_IF" -p tcp --syn -j TCPMSS --clamp-mss-to-pmtu
 
  ip route replace default via "$VETH_NS_IP" dev "$VETH_H" table "$GW_TABLE"
  ip rule add iif tailscale0 lookup "$GW_TABLE" pref "$RULE_PREF"
 
  local spec
  for spec in \
    "-i tailscale0 -o $VETH_H" \
    "-i $VETH_H -o tailscale0" \
    "-i $VETH_H -o $UPLINK_IF" \
    "-i $UPLINK_IF -o $VETH_H"; do
    iptables -C FORWARD $spec -j ACCEPT 2>/dev/null || iptables -A FORWARD $spec -j ACCEPT
  done
 
  guard_up
  echo "peer endpoint ${ep_ip}:${WG_ENDPOINT_PORT}, namespace '${NS}'"
}
 
status() {
  if iptables -t mangle -C FORWARD -i tailscale0 -o "$UPLINK_IF" -j DROP 2>/dev/null; then
    echo "  ts clients cannot egress ${UPLINK_IF}"

  else
    echo "  ts clients egress this node's real ip"

  fi

  echo "wg config:"
  ipn wg show "$WG_IF" 2>/dev/null || echo "  (no namespace '${NS}')"

  echo "routes"
  ipn ip route show 2>/dev/null || true

}
 
case "${1:-}" in
  up)     up ;;
  down)   teardown ;;
  status) status ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 2 ;;

esac
TSVPN_SH_EOF

chmod 755 /usr/local/sbin/tsvpn.sh
ok "wrote /usr/local/sbin/tsvpn.sh"
 
# systemd service
cat > /etc/systemd/system/tsvpn.service <<'TSVPN_SERVICE_EOF'
[Unit]
Description=wg + ts exit node
Documentation=man:wg(8)
Wants=network-online.target
After=network-online.target
Wants=tailscaled.service
After=tailscaled.service
 
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/tsvpn.sh up
ExecStop=/usr/local/sbin/tsvpn.sh down
ExecReload=/usr/local/sbin/tsvpn.sh up
TimeoutStartSec=120
 
[Install]
WantedBy=multi-user.target
TSVPN_SERVICE_EOF

ok "wrote /etc/systemd/system/tsvpn.service"
 
systemctl daemon-reload
ok "systemd reloaded"
 
# ask to start right now
case "$(ask 'start tsvpn now?' 'Y')" in y|Y)

    if systemctl enable --now tsvpn; then
      sleep 6

      if ip netns exec pvpn wg show wg0 2>/dev/null | grep -q "latest handshake"; then
        ok "tunnel up"
        ip netns exec pvpn wg show wg0 2>/dev/null | sed -n '/peer:/,$p'

      fi

    else
      warn "something went wrong: check journalctl -eu tsvpn "

    fi
    ;;
  *)

    say "manually enable and start with:  systemctl enable --now tsvpn"
    ;;

esac
 
ok "done"
