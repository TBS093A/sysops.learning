#!/usr/bin/env bash
# =============================================================================
#  07 — nftables, conntrack, ufw/firewalld
# =============================================================================
#  nftables (nft) = następca iptables. Jedna komenda dla IPv4/IPv6/ARP/bridge,
#  zbiory (sets) i mapy zamiast setek reguł, atomowe ładowanie całego pliku.
#  conntrack = tablica śledzonych połączeń, na której opiera się stateful
#  firewall i NAT (zarówno iptables, jak i nft).
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "07 · NFTABLES + CONNTRACK" "nft list ruleset / sets / conntrack -L / limity"
need_sudo

# -----------------------------------------------------------------------------
section "1. nft list tables / ruleset"
flags "list ruleset" "wszystko" "list tables" "same tabele" "-a" "pokaż handle (do usuwania reguł)" \
      "-n" "numerycznie (bez nazw usług)" "-j" "JSON (do jq)" "-c" "sprawdź plik bez ładowania (nft -c -f plik)"
run "nft list tables" nft root | annotate \
  '^table ip ' 'table RODZINA NAZWA. Rodziny: ip (v4), ip6, inet (v4+v6 naraz!), arp, bridge, netdev (ingress)' \
  '^table inet' 'inet = jedna tabela dla IPv4 i IPv6 — zalecane dla firewalla hosta' \
  'table ip (filter|nat|mangle|raw)' 'tabele filter/nat/mangle/raw w rodzinie ip = utworzone przez iptables-nft (kompatybilność)'

run "nft -a list ruleset | head -60" nft root | annotate \
  '^table' 'table = kontener na łańcuchy (nazwa dowolna, w przeciwieństwie do iptables)' \
  'type filter hook (input|forward|output)' 'chain bazowy: type filter|nat|route, hook = miejsce w stosie (prerouting/input/forward/output/postrouting)||priority = kolejność względem innych tabel (niżej = wcześniej; filter=0, dstnat=-100, srcnat=100)||policy accept|drop = polityka domyślna' \
  'type nat hook' 'łańcuch NAT: dnat w prerouting/output, snat/masquerade w postrouting' \
  'ct state (established,related|related,established)' 'ct state established,related accept = to samo co conntrack RELATED,ESTABLISHED w iptables' \
  'ct state invalid' 'ct state invalid drop — odrzuć śmieci' \
  'counter packets' 'counter = licznik; w nft trzeba go jawnie dodać do reguły (iptables liczy zawsze)' \
  'xt (match|target)' 'xt match/target = reguła iptables-nft używa rozszerzenia x_tables, którego nft nie umie wyrazić natywnie' \
  'jump |goto ' 'jump = wywołaj łańcuch i wróć, goto = skocz bez powrotu' \
  '# handle [0-9]+' '# handle N = identyfikator reguły (flaga -a): nft delete rule inet filter input handle N' \
  ' set |@' 'set / @nazwa = zbiór adresów/portów — jedna reguła zamiast setek (ip saddr @blacklist drop)' \
  'masquerade' 'masquerade = SNAT na adres interfejsu wyjściowego' \
  'dnat to' 'dnat to IP:port = przekierowanie portu'

pause
# -----------------------------------------------------------------------------
section "2. Tłumaczenie iptables -> nft (bez zmieniania czegokolwiek)"
note "iptables-translate tylko DRUKUJE odpowiednik — nic nie ładuje"
run "iptables-translate -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -j ACCEPT; iptables-translate -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE; iptables-translate -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT" iptables-translate | annotate \
  'dport 22' 'nft add rule ip filter INPUT tcp dport 22 ct state new counter accept' \
  'masquerade' 'oifname = interfejs wyjściowy (w nft porównanie po nazwie)' \
  '\{ *80, *443 *\}' '{ 80, 443 } = anonimowy zbiór — natywna alternatywa dla -m multiport'
cheat <<'EOF'
# /etc/nftables.conf — minimalny firewall hosta (inet = IPv4 + IPv6 jednocześnie)
flush ruleset
table inet filter {
  set allowed_ssh { type ipv4_addr; flags interval; elements = { 10.0.0.0/8, 192.168.0.0/16 } }
  chain input {
    type filter hook input priority filter; policy drop;
    iif "lo" accept
    ct state established,related accept
    ct state invalid drop
    meta l4proto { icmp, ipv6-icmp } limit rate 10/second accept
    tcp dport 22 ip saddr @allowed_ssh ct state new accept
    tcp dport { 80, 443 } accept
    counter log prefix "nft-drop: " limit rate 5/minute
  }
  chain forward { type filter hook forward priority filter; policy drop; }
  chain output  { type filter hook output  priority filter; policy accept; }
}
# nft -c -f /etc/nftables.conf   (walidacja)   |   nft -f /etc/nftables.conf   (atomowe załadowanie)
# nft add element inet filter allowed_ssh { 172.16.0.0/12 }      # zmiana zbioru bez przeładowania
# nft monitor trace   + reguła z "meta nftrace set 1"            # śledzenie pakietu
EOF

pause
# -----------------------------------------------------------------------------
section "3. conntrack — tablica śledzonych połączeń"
note "Zapełnienie tablicy (czytelne bez roota, jeśli moduł nf_conntrack jest załadowany):"
run "for k in nf_conntrack_count nf_conntrack_max nf_conntrack_buckets nf_conntrack_tcp_timeout_established; do printf '%-42s %s\\n' \$k \"\$(cat /proc/sys/net/netfilter/\$k 2>/dev/null || echo '(brak — moduł nf_conntrack niezaładowany)')\"; done" | annotate \
  'nf_conntrack_count' 'count = ile połączeń jest teraz śledzonych' \
  'nf_conntrack_max' 'max = limit. Gdy count dobije do max, w dmesg pojawi się||"nf_conntrack: table full, dropping packet" — nowe połączenia giną. Typowe na LB/NAT/k8s nodach' \
  'tcp_timeout_established' 'timeout ESTABLISHED w s (domyślnie 432000 = 5 dni!). Martwe połączenia długo zajmują wpisy'
run "awk 'FNR==1{f=FILENAME} {v[f]=\$1} END{c=v[\"/proc/sys/net/netfilter/nf_conntrack_count\"]; m=v[\"/proc/sys/net/netfilter/nf_conntrack_max\"]; if (m) printf \"zajętość conntrack: %d / %d = %.2f%%\\n\", c, m, c/m*100}' /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null" | annotate \
  'zajętość' 'awk czyta 2 pliki naraz (FILENAME) i liczy procent. > 80% => podnieś nf_conntrack_max / skróć timeouty'

run "conntrack -L 2>/dev/null | head -15" conntrack root | annotate \
  '^tcp ' 'tcp 6 SEKUNDY_DO_WYGAŚNIĘCIA STAN src= dst= sport= dport= (kierunek oryginalny)||potem DRUGI zestaw src/dst = oczekiwana ODPOWIEDŹ (tu widać NAT: adresy różnią się od oryginału)' \
  '^udp ' 'udp 17 ... — UDP nie ma stanów, conntrack zgaduje "połączenie" po parze adres/port' \
  'ASSURED' '[ASSURED] = ruch widziany w obu kierunkach; takie wpisy nie są usuwane przy braku miejsca' \
  'UNREPLIED' '[UNREPLIED] = brak odpowiedzi (cel nie odpowiada / DROP po drodze / asymetryczny routing)' \
  'TIME_WAIT' 'stany TCP conntracka odpowiadają stanom gniazd (lekcja 05)' \
  'mark=' 'mark = connmark (iptables CONNMARK / nft ct mark)'
note "Fallback bez conntrack-tools: sudo cat /proc/net/nf_conntrack (to samo, inny format)"
run "conntrack -S 2>/dev/null | head -4" conntrack root | annotate \
  'insert_failed=[1-9]' 'insert_failed > 0 = wyścig przy wstawianiu (znany problem DNS/UDP w k8s — timeouty 5 s)' \
  'drop=[1-9]' 'drop > 0 = pakiety odrzucone, bo tablica pełna' \
  'cpu=' 'statystyki per CPU: found/invalid/insert/drop/early_drop/search_restart'
note "Rozkład stanów (awk: 4. pole to stan dla tcp):"
run "conntrack -L -p tcp 2>/dev/null | awk '{s[\$4]++} END{for (k in s) print s[k], k}' | sort -nr" conntrack root
cheat <<'EOF'
conntrack -L -d 10.0.0.5                    # połączenia do adresu
conntrack -L -p tcp --dport 443 -o extended
conntrack -E                                # zdarzenia na żywo (NEW/UPDATE/DESTROY)
conntrack -D -s 203.0.113.7                 # usuń wpisy (np. po zmianie NAT, żeby stare połączenia nie wisiały)
sysctl -w net.netfilter.nf_conntrack_max=262144
EOF

pause
# -----------------------------------------------------------------------------
section "4. Nakładki: ufw / firewalld (jeśli są w systemie)"
run "ufw status verbose" ufw root | annotate \
  'Status: inactive' 'ufw zainstalowany, ale wyłączony' \
  'Default:' 'Default: deny (incoming), allow (outgoing) = polityki łańcuchów' \
  'ALLOW' 'To / Action / From — reguły w składni ufw (ufw allow 22/tcp, ufw deny from 1.2.3.4)'
run "firewall-cmd --state; firewall-cmd --list-all" firewall-cmd root | annotate \
  'services:' 'firewalld: strefy (zones) z listą usług/portów. --permanent + --reload = zapis na stałe' \
  'interfaces:' 'interfejsy przypisane do strefy (public/internal/trusted...)'
note "ufw i firewalld GENERUJĄ reguły iptables/nft — nie edytuj ich równolegle ręcznie."
