#!/usr/bin/env bash
# =============================================================================
#  16 — tc / netem: symulacja złej sieci i jak ją widać w narzędziach
# =============================================================================
#  Lekcja buduje DWA wirtualne hosty (klient 10.9.0.1 <-> serwer 10.9.0.2)
#  w osobnych przestrzeniach nazw (unshare, BEZ roota) i po kolei psuje łącze:
#  opóźnienie, jitter, straty, limit przepustowości. Po każdym kroku mierzy
#  tymi samymi narzędziami (ping, curl -w, ss -ti, tc -s) — widzisz, jak dana
#  usterka wygląda "od środka". Twoja prawdziwa sieć nie jest dotykana.
# =============================================================================
D="$(cd "$(dirname "$0")" && pwd)"
if [[ -z "${NETEM_INNER:-}" ]]; then
  userns=(--user --map-root-user); [[ $EUID -eq 0 ]] && userns=()
  exec unshare "${userns[@]}" --net --mount --pid --fork --mount-proc --propagation private \
       env NETEM_INNER=1 bash "$0" "$@"
fi
source "$D/lib/common.sh"

lesson_header "16 · TC NETEM" "opóźnienie / jitter / straty / limit pasma — i jak to wygląda w pomiarach"

# --- budowa: dwa hosty połączone kablem veth ---------------------------------
mount -t tmpfs netem-run /run; mkdir -p /run/netns /run/www
head -c 2000000 /dev/urandom > /run/www/2MB.bin
printf '127.0.0.1 localhost\n10.9.0.2 serwer\n' > /run/hosts; mount --bind /run/hosts /etc/hosts
printf 'nameserver 127.0.0.1\n' > /run/resolv.conf; mount --bind /run/resolv.conf /etc/resolv.conf
for n in klient serwer; do ip netns add $n; ip -n $n link set lo up; done
ip link add eth0 netns klient type veth peer name eth0 netns serwer
ip -n klient addr add 10.9.0.1/24 dev eth0; ip -n serwer addr add 10.9.0.2/24 dev eth0
ip -n klient link set eth0 up; ip -n serwer link set eth0 up
ip netns exec serwer python3 -m http.server 80 --bind 10.9.0.2 --directory /run/www >/dev/null 2>&1 &
for _ in $(seq 50); do ip netns exec serwer ss -Htln 'sport = :80' | grep -q LISTEN && break; sleep 0.1; done

K="ip netns exec klient"; S="ip netns exec serwer"
note "Topologia: [klient eth0 10.9.0.1] ──veth── [serwer eth0 10.9.0.2], serwer ma HTTP z plikiem 2MB.bin"

measure() {
  run "$K ping -c 10 -i 0.2 -W 2 10.9.0.2 | tail -2" ping | annotate \
    'packet loss' 'transmitted / received / % strat' \
    'rtt' 'min/avg/max/mdev — mdev = jitter (rozrzut)'
  run "$K curl -s -o /dev/null -m 60 -w 'tcp_connect=%{time_connect}s  TTFB=%{time_starttransfer}s  total=%{time_total}s  speed=%{speed_download}B/s\n' http://10.9.0.2/2MB.bin" curl | annotate \
    'tcp_connect' 'tcp_connect ≈ 1 RTT (handshake). TTFB ≈ 2 RTT. total i speed = ile trwał transfer 2 MB'
}

# -----------------------------------------------------------------------------
section "1. Punkt odniesienia — łącze bez zakłóceń"
run "$K tc qdisc show dev eth0" tc | annotate \
  'noqueue' 'noqueue = interfejs wirtualny bez kolejki (veth). Fizyczne karty mają zwykle fq_codel / mq / pfifo_fast'
measure
pause

# -----------------------------------------------------------------------------
section "2. Opóźnienie 100 ms (jak łącze międzykontynentalne)"
note "netem działa na ruchu WYCHODZĄCYM interfejsu. Dajemy 50 ms po każdej stronie = 100 ms RTT."
run "$K tc qdisc add dev eth0 root netem delay 50ms; $S tc qdisc add dev eth0 root netem delay 50ms" tc
measure
note "Zauważ: przepustowość spada, choć nic nie gubimy — TCP potrzebuje wielu RTT na rozpędzenie okna (cwnd)."
note "Bandwidth-Delay Product: aby wysycić 1 Gbit/s przy 100 ms, w locie musi być 12,5 MB -> bufory tcp_rmem/wmem!"
pause

# -----------------------------------------------------------------------------
section "3. Jitter: 100 ms ± 40 ms"
run "$K tc qdisc change dev eth0 root netem delay 50ms 20ms; $S tc qdisc change dev eth0 root netem delay 50ms 20ms; $K tc qdisc show dev eth0" tc | annotate 'delay 50ms  20ms' 'delay ŚREDNIA ROZRZUT — netem losuje opóźnienie każdego pakietu (domyślnie może zmieniać kolejność!)'
run "$K ping -c 10 -i 0.2 -W 2 10.9.0.2" ping | annotate \
  'icmp_seq=1 ' 'Kolejne time= skaczą — to jitter. Dla VoIP/wideo/gier jitter boli bardziej niż stałe opóźnienie' \
  'mdev' 'mdev duże = niestabilne łącze (Wi-Fi, przeciążony uplink, bufferbloat)'
pause

# -----------------------------------------------------------------------------
section "4. Straty 5% — co robi TCP"
run "$K tc qdisc change dev eth0 root netem delay 10ms loss 5%; $S tc qdisc change dev eth0 root netem delay 10ms loss 5%; $K tc qdisc show dev eth0" tc
measure
note "Wnętrze połączenia W TRAKCIE pobierania, od strony SERWERA (to on wysyła dane, więc on retransmituje):"
run "$K curl -s -o /dev/null -m 30 http://10.9.0.2/2MB.bin & sleep 1.5; $S ss -tin src 10.9.0.2; wait" ss | annotate \
  'rtt:' 'rtt — rośnie przy stratach, bo retransmisje wydłużają potwierdzenia' \
  'retrans:' 'retrans:aktualne/łączne + bytes_retrans — tak wyglądają straty od strony gniazda' \
  'cwnd:' 'cwnd małe — algorytm CC (cubic) zmniejsza okno po każdej stracie => niska przepustowość' \
  'lost:' 'lost = segmenty uznane za zgubione'
run "$S nstat -az TcpRetransSegs TcpOutSegs TcpExtTCPLostRetransmit TcpExtTCPTimeouts" nstat | annotate \
  'TcpRetransSegs' 'Retransmisje / wysłane segmenty = % strat widziany przez TCP (porównaj z 5% netem)' \
  'TCPTimeouts' 'TCPTimeouts = straty, których nie wykrył fast retransmit — czekanie na RTO (bolesne)'
pause

# -----------------------------------------------------------------------------
section "5. Limit pasma 2 Mbit/s (tbf) + bufferbloat"
run "$K tc qdisc del dev eth0 root; $S tc qdisc del dev eth0 root; $S tc qdisc add dev eth0 root tbf rate 2mbit burst 32kbit latency 400ms" tc
note "Ping w trakcie pobierania — kolejka na serwerze się zapycha, opóźnienie rośnie (bufferbloat):"
run "$K bash -c 'curl -s -o /dev/null -m 20 http://10.9.0.2/2MB.bin & sleep 0.5; ping -c 6 -i 0.5 10.9.0.2 | grep -E \"time=|rtt\"; wait'" ping | annotate \
  'time=' 'RTT bez obciążenia ~0,05 ms, pod obciążeniem setki ms: pakiety pingu czekają w pełnej kolejce tbf.||Lekarstwo: AQM (fq_codel, cake) zamiast wielkich buforów FIFO'
run "$S tc -s qdisc show dev eth0" tc | annotate \
  'tbf' 'tbf rate = limit, burst = ile może wyjść "naraz", latency = max czas w kolejce (reszta jest wyrzucana)' \
  'Sent' 'Sent bajty/pakiety, dropped = wyrzucone przez kolejkę, overlimits = ile razy limit zadziałał,||requeues = ponowne kolejkowanie (sterownik zajęty)' \
  'backlog' 'backlog = ile bajtów/pakietów aktualnie czeka w kolejce — duży = bufferbloat'

pause
# -----------------------------------------------------------------------------
section "6. Ściągawka tc / netem"
cheat <<'EOF'
tc qdisc show                                    # kolejki wszystkich interfejsów
tc -s qdisc show dev eth0                        # + statystyki: dropped, overlimits, backlog
tc qdisc add dev eth0 root netem delay 100ms 20ms distribution normal
tc qdisc add dev eth0 root netem loss 2% 25%     # straty z korelacją (seriami)
tc qdisc add dev eth0 root netem duplicate 1% corrupt 0.1% reorder 25% 50%
tc qdisc change dev eth0 root netem delay 200ms  # zmiana w locie
tc qdisc del dev eth0 root                       # USUŃ — zapomniany netem = awaria (lab scenariusz 7)
# netem tylko dla jednego celu: prio + filtr
tc qdisc add dev eth0 root handle 1: prio
tc qdisc add dev eth0 parent 1:3 handle 30: netem delay 300ms
tc filter add dev eth0 parent 1: protocol ip u32 match ip dst 10.0.0.5/32 flowid 1:3
# ruch PRZYCHODZĄCY: netem tylko na egress -> przekieruj ingress do ifb0
modprobe ifb; ip link set ifb0 up
tc qdisc add dev eth0 handle ffff: ingress
tc filter add dev eth0 parent ffff: matchall action mirred egress redirect dev ifb0
tc qdisc add dev ifb0 root netem delay 100ms
EOF
note "Koniec — przestrzenie nazw lekcji znikają razem ze skryptem."
