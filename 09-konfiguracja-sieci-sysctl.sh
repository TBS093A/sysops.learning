#!/usr/bin/env bash
# =============================================================================
#  09 — Konfiguracja sieci: kto zarządza siecią, pliki konfiguracyjne, sysctl
# =============================================================================
#  "ip addr add" działa do restartu. Trwałą konfigurację trzyma JEDEN z:
#    NetworkManager (nmcli)       – desktopy, RHEL/Fedora
#    systemd-networkd (.network)  – serwery, kontenery, Arch
#    netplan (YAML)               – Ubuntu: generuje config dla networkd/NM
#    ifupdown (/etc/network/interfaces) – Debian klasycznie
#    ifcfg (/etc/sysconfig/network-scripts) – stare RHEL/CentOS
#    dhcpcd / wpa_supplicant      – Void, Raspberry Pi OS, minimalne systemy
#  Ta lekcja wykrywa, co działa u Ciebie, i pokazuje TWOJE pliki.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "09 · KONFIGURACJA SIECI + SYSCTL" "kto zarządza siecią / pliki / parametry kernela"
need_sudo

# Pokazuje plik konfiguracyjny bez komentarzy i pustych linii.
showconf() { run "grep -vE '^[[:space:]]*(#|;|\$)' $1" "" "${2:-}"; }

# -----------------------------------------------------------------------------
section "1. Kto zarządza siecią na tym hoście?"
run "ps -eo comm= | grep -xE 'NetworkManager|systemd-network|systemd-resolve|dhcpcd|dhclient|wpa_supplicant|iwd|connmand|dnsmasq|resolvconf|netplan' | sort | uniq -c" | annotate \
  'NetworkManager' 'NetworkManager -> konfiguracja: nmcli / /etc/NetworkManager/system-connections/*.nmconnection' \
  'systemd-network' 'systemd-networkd -> /etc/systemd/network/*.network|.netdev|.link, stan: networkctl' \
  'systemd-resolve' 'systemd-resolved -> resolvectl status, /etc/systemd/resolved.conf' \
  'dhcpcd' 'dhcpcd = klient DHCP (+ IPv6 RA). Konfiguracja: /etc/dhcpcd.conf; on też pisze resolv.conf' \
  'dhclient' 'dhclient = klient DHCP ISC (ifupdown). Dzierżawy: /var/lib/dhcp/' \
  'wpa_supplicant' 'wpa_supplicant = uwierzytelnianie Wi-Fi/802.1X: /etc/wpa_supplicant/*.conf, wpa_cli status' \
  'iwd' 'iwd = nowszy demon Wi-Fi (iwctl)' \
  'dnsmasq' 'dnsmasq = lokalny DNS/DHCP (libvirt, NM, Pi-hole)'
for d in /etc/netplan /etc/systemd/network /etc/NetworkManager/system-connections /etc/network /etc/sysconfig/network-scripts /etc/dhcpcd.conf /etc/wpa_supplicant; do
  [[ -e $d ]] && note "istnieje: $d"
done

pause
# -----------------------------------------------------------------------------
section "2. Twoje pliki konfiguracyjne sieci"
[[ -f /etc/dhcpcd.conf ]] && showconf /etc/dhcpcd.conf | annotate \
  '^hostname' 'hostname = wyślij nazwę hosta do serwera DHCP' \
  '^option' 'option X = poproś serwer DHCP o opcję (domain_name_servers, ntp_servers, interface_mtu...)' \
  '^interface' 'interface X = sekcja dla interfejsu; poniżej np. static ip_address=10.0.0.5/24, static routers=' \
  '^static' 'static = adres/brama/DNS na sztywno zamiast DHCP' \
  '^slaac' 'slaac private = adresy IPv6 prywatne (RFC 4941) zamiast z MAC' \
  '^nohook' 'nohook X = nie uruchamiaj hooka (np. nohook resolv.conf = nie nadpisuj DNS)' \
  '^denyinterfaces|^allowinterfaces' 'deny/allowinterfaces = których interfejsów NIE / wyłącznie dotykać (veth*, docker*)'
for f in /etc/netplan/*.yaml; do [[ -f $f ]] && showconf "$f" root | annotate \
  'renderer' 'renderer: networkd | NetworkManager — kto faktycznie zastosuje config' \
  'dhcp4' 'dhcp4: true/false' \
  'addresses' 'addresses: [10.0.0.5/24] statycznie; routes: - to: default via: 10.0.0.1' \
  'nameservers' 'nameservers: addresses: [...] search: [...]'; done
note "netplan: 'netplan try' = zastosuj z auto-rollbackiem po 120 s (bezpieczne przez SSH), 'netplan apply'"
for f in /etc/systemd/network/*.network; do [[ -f $f ]] && showconf "$f" | annotate \
  '^\[Match\]' '[Match] Name=eth0 / MACAddress= — do którego interfejsu' \
  '^\[Network\]' '[Network] DHCP=yes | Address=10.0.0.5/24, Gateway=, DNS=, VLAN=, Bridge=' \
  '^\[Route\]' '[Route] Destination=, Gateway=, Metric=, Table='; done
[[ -f /etc/network/interfaces ]] && showconf /etc/network/interfaces | annotate \
  '^auto' 'auto X = podnieś przy starcie (ifup -a). allow-hotplug = gdy urządzenie się pojawi' \
  '^iface .* inet dhcp' 'iface X inet dhcp = DHCP' \
  '^iface .* inet static' 'iface X inet static + address/netmask/gateway — statycznie' \
  '^source' 'source /etc/network/interfaces.d/* — dołączanie plików'
if have nmcli; then
  run "nmcli -f NAME,TYPE,DEVICE,AUTOCONNECT connection show" nmcli | annotate 'DEVICE' 'profile NM; szczegóły: nmcli -f ipv4 connection show NAZWA'
  run "nmcli device status" nmcli | annotate 'unmanaged' 'unmanaged = NM nie dotyka tego interfejsu (docker, veth, lub ustawione w configu)'
fi
have networkctl && run "networkctl list" networkctl | annotate 'configured' 'configured = networkd zastosował .network; unmanaged = brak pasującego pliku'
have resolvectl && run "resolvectl status | head -25" resolvectl | annotate 'Current DNS Server' 'faktycznie używany serwer DNS per interfejs' 'DNS Domain' 'domeny routowane do tego interfejsu (split DNS przy VPN)'

cheat <<'EOF'
# --- netplan (/etc/netplan/01-net.yaml) ---------------------------
network:
  version: 2
  ethernets:
    eth0:
      addresses: [10.0.0.5/24]
      routes: [{ to: default, via: 10.0.0.1 }]
      nameservers: { addresses: [1.1.1.1, 9.9.9.9] }
  vlans:
    vlan100: { id: 100, link: eth0, addresses: [10.100.0.5/24] }
# --- systemd-networkd (/etc/systemd/network/10-eth0.network) ------
[Match]
Name=eth0
[Network]
Address=10.0.0.5/24
Gateway=10.0.0.1
DNS=1.1.1.1
# --- nmcli: statyczny adres -----------------------------------------
nmcli con mod eth0 ipv4.method manual ipv4.addresses 10.0.0.5/24 ipv4.gateway 10.0.0.1 ipv4.dns 1.1.1.1
nmcli con up eth0
EOF

pause
# -----------------------------------------------------------------------------
section "3. Hostname i /etc/hosts"
run "hostname; hostname -f 2>/dev/null; cat /etc/hostname 2>/dev/null" | annotate \
  '\.' 'hostname -f = FQDN (z /etc/hosts lub DNS). Brak FQDN psuje część usług (Kerberos, poczta)'

pause
# -----------------------------------------------------------------------------
section "4. sysctl — sieciowe parametry kernela (TWOJE aktualne wartości)"
note "sysctl czyta /proc/sys: net.ipv4.ip_forward == /proc/sys/net/ipv4/ip_forward"
run "sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.conf.all.rp_filter net.ipv4.conf.default.rp_filter net.ipv4.tcp_syncookies net.core.somaxconn net.ipv4.tcp_max_syn_backlog net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout net.ipv4.tcp_keepalive_time net.ipv4.tcp_congestion_control net.core.default_qdisc net.core.rmem_max net.core.wmem_max net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.icmp_echo_ignore_all net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv6.conf.all.disable_ipv6 net.netfilter.nf_conntrack_max net.bridge.bridge-nf-call-iptables 2>&1" sysctl | annotate \
  'ip_forward = 1' 'ip_forward=1 = host ROUTUJE pakiety między interfejsami (wymagane dla Dockera, k8s, VPN, NAT)' \
  'ip_forward = 0' 'ip_forward=0 = host nie przekazuje pakietów (zwykły serwer/desktop)' \
  'rp_filter' 'rp_filter: 0=wył, 1=strict (pakiet musi przyjść interfejsem, którym byśmy odpowiedzieli),||2=loose. Strict + asymetryczny routing/multi-homing = pakiety cicho giną!' \
  'tcp_syncookies' 'tcp_syncookies=1 = ochrona przed SYN flood, gdy backlog SYN pełny' \
  'somaxconn' 'somaxconn = górny limit backlogu listen() (lekcja 05: Recv-Q/Send-Q na LISTEN)' \
  'tcp_max_syn_backlog' 'kolejka półotwartych połączeń (SYN-RECV)' \
  'ip_local_port_range' 'zakres portów efemerycznych (źródłowych dla połączeń wychodzących). Mało portów + dużo||TIME-WAIT do jednego celu = "Cannot assign requested address"' \
  'tcp_tw_reuse' 'tcp_tw_reuse: 1 = reużyj TIME-WAIT dla nowych połączeń wychodzących, 2 = tylko loopback (domyślne)' \
  'tcp_fin_timeout' 'ile s trzymać FIN-WAIT-2' \
  'tcp_keepalive_time' 'po ilu s ciszy wysłać keepalive (7200 = 2h!). Firewalle/NAT zrywają bezczynne połączenia wcześniej' \
  'tcp_congestion_control' 'algorytm CC: cubic (domyślny) / bbr (lepszy na długich, stratnych łączach + qdisc fq)' \
  'default_qdisc' 'domyślna kolejka interfejsów: fq_codel / fq (dla bbr) / pfifo_fast (stara)' \
  'rmem_max|wmem_max' 'max bufory gniazd w bajtach. tcp_rmem/wmem = min domyślny max (autotuning)' \
  'icmp_echo_ignore_all' '1 = host nie odpowiada na ping' \
  'accept_redirects' 'accept_redirects=0 na serwerach (ICMP redirect potrafi zmienić routing — ryzyko)' \
  'disable_ipv6' 'disable_ipv6 = 1 => IPv6 wyłączone' \
  'bridge-nf-call-iptables' 'bridge-nf-call-iptables=1 = ruch przez bridge przechodzi przez iptables (wymagane w k8s)||"cannot stat" => moduł br_netfilter niezaładowany' \
  'cannot stat|No such file' 'klucz nie istnieje = moduł jądra niezaładowany (nf_conntrack, br_netfilter) lub inna wersja kernela'
note "Skąd pochodzi wartość? Pliki ładowane przy starcie (sysctl --system), późniejszy wygrywa:"
run "grep -rsHvE '^[[:space:]]*(#|;|\$)' /etc/sysctl.conf /etc/sysctl.d/ /run/sysctl.d/ /usr/lib/sysctl.d/ /usr/local/lib/sysctl.d/ | head -25" | annotate \
  '^/etc/sysctl.d' '/etc/sysctl.d/*.conf = TWOJE ustawienia (np. 99-custom.conf). Nadpisują /usr/lib/sysctl.d (pakiety)' \
  '^/usr/lib/sysctl.d' 'ustawienia z pakietów — nie edytuj, nadpisz w /etc/sysctl.d z tą samą nazwą pliku'
note "Różnice między wartością w kernelu a plikami (awk porównuje dwie listy):"
run "grep -rshvE '^[[:space:]]*(#|;|\$)' /etc/sysctl.conf /etc/sysctl.d/ /usr/lib/sysctl.d/ 2>/dev/null | sed -E 's/^-//; s/[[:space:]]*=[[:space:]]*/=/' | awk -F= '!/\\*/{cmd=\"sysctl -n \" \$1 \" 2>/dev/null\"; cmd | getline cur; close(cmd); gsub(/[[:space:]]+/, \" \", cur); if (cur != \$2) printf \"%-45s plik=%-12s kernel=%s\\n\", \$1, \$2, cur; cur=\"\"}' | head -15" sysctl | annotate \
  'kernel=' 'Różnica = ktoś zmienił w locie (sysctl -w, Docker, k8s, VPN) albo nadpisuje późniejszy plik'
cheat <<'EOF'
sysctl -w net.ipv4.ip_forward=1                         # w locie (do restartu)
echo 'net.ipv4.ip_forward = 1' > /etc/sysctl.d/99-forward.conf && sysctl --system   # na stałe
EOF
