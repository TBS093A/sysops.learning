# shellcheck shell=bash
# =============================================================================
#  lab/scenarios.sh — scenariusze awarii
# =============================================================================
#  Każdy scenariusz N definiuje:
#    sN_title     – tytuł (ukryty w trybie random)
#    sN_story     – objawy, tak jak zgłosiłby je użytkownik
#    sN_setup     – psuje coś w labie
#    sN_check     – sprawdza, czy naprawione (0 = tak)
#    SN_HINTS     – kolejne podpowiedzi (tablica)
#    sN_solution  – opis rozwiązania + dlaczego
#    sN_fix       – automatyczna naprawa (dla ./lab.sh selftest)
#  Nie zaglądaj tu przed rozwiązaniem — to spoiler :)
# =============================================================================

SCENARIOS=(1 2 3 4 5 6 7)

# --- 1 -----------------------------------------------------------------------
s1_title() { echo "Router nie przekazuje pakietów"; }
s1_story() { cat <<'EOF'
"Z klienta nie da się wejść na http://10.0.2.20/. Dziwne, bo ping do routera
 (10.0.1.1) działa, a nawet ping do jego drugiego adresu 10.0.2.1 też!"
EOF
}
s1_setup() { nsx router sysctl -qw net.ipv4.ip_forward=0; }
s1_check() { client_get http://10.0.2.20/; }
S1_HINTS=(
  "Sprawdź po kolei: c ping 10.0.1.1, c ping 10.0.2.1, c ping 10.0.2.20. Gdzie się urywa?"
  "Adresy 10.0.1.1 i 10.0.2.1 należą do routera — pakiet do nich nie jest PRZEKAZYWANY, tylko dostarczany lokalnie."
  "Jaki parametr kernela decyduje, czy host routuje pakiety między interfejsami? (lekcja 09)"
)
s1_solution() { cat <<'EOF'
r sysctl net.ipv4.ip_forward   -> 0. Router odbiera pakiety do SIEBIE (INPUT), ale nie przekazuje
dalej (FORWARD). Naprawa:  r sysctl -w net.ipv4.ip_forward=1   (na stałe: /etc/sysctl.d/*.conf)
Lekcja: ping do adresu routera po drugiej stronie NIE dowodzi, że forwarding działa.
EOF
}
s1_fix() { nsx router sysctl -qw net.ipv4.ip_forward=1; }

# --- 2 -----------------------------------------------------------------------
s2_title() { echo "Timeout czy Connection refused? (iptables)"; }
s2_story() { cat <<'EOF'
"Serwer 10.0.2.20 ma dwie usługi: :80 i :8080. Z klienta port 80 'wisi', a 8080 od razu
 rzuca błędem. Obie usługi działają — sprawdzone lokalnie na serwerze (s curl ...)."
EOF
}
s2_setup() {
  nsx router iptables -A FORWARD -p tcp --dport 80 -j DROP
  nsx server iptables -A INPUT -p tcp --dport 8080 -j REJECT --reject-with tcp-reset
}
s2_check() { client_get http://10.0.2.20/ && client_get http://10.0.2.20:8080/; }
S2_HINTS=(
  "Porównaj komunikaty: c curl -m3 -v http://10.0.2.20/  oraz  c curl -v http://10.0.2.20:8080/"
  "Timeout = ktoś pakiet cicho wyrzuca (DROP). Refused = ktoś odpowiada RST (REJECT albo nic nie słucha)."
  "Firewall może być na KAŻDYM hoście po drodze: r iptables -L -n -v  oraz  s iptables -L -n -v. Patrz na liczniki pkts."
)
s2_solution() { cat <<'EOF'
Port 80: router, łańcuch FORWARD, reguła DROP -> klient czeka do timeoutu (SYN-SENT w ss).
Port 8080: serwer, łańcuch INPUT, REJECT --reject-with tcp-reset -> natychmiastowy "Connection refused".
Naprawa:  r iptables -D FORWARD -p tcp --dport 80 -j DROP
          s iptables -D INPUT -p tcp --dport 8080 -j REJECT --reject-with tcp-reset
          (albo po numerze: r iptables -L FORWARD --line-numbers ; r iptables -D FORWARD 1)
EOF
}
s2_fix() {
  nsx router iptables -D FORWARD -p tcp --dport 80 -j DROP
  nsx server iptables -D INPUT -p tcp --dport 8080 -j REJECT --reject-with tcp-reset
}

# --- 3 -----------------------------------------------------------------------
s3_title() { echo "Brak trasy powrotnej"; }
s3_story() { cat <<'EOF'
"Klient nie może się połączyć z serwerem. Admin serwera przysięga, że widzi przychodzące
 pakiety od klienta, a firewall jest pusty."
EOF
}
s3_setup() { ip -n server route del default; }
s3_check() { client_get http://10.0.2.20/; }
S3_HINTS=(
  "Pakiety DOCHODZĄ do serwera. Czy serwer wie, jak ODESŁAĆ odpowiedź do 10.0.1.10?"
  "s ip route get 10.0.1.10   — co mówi kernel serwera?"
  "Dwie poprawne naprawy: trasa na serwerze albo NAT (MASQUERADE) na routerze — wtedy serwer widzi klienta jako 10.0.2.1."
)
s3_solution() { cat <<'EOF'
s ip route  -> brak 'default' i brak trasy do 10.0.1.0/24. Odpowiedź serwera nie ma dokąd wyjść
(s ip route get 10.0.1.10 -> "Network is unreachable").
Naprawa A:  s ip route add default via 10.0.2.1        (albo: s ip route add 10.0.1.0/24 via 10.0.2.1)
Naprawa B:  r iptables -t nat -A POSTROUTING -o r-s -j MASQUERADE   (serwer widzi wtedy 10.0.2.1)
Routing jest DWUKIERUNKOWY — zawsze sprawdzaj drogę powrotną.
EOF
}
s3_fix() { ip -n server route add default via 10.0.2.1; }

# --- 4 -----------------------------------------------------------------------
s4_title() { echo "MTU blackhole — duże odpowiedzi wiszą"; }
s4_story() { cat <<'EOF'
"Strona http://10.0.2.20/small.txt działa, ale pobranie http://10.0.2.20/big.bin wisi w nieskończoność.
 Ping działa. Połączenie TCP się zestawia (curl pokazuje 'Connected')."
EOF
}
s4_setup() {
  ip -n router link set r-c mtu 1400
  nsx router iptables -A OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP
}
s4_check() { client_get http://10.0.2.20/big.bin 5; }
S4_HINTS=(
  "Małe pakiety przechodzą, duże nie. Sprawdź MTU interfejsów na całej ścieżce: c ip link / r ip link / s ip link"
  "Test z ustawionym bitem DF: c ping -M do -s 1472 10.0.2.20  vs  c ping -M do -s 1372 10.0.2.20"
  "Router powinien odesłać ICMP 'fragmentation needed', żeby serwer zmniejszył pakiety (PMTUD). Czy coś to blokuje? r iptables -L -n -v"
)
s4_solution() { cat <<'EOF'
r-c ma MTU 1400, reszta 1500. Serwer wysyła segmenty 1500 B z bitem DF; router musi odesłać
ICMP type 3 code 4 (fragmentation-needed), ale reguła w OUTPUT routera go wyrzuca -> PMTU blackhole.
Naprawa (dowolna):
  r iptables -D OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP     (nie blokuj tego ICMP!)
  r ip link set r-c mtu 1500                                                (wyrównaj MTU)
  r iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
Klasyka przy VPN, PPPoE, VXLAN, tunelach w chmurze.
EOF
}
s4_fix() { nsx router iptables -D OUTPUT -p icmp --icmp-type fragmentation-needed -j DROP; }

# --- 5 -----------------------------------------------------------------------
s5_title() { echo "Pełna kolejka accept (backlog)"; }
s5_story() { cat <<'EOF'
"Aplikacja na 10.0.2.20:9000 przy kilku równoczesnych klientach przestaje przyjmować połączenia —
 część klientów dostaje timeout już na etapie łączenia. Proces żyje, CPU wolny."
 Test obciążenia:  c python3 $LAB_DIR/tools/conncheck.py 10.0.2.20 9000 8
EOF
}
s5_setup() { nsx server sysctl -qw net.core.somaxconn=2; start_app; }
s5_check() { nsx client python3 "$LAB_DIR/tools/conncheck.py" 10.0.2.20 9000 8 >/dev/null; }
S5_HINTS=(
  "Uruchom test obciążenia i W TRAKCIE patrz na gniazdo nasłuchujące: s ss -tln 'sport = :9000'"
  "Dla LISTEN: Recv-Q = połączenia czekające na accept(), Send-Q = limit kolejki. Ile wynosi limit?"
  "Aplikacja prosi o listen(128). Kernel przycina to do... jakiego sysctl? (lekcja 05 i 09). Po zmianie: app-restart"
)
s5_solution() { cat <<'EOF'
s ss -tln 'sport = :9000'  -> Send-Q = 2: kolejka accept ma 2 miejsca, bo net.core.somaxconn=2.
Gdy jest pełna, kernel wyrzuca nowe SYN-y -> klienci mają timeout (s nstat -az TcpExtListenOverflows rośnie).
Naprawa:  s sysctl -w net.core.somaxconn=4096 ; app-restart     (backlog liczony w chwili listen()!)
Prawdziwa przyczyna to wolne accept() aplikacji — większy backlog tylko kupuje czas.
EOF
}
s5_fix() { nsx server sysctl -qw net.core.somaxconn=4096; start_app; }

# --- 6 -----------------------------------------------------------------------
s6_title() { echo "DNS mówi jedno, aplikacja robi drugie"; }
s6_story() { cat <<'EOF'
"curl http://app.lab/ z klienta nie działa. Admin DNS pokazuje, że rekord jest poprawny:
 dig @10.0.1.1 app.lab -> 10.0.2.20   (bez dig: dnsq app.lab 10.0.1.1)"
EOF
}
s6_setup() { echo "10.0.2.99 app.lab   # stary serwer, przeniesiony 2024" >> "$LAB/hosts"; }
s6_check() { [[ $(nsx client getent ahostsv4 app.lab | awk 'NR==1{print $1}') == 10.0.2.20 ]] && client_get http://app.lab/; }
S6_HINTS=(
  "Porównaj: c getent hosts app.lab  (tak jak aplikacja)  z  odpowiedzią serwera DNS: dnsq app.lab 10.0.1.1  (albo dig +short @10.0.1.1 app.lab)"
  "getent idzie przez /etc/nsswitch.conf. Jakie źródło jest PIERWSZE w linii hosts:?"
  "Popraw /etc/hosts w labie: vi /etc/hosts, albo grep -v ... /etc/hosts > /run/lab/h; cat /run/lab/h > /etc/hosts (sed -i tu nie zadziała — czemu?)"
)
s6_solution() { cat <<'EOF'
/etc/hosts zawiera stary wpis 10.0.2.99 app.lab, a nsswitch ma 'hosts: files ... dns' -> plik wygrywa z DNS.
dig/nslookup pytają serwer DNS bezpośrednio i omijają /etc/hosts — dlatego "DNS jest dobry".
Naprawa: usuń linię z /etc/hosts (vi /etc/hosts albo: grep -v 10.0.2.99 /etc/hosts > /run/lab/h; cat /run/lab/h > /etc/hosts)
sed -i NIE edytuje pliku w miejscu: tworzy plik tymczasowy w tym samym katalogu i robi rename().
W labie /etc nie jest zapisywalny ("couldn't open temporary file"), a na plik zamontowany bind mountem
(np. /etc/hosts i /etc/resolv.conf w kontenerach Dockera!) rename() daje "Device or resource busy".
'cat > plik' nadpisuje treść tego samego inode — działa w obu przypadkach.
EOF
}
s6_fix() { grep -v '10.0.2.99' "$LAB/hosts" > "$LAB/hosts.new"; cat "$LAB/hosts.new" > "$LAB/hosts"; }

# --- 7 -----------------------------------------------------------------------
s7_title() { echo "Wolna i stratna sieć (tc netem)"; }
s7_story() { cat <<'EOF'
"Od rana wszystko z klienta do serwera działa wolno: strony ładują się sekundami, czasem curl
 się zawiesza. Nikt nic nie zmieniał (podobno)."
EOF
}
s7_setup() { nsx router tc qdisc add dev r-c root netem delay 250ms 50ms loss 8%; }
s7_check() {
  local avg
  avg=$(nsx client ping -c 5 -i 0.2 -W 1 10.0.2.20 2>/dev/null | awk -F/ '/^rtt/{print int($5)}')
  [[ -n $avg && $avg -lt 20 ]] && ! nsx router tc qdisc show | grep -q netem
}
S7_HINTS=(
  "Zmierz: c ping -c 20 -i 0.2 10.0.2.20 — RTT i straty. Potem c ping 10.0.1.1 — czy problem jest już na pierwszym odcinku?"
  "Zajrzyj do połączenia: c curl -s -o /dev/null http://10.0.2.20/big.bin & c ss -tin  (rtt, retrans)"
  "Kolejki (qdisc) na interfejsach: r tc -s qdisc show  — czy któryś interfejs ma dziwną dyscyplinę?"
)
s7_solution() { cat <<'EOF'
r tc qdisc show dev r-c -> 'netem delay 250ms 50ms loss 8%'. netem działa na RUCHU WYCHODZĄCYM interfejsu,
więc opóźnia wszystko, co router wysyła do klienta (ping do 10.0.1.1 też jest wolny!).
Naprawa:  r tc qdisc del dev r-c root
netem to świetne narzędzie do testów (chaos engineering), ale zapomniany po teście robi dokładnie to.
EOF
}
s7_fix() { nsx router tc qdisc del dev r-c root; }
