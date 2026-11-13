#!/usr/bin/env bash
# =============================================================================
#  05 — Gniazda i połączenia: ss (następca netstat), stany TCP, nstat
# =============================================================================
#  Pytania:
#    * czy usługa w ogóle słucha? na jakim adresie?   -> ss -tlnp
#    * kto łączy się do mnie / ile połączeń?         -> ss -tn state established
#    * "connection refused"?                         -> nic nie słucha / firewall REJECT
#    * "timeout"?                                    -> firewall DROP / routing / pełny backlog
#    * TIME_WAIT/CLOSE_WAIT w tysiącach?             -> sekcja 3
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "05 · GNIAZDA: ss" "ss -tulpn / stany TCP / filtry / ss -ti / nstat"
need_sudo

# -----------------------------------------------------------------------------
section "1. ss -tulpn — co słucha na porcie"
flags "-t / -u" "TCP / UDP" "-l" "tylko gniazda nasłuchujące (LISTEN)" \
      "-p" "pokaż proces (cudze procesy widać tylko jako root -> sudo)" "-n" "liczby zamiast nazw (bez DNS i /etc/services)" \
      "-4 / -6" "rodzina adresów" "-x" "gniazda unix" "-e" "rozszerzone (uid, inode)"
run "ss -tulpn" ss root | annotate \
  '^Netid' 'Recv-Q/Send-Q mają INNE znaczenie dla LISTEN i dla ESTAB:||  LISTEN: Recv-Q = połączenia czekające na accept(), Send-Q = rozmiar backlogu||  ESTAB:  Recv-Q = bajty nieodczytane przez aplikację, Send-Q = bajty niepotwierdzone przez peer' \
  'UNCONN' 'UNCONN = UDP nie ma połączeń; to "słuchające" gniazdo UDP' \
  '%[a-z0-9]+:' '%iface = gniazdo przypięte do interfejsu (SO_BINDTODEVICE / adres link-local)' \
  ' 0\.0\.0\.0:[0-9]+ ' '0.0.0.0 = wszystkie adresy IPv4 — dostępne z sieci (jeśli firewall pozwoli)' \
  ' 127\.0\.0\.[0-9]+:[0-9]+ ' '127.x = TYLKO lokalnie. Klasyk: "baza nie odpowiada z zewnątrz" => bind/listen_addresses' \
  ' (\*|\[::\]):[0-9]+ ' '* lub [::] = wszystkie adresy (zwykle dual-stack IPv4+IPv6, zależnie od net.ipv6.bindv6only)' \
  'users:' 'users:(("nazwa",pid=,fd=)) — który proces i który deskryptor' \
  'docker-proxy' 'docker-proxy = userland proxy Dockera dla -p HOST:KONTENER (obok reguł DNAT w iptables)'

note "Backlog pełny? awk porównuje Recv-Q (kolumna 2) z Send-Q (3) dla LISTEN (bez -u nie ma kolumny Netid):"
run "ss -tln | awk 'NR>1 && \$1==\"LISTEN\" {printf \"%-28s queue=%s/%s %s\\n\", \$4, \$2, \$3, (\$2>0 ? \"<-- czeka na accept()\" : \"ok\")}'" ss | annotate \
  'czeka na accept' 'Recv-Q > 0 na LISTEN = aplikacja nie nadąża przyjmować. Recv-Q >= Send-Q => SYN-y odrzucane!||Limit = min(backlog z listen(), net.core.somaxconn)' \
  ' ok$' 'kolejka pusta — aplikacja przyjmuje połączenia na bieżąco'

note "Filtr w samym ss (szybszy i dokładniejszy niż grep):"
run "ss -tln 'sport = :22 or sport = :443'" ss

pause
# -----------------------------------------------------------------------------
section "2. Połączenia aktywne i filtry ss"
run "ss -tnp state established | head -15" ss root | annotate \
  'Recv-Q' 'Przy filtrze state kolumny State nie ma. Local = my, Peer = druga strona' \
  ':443 ' 'port 443 = HTTPS; ephemeral port po naszej stronie = MY jesteśmy klientem' \
  ':22 ' 'port 22 = SSH'
cheat <<'EOF'
ss -tn state established '( dport = :443 or sport = :443 )'
ss -tn dst 10.0.0.0/8
ss -tn 'sport > :1024 and dport = :5432'
ss -tnp | grep -w 'pid=2210'                    # połączenia procesu
ss -K dst 10.1.2.3 dport = 5432                 # ZABIJ gniazda (root)
EOF

pause
# -----------------------------------------------------------------------------
section "3. Rozkład stanów TCP — awk grupuje po kolumnie State"
run "ss -tan | awk 'NR>1 {c[\$1]++} END {for (s in c) printf \"%-12s %d\\n\", s, c[s]}' | sort -k2 -nr" ss | annotate \
  '^ESTAB' 'ESTAB = połączenie nawiązane, dane mogą płynąć' \
  '^LISTEN' 'LISTEN = gniazda nasłuchujące' \
  '^TIME-WAIT' 'TIME-WAIT = strona, która zamknęła PIERWSZA, czeka 2*MSL (60 s w Linuksie).||Tysiące to zwykle OK. Problem gdy kończą się porty efemeryczne (ip_local_port_range)||=> keep-alive / connection pooling, net.ipv4.tcp_tw_reuse=1' \
  '^CLOSE-WAIT' 'CLOSE-WAIT = peer zamknął, a NASZA aplikacja nie wywołała close()!||Rośnie => BUG/leak w aplikacji. Kernel tego nie posprząta.' \
  '^SYN-SENT' 'SYN-SENT = wysłaliśmy SYN, brak odpowiedzi => cel nie odpowiada / firewall DROP po drodze' \
  '^SYN-RECV' 'SYN-RECV = czekamy na ACK po naszym SYN-ACK. Tysiące => SYN flood (tcp_syncookies=1)||albo asymetryczny routing' \
  '^FIN-WAIT' 'FIN-WAIT-1/2 = zamknęliśmy, czekamy na ACK/FIN drugiej strony (tcp_fin_timeout)' \
  '^LAST-ACK' 'LAST-ACK = zamknęliśmy jako drudzy, czekamy na ostatni ACK'

note "Diagram stanów TCP (to nie output — schemat do zapamiętania):"
cat <<'EOF'
     klient                                   serwer
     CLOSED                                   LISTEN
       |  ----------- SYN ----------------->    |
    SYN-SENT                                 SYN-RECV
       |  <--------- SYN+ACK ---------------    |
       |  ----------- ACK ----------------->    |
     ESTAB  <========== dane ==========>      ESTAB
       |  ----------- FIN ----------------->    |       (klient zamyka pierwszy)
   FIN-WAIT-1                               CLOSE-WAIT  <- app musi zrobić close()
       |  <---------- ACK -----------------     |
   FIN-WAIT-2                                   |
       |  <---------- FIN -----------------  LAST-ACK
   TIME-WAIT  ------- ACK ----------------->  CLOSED
     (2*MSL)
EOF

pause
# -----------------------------------------------------------------------------
section "4. Top adresów zdalnych (kto ma ze mną najwięcej połączeń?)"
note "Kolumna 4 = Peer Address:Port. sed usuwa tylko OSTATNI ':port' (działa też dla IPv6 [..]:port)"
run "ss -tn state established | awk 'NR>1 {print \$4}' | sed -E 's/:[0-9]+\$//' | sort | uniq -c | sort -nr | head" ss | annotate \
  '^ +[0-9]+ ' 'liczba połączeń + adres. Setki z jednego IP => klient bez poolingu albo atak (limit: iptables connlimit)'
note "Odwrotnie — po którym LOKALNYM porcie (kto jest serwerem):"
run "ss -tn state established | awk 'NR>1 {n=split(\$3,a,\":\"); print a[n]}' | sort | uniq -c | sort -nr | head -5" ss

pause
# -----------------------------------------------------------------------------
section "5. ss -ti — wnętrze połączenia TCP (RTT, cwnd, retransmisje)"
run "ss -tin state established | head -12" ss | annotate \
  'cubic|bbr|reno' 'cubic/bbr = algorytm kontroli przeciążenia (sysctl net.ipv4.tcp_congestion_control)' \
  'rtt:' 'rtt:ŚREDNIA/ODCHYLENIE ms; rto = timeout retransmisji; cwnd = okno przeciążenia (segmenty)||mss = max segment; pmtu = MTU ścieżki; bytes_sent/acked/received = liczniki' \
  'retrans:' 'retrans:aktualne/ŁĄCZNE oraz bytes_retrans — > 1-2% => straty pakietów na ścieżce' \
  'rwnd_limited' 'rwnd_limited = ograniczało nas okno ODBIORCY (wolny klient / mały bufor)' \
  'sndbuf_limited' 'sndbuf_limited = nasz bufor wysyłki za mały (net.ipv4.tcp_wmem)' \
  'lastsnd' 'lastsnd/lastrcv/lastack = ms od ostatniego wysłania/odbioru. Duże = połączenie bezczynne'
note "Wyłuskanie samego RTT per połączenie (grep -o + sed):"
run "ss -tin state established | grep -oE 'rtt:[0-9.]+' | sed 's/rtt://' | sort -n | awk '{a[NR]=\$1} END{if(NR) printf \"połączeń=%d  min=%sms  mediana=%sms  max=%sms\\n\", NR, a[1], a[int((NR+1)/2)], a[NR]}'" ss

pause
# -----------------------------------------------------------------------------
section "6. Statystyki globalne: ss -s, nstat"
run "ss -s" ss | annotate \
  '^TCP:' 'estab/closed/orphaned/timewait — orphaned = gniazda bez procesu (zamknięte, kończą FIN)' \
  '^Total' 'Total = wszystkie gniazda (też unix)'
note "nstat = liczniki SNMP kernela (to, co kiedyś netstat -s). -a = od bootu, -z = także zera"
run "nstat -az | grep -E 'TcpRetransSegs|TcpExtListenOverflows|TcpExtListenDrops|TcpExtTCPSynRetrans|TcpAttemptFails|TcpEstabResets|TcpExtTCPTimeouts|UdpRcvbufErrors|UdpInErrors|IpInDiscards'" nstat | annotate \
  'TcpRetransSegs' 'TcpRetransSegs = retransmisje. Porównaj z TcpOutSegs (nstat -az TcpOutSegs) — % strat' \
  'ListenOverflows' 'ListenOverflows/ListenDrops > 0 i rośnie => backlog aplikacji pełny (sekcja 1)' \
  'TCPSynRetrans' 'TCPSynRetrans = powtórzone SYN — cel nie odpowiada / DROP po drodze' \
  'TcpAttemptFails' 'AttemptFails = nieudane próby połączeń (RST na SYN = "connection refused")' \
  'TcpEstabResets' 'EstabResets = połączenia zerwane RST-em' \
  'TCPTimeouts' 'TCPTimeouts = wygasłe RTO (poważne straty / zerwane trasy)' \
  'UdpRcvbufErrors' 'UdpRcvbufErrors > 0 = bufor UDP przepełniony (DNS/syslog/QUIC gubi pakiety) -> net.core.rmem_max' \
  'IpInDiscards' 'IpInDiscards = pakiety IP odrzucone przez brak zasobów'
