# shellcheck shell=bash
# =============================================================================
#  lab/lib-lab.sh — budowa izolowanej sieci laboratoryjnej
# =============================================================================
#  Wszystko dzieje się w przestrzeniach nazw utworzonych przez `unshare`
#  (user + net + mount + pid). Twoja prawdziwa sieć, iptables i /etc NIE są
#  dotykane. Wyjście z powłoki labu = wszystko znika (PID 1 przestrzeni ginie).
#
#  Topologia:
#
#     ┌─────────── client ──────────┐   ┌──────────── router ────────────┐   ┌─────────── server ──────────┐
#     │ c0  10.0.1.10/24            │───│ r-c 10.0.1.1/24  r-s 10.0.2.1/24│───│ s0  10.0.2.20/24            │
#     │ default via 10.0.1.1        │   │ ip_forward=1, dnsmasq (DNS .lab)│   │ default via 10.0.2.1        │
#     │ resolv.conf -> 10.0.1.1     │   │                                 │   │ HTTP :80 :8080, app :9000   │
#     └─────────────────────────────┘   └─────────────────────────────────┘   └─────────────────────────────┘
# =============================================================================

LAB=/run/lab
NS=(client router server)

nsx() { local n=$1; shift; ip netns exec "$n" "$@"; }

wait_port() {   # wait_port NS IP PORT  — czekaj aż usługa zacznie słuchać
  local i
  for i in $(seq 50); do
    nsx "$1" ss -Htln "src $2 and sport = :$3" 2>/dev/null | grep -q LISTEN && return 0
    sleep 0.1
  done
  echo "!! usługa $2:$3 w $1 nie wstała" >&2; return 1
}

build_lab() {
  mount -t tmpfs lab-run /run
  mkdir -p "$LAB/www" /run/netns
  head -c 400000 /dev/urandom > "$LAB/www/big.bin"
  echo "mały plik - ok" > "$LAB/www/small.txt"
  echo "<h1>app.lab działa</h1>" > "$LAB/www/index.html"

  # własne /etc/hosts i resolv.conf (bind mount tylko w przestrzeni labu)
  printf '127.0.0.1 localhost\n10.0.1.10 client.lab client\n10.0.1.1 router.lab router\n10.0.2.20 server.lab server\n' > "$LAB/hosts"
  printf 'nameserver 10.0.1.1\noptions timeout:1 attempts:2\n' > "$LAB/resolv.conf"
  mount --bind "$LAB/hosts" /etc/hosts
  mount --bind "$LAB/resolv.conf" /etc/resolv.conf

  local n
  for n in "${NS[@]}"; do ip netns add "$n"; ip -n "$n" link set lo up; done
  ip link add c0 netns client type veth peer name r-c netns router
  ip link add s0 netns server type veth peer name r-s netns router
  ip -n client addr add 10.0.1.10/24 dev c0
  ip -n router addr add 10.0.1.1/24  dev r-c
  ip -n router addr add 10.0.2.1/24  dev r-s
  ip -n server addr add 10.0.2.20/24 dev s0
  ip -n client link set c0 up; ip -n router link set r-c up
  ip -n router link set r-s up; ip -n server link set s0 up
  ip -n client route add default via 10.0.1.1
  ip -n server route add default via 10.0.2.1
  nsx router sysctl -qw net.ipv4.ip_forward=1

  start_dns
  start_web
}

start_dns() {
  # -d (debug) = bez forka i bez zmiany UID/GID — w user namespace setgroups() jest zabronione
  nsx router dnsmasq -d --conf-file=/dev/null --no-resolv --no-hosts --bind-interfaces \
      --listen-address=10.0.1.1 --address=/app.lab/10.0.2.20 --address=/server.lab/10.0.2.20 \
      --log-queries --pid-file= > "$LAB/dns.log" 2>&1 &
  wait_port router 10.0.1.1 53
}

start_web() {
  nsx server python3 -m http.server 80   --bind 10.0.2.20 --directory "$LAB/www" > "$LAB/web80.log" 2>&1 &
  nsx server python3 -m http.server 8080 --bind 10.0.2.20 --directory "$LAB/www" > "$LAB/web8080.log" 2>&1 &
  wait_port server 10.0.2.20 80 && wait_port server 10.0.2.20 8080
}

# Aplikacja na :9000, która przyjmuje połączenia powoli (scenariusz z backlogiem)
start_app() {
  [[ -f $LAB/app.pid ]] && kill "$(cat "$LAB/app.pid")" 2>/dev/null && sleep 0.3
  nsx server python3 "$LAB_DIR/tools/slow_app.py" 10.0.2.20 9000 > "$LAB/app.log" 2>&1 &
  echo $! > "$LAB/app.pid"
  wait_port server 10.0.2.20 9000
}

ok()   { printf '\e[1;32m  ✔ %s\e[0m\n' "$*"; }
fail() { printf '\e[1;31m  ✘ %s\e[0m\n' "$*"; }

# curl z klienta: 0 gdy CAŁA odpowiedź (2xx) dotarła w zadanym czasie
client_get() { nsx client curl -sf -o /dev/null -m "${2:-3}" "$1" 2>/dev/null; }
