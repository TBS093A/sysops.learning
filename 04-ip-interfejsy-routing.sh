#!/usr/bin/env bash
# =============================================================================
#  04 — Sieć L2/L3: ip link, ip addr, ip route, ip rule, ip neigh, ethtool, netns
# =============================================================================
#  iproute2 (ip, ss, tc, bridge) zastąpiło stare net-tools (ifconfig, route,
#  arp, netstat). Ściągawka mapowania jest na końcu lekcji.
#
#  Kolejność debugowania "nie ma sieci" (od dołu stosu):
#    L1/L2: ip link (UP? LOWER_UP? błędy?) , ethtool (link detected? speed?)
#    L3:    ip addr (jest adres?), ip route (jest default?), ip neigh (ARP bramy?)
#    L3+:   ip route get <cel> (którędy pójdzie pakiet?), ping bramy, ping 1.1.1.1
#    L4:    firewall (lekcje 06-07), ss (lekcja 05)
#    L7:    DNS (lekcja 08)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "04 · IP: INTERFEJSY I ROUTING" "ip link / addr / route / rule / neigh / ethtool"

# -----------------------------------------------------------------------------
section "1. ip -s link — stan interfejsów i liczniki błędów"
flags "-s" "statystyki (dwa razy -s -s = więcej szczegółów błędów)" \
      "-br" "brief: jedna linia na interfejs" \
      "-c" "kolory" "-d" "detale (typ: vlan, bridge, veth, vxlan, wireguard...)"
run "ip -s link" ip | annotate \
  '<LOOPBACK' 'lo = loopback (127.0.0.1). <FLAGI>: UP = włączony administracyjnie (ip link set X up)||LOWER_UP = jest sygnał w warstwie fizycznej. UP bez LOWER_UP = brak linku!' \
  'mtu [0-9]+ qdisc' 'mtu = max rozmiar ramki. Niezgodny MTU (VPN, VXLAN, jumbo) => połączenia "wiszą"||przy dużych pakietach. Test: ping -M do -s 1472 <cel>   (1472 + 28 nagłówka = 1500)||qdisc = dyscyplina kolejki (tc qdisc show); state = stan operacyjny' \
  'NO-CARRIER' 'NO-CARRIER + state DOWN: karta fizyczna => brak kabla / port switcha wyłączony / Wi-Fi rozłączone||bridge (docker0, br-*) => po prostu brak podłączonych portów (żaden kontener nie działa) — OK' \
  'link/ether' 'adres MAC; brd = adres rozgłoszeniowy L2 (ff:ff:ff:ff:ff:ff)' \
  'RX: +bytes' 'RX: errors = uszkodzone ramki (CRC => kabel/SFP), dropped = kernel odrzucił (bufory pełne,||nieznany protokół/VLAN), missed = karta nie zdążyła (ring buffer: ethtool -g/-G)' \
  'TX: +bytes' 'TX: carrier = utrata nośnej, collsns = kolizje (half-duplex! dziś nie powinno ich być)' \
  'master [a-z0-9-]+' 'master X = interfejs jest portem bridge X (Docker: docker0 / br-*)' \
  '@if[0-9]+' 'vethXXX@ifN = para wirtualna; drugi koniec (ifindex N) jest w innym namespace (kontener)' \
  'link-netnsid' 'link-netnsid = drugi koniec w innym network namespace: ip netns / nsenter -t PID -n ip a' \
  'link/none' 'link/none = interfejs L3 bez MAC: tun (OpenVPN) albo wireguard'

note "Wyłuskaj interfejsy z błędami/dropami (awk: zapamiętaj nazwę, sprawdź linię PO nagłówku RX/TX):"
run "ip -s link | awk '/^[0-9]+:/{i=\$2} /RX:|TX:/{d=\$1; getline; if (\$3+\$4 > 0) printf \"%-16s %s errors=%s dropped=%s\\n\", i, d, \$3, \$4}'" | annotate \
  'errors=' 'Interfejsy z niezerowymi błędami/dropami. dropped na RX bywa normalny (np. ramki IPv6/LLDP bez obsługi)'

run "ip -br -c=never addr" ip | annotate \
  ' UP ' '-br = 1 linia/interfejs: NAZWA STAN ADRESY' \
  'UNKNOWN' 'lo i tun/wg mają stan UNKNOWN — to normalne (brak warstwy fizycznej do sprawdzenia)' \
  'DOWN' 'DOWN = brak linku lub interfejs wyłączony'

pause
# -----------------------------------------------------------------------------
section "2. ip addr — adresy IP"
flags "-4 / -6" "tylko IPv4 / IPv6" "-o" "jedna linia na adres (idealne do awk/grep)" "show dev eth0" "tylko interfejs"
run "ip addr show" ip | annotate \
  'inet [0-9.]+/[0-9]+ brd' 'inet ADRES/PREFIKS: /24 = maska 255.255.255.0 (256 adresów, 254 hostów)||brd = broadcast podsieci; scope global = routowalny' \
  'inet 127\.' 'scope host = adres tylko lokalny (loopback)' \
  'dynamic' 'dynamic = z DHCP/SLAAC (valid_lft odlicza czas dzierżawy). Brak "dynamic" = statyczny' \
  'noprefixroute' 'noprefixroute = kernel nie dodaje sam trasy do podsieci — robi to menedżer sieci (NM/dhcpcd) z własną metryką' \
  'inet 169\.254\.' '169.254.0.0/16 = IPv4 link-local (APIPA/zeroconf) — zwykle znak, że DHCP NIE odpowiedział' \
  'inet 172\.(1[6-9]|2[0-9]|3[01])\.' '172.16.0.0/12, 10.0.0.0/8, 192.168.0.0/16 = adresy prywatne RFC 1918 (172.17.0.1 = docker0)' \
  'valid_lft forever' 'forever = adres statyczny, bez wygasania' \
  '/32 scope global' '/32 = pojedynczy adres (VIP keepalived, floating IP, kube-vip, WireGuard peer)' \
  'scope link' 'fe80::/10 = link-local IPv6, istnieje zawsze; działa tylko w obrębie segmentu L2' \
  'mngtmpaddr|temporary' 'mngtmpaddr/temporary = adresy IPv6 z SLAAC; temporary = prywatne, rotowane (RFC 4941)'

note "Wyłuskanie 'interfejs adres' z trybu -o (awk po kolumnach):"
run "ip -o -4 addr show | awk '{print \$2, \$4}'"
note "To samo sedem (grupy przechwytujące \\1 \\2):"
run "ip -o -4 addr | sed -E 's/^[0-9]+: ([^ ]+) +inet ([0-9./]+).*/\\1 => \\2/'"
note "Policz rozmiar podsieci z prefiksu (awk: 2^(32-prefix)):"
run "ip -o -4 addr | awk '{split(\$4,a,\"/\"); printf \"%-12s %-18s hostów: %d\\n\", \$2, \$4, (a[2]>=31 ? 2^(32-a[2]) : 2^(32-a[2])-2)}'"

pause
# -----------------------------------------------------------------------------
section "3. ip route — tablica routingu"
run "ip route show" ip | annotate \
  '^default via' 'default = 0.0.0.0/0 — brama ostateczności. via = next hop, dev = przez który interfejs||src = adres źródłowy; proto dhcp = wpisana przez klienta DHCP, proto static = ręcznie/konfig' \
  'metric [0-9]+' 'metric — przy kilku trasach do TEJ SAMEJ sieci wygrywa NIŻSZA metryka' \
  'proto kernel scope link' 'proto kernel scope link (bez via) = sieć bezpośrednio podłączona, dodana automatycznie||przy nadaniu adresu — host odpowiada przez ARP' \
  'proto (bird|bgp|zebra)' 'trasa wstrzyknięta przez demona routingu (BGP: Calico, MetalLB, FRR)' \
  'linkdown' 'linkdown = interfejs bez nośnej; trasa jest martwa (np. docker0 bez kontenerów)' \
  '^(blackhole|unreachable|prohibit)' 'blackhole = cicho wyrzucaj, unreachable/prohibit = odeślij ICMP'
note "Zasada wyboru trasy: NAJDŁUŻSZY PASUJĄCY PREFIKS (longest prefix match), dopiero potem metryka."

note "Którędy NAPRAWDĘ pójdzie pakiet? (kernel symuluje decyzję, uwzględnia reguły, metryki, src):"
run "ip route get 1.1.1.1" ip | annotate \
  ' via ' 'via = brama, dev = interfejs wyjściowy, src = adres źródłowy, uid = kto pyta' \
  'cache' 'Też: ip route get 8.8.8.8 from 10.0.0.5 iif eth0 mark 0x1  (z policy routingiem)'
run "ip route get 127.0.0.1" ip | annotate '^local' 'local = adres należy do tej maszyny — trafi do tablicy "local", przez lo'

note "Wszystkie tablice naraz (local, main, własne):"
run "ip route show table all | grep -vE '^(broadcast|local|anycast|multicast)' | head -20" ip | annotate \
  'table [a-z0-9]+' 'table X = trasa w innej tablicy niż main — patrz ip rule (sekcja 4)'

cheat <<'EOF'
ip route add 10.20.0.0/16 via 192.168.1.254 dev eth0       # dodaj trasę
ip route replace default via 192.168.1.1                   # podmień (add or change)
ip route del 10.20.0.0/16
ip route add blackhole 203.0.113.0/24                      # "null route" atakującej sieci
trwałość: netplan / systemd-networkd / NetworkManager / ifupdown — lekcja 09
EOF

pause
# -----------------------------------------------------------------------------
section "4. ip rule — policy routing (wiele tablic routingu)"
run "ip rule show" ip | annotate \
  'lookup local' 'Reguły czytane od najniższego numeru. Tablica "local" = adresy lokalne i broadcast' \
  'lookup main' 'main = to, co pokazuje zwykłe "ip route"' \
  'lookup default' 'default = pusta tablica-zapas (historyczna)' \
  'fwmark' 'fwmark = pakiety oznaczone przez iptables/nft (-j MARK) lub WireGuard/Tailscale idą inną tablicą' \
  'from [0-9]' 'from ADRES = ruch z danego źródła idzie inną tablicą (multi-homing, VPN split)'
run "cat /etc/iproute2/rt_tables 2>/dev/null || cat /usr/share/iproute2/rt_tables" | annotate \
  '^255' 'Nazwy tablic (numer nazwa). Własna: echo "100 vpn" >> /etc/iproute2/rt_tables'

pause
# -----------------------------------------------------------------------------
section "5. ip neigh — tablica ARP / NDP (sąsiedzi L2)"
run "ip neigh show" ip | annotate \
  'REACHABLE' 'REACHABLE = potwierdzony niedawno. Brama musi tu być, inaczej nic nie wyjdzie poza LAN' \
  'STALE' 'STALE = wpis stary, zostanie zweryfikowany przy następnym użyciu — normalne' \
  'DELAY|PROBE' 'DELAY/PROBE = kernel właśnie weryfikuje sąsiada' \
  'FAILED|INCOMPLETE' 'FAILED/INCOMPLETE = nikt nie odpowiedział na ARP => host down, zły VLAN, firewall L2,||albo duplikat IP. Test: arping -I eth0 <IP>' \
  'PERMANENT' 'PERMANENT = wpis statyczny (ip neigh add ... nud permanent)' \
  ' router ' 'router = sąsiad ogłasza się jako router IPv6 (Router Advertisement)'
GW=$(ip route show default 2>/dev/null | awk '/via/{print $3; exit}')
note "Twoja brama domyślna (awk z 'ip route show default'): ${GW:-brak}"
[[ -n "$GW" ]] && run "ip neigh show $GW; ping -c 2 -W 1 $GW" ping | annotate \
  'lladdr' 'Brama ma MAC w tablicy ARP => L2 do bramy działa' \
  'bytes from' 'Brama odpowiada na ICMP => L3 w LAN działa. Teraz ping 1.1.1.1, potem DNS' \
  '100% packet loss' '100% strat do bramy: zły VLAN/kabel/Wi-Fi, albo brama blokuje ICMP (sprawdź ARP)'

pause
# -----------------------------------------------------------------------------
section "6. ethtool — warstwa fizyczna karty"
IFACE=$(ip -o route get 1.1.1.1 2>/dev/null | sed -nE 's/.* dev ([^ ]+).*/\1/p')
note "Interfejs wyjściowy do internetu (sed wyciąga słowo po 'dev'): ${IFACE:-?}"
run "ethtool ${IFACE:-eth0} 2>&1 | grep -E 'Speed|Duplex|Auto-neg|Link detected|Port:'" ethtool | annotate \
  'Speed' 'Speed niższa niż oczekiwana (100 zamiast 1000) => zły kabel/port. Unknown! = wirtualka/Wi-Fi' \
  'Duplex' 'Duplex: Half => duplex mismatch, kolizje i straty' \
  'Link detected' 'Link detected: no = L1 leży (kabel, SFP, port)'
run "ethtool -i ${IFACE:-eth0}" ethtool | annotate '^driver' 'driver/version/firmware — przy dziwnych błędach szukaj znanych bugów sterownika'
run "ethtool -S ${IFACE:-eth0} 2>&1 | grep -iE 'err|drop|miss|fifo' | awk '\$2 != 0' | head" ethtool | annotate \
  ':' 'Niezerowe liczniki błędów sterownika (dokładniejsze niż ip -s). Brak linii = brak błędów'
cheat <<'EOF'
ethtool -g eth0 / -G eth0 rx 4096        # ring buffer (missed/rx_dropped przy dużym ruchu)
ethtool -k eth0                          # offloady (TSO/GRO/checksum) — czasem psują tcpdump/VPN
ethtool -K eth0 gro off                  # wyłącz offload
EOF

pause
# -----------------------------------------------------------------------------
section "7. Network namespaces i bridge (Docker / k8s pod spodem)"
run "ip netns list" ip | annotate '.' 'nazwane namespace (ip netns add). Docker NIE rejestruje ich tu — użyj nsenter'
run "bridge link show" bridge | annotate \
  'master' 'porty bridge: vethXXX master docker0 = kontener podpięty do bridge Dockera' \
  'state forwarding' 'forwarding = port przekazuje ruch (STP ok); blocking/disabled = nie'
run "ip -d link show type bridge" ip | annotate 'bridge forward_delay' 'parametry bridge: stp_state, forward_delay, vlan_filtering...'
note "Wejście w sieć kontenera:  nsenter -t \$(docker inspect -f '{{.State.Pid}}' NAZWA) -n ip a"

pause
# -----------------------------------------------------------------------------
section "8. Ściągawka: net-tools (stare) -> iproute2 (nowe)"
cheat <<'EOF'
ifconfig                    -> ip addr / ip -s link
ifconfig eth0 up            -> ip link set eth0 up
ifconfig eth0 1.2.3.4/24    -> ip addr add 1.2.3.4/24 dev eth0
route -n                    -> ip route
route add default gw X      -> ip route add default via X
arp -an                     -> ip neigh
netstat -tulpn              -> ss -tulpn
netstat -i                  -> ip -s link
netstat -s                  -> nstat -az
brctl show                  -> bridge link / ip link show master br0
vconfig add eth0 100        -> ip link add link eth0 name eth0.100 type vlan id 100
EOF
