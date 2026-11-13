#!/usr/bin/env bash
# =============================================================================
#  08 — DNS i łączność end-to-end: resolv.conf, getent, dig, ping, tracepath,
#       traceroute, nc, curl -w (timingi), openssl s_client (TLS)
# =============================================================================
#  Drabinka debugowania "strona nie działa":
#    1. czy nazwa się rozwiązuje?            getent ahosts / dig
#    2. czy jest trasa i host odpowiada?     ping / tracepath / traceroute
#    3. czy port jest otwarty?               nc -zv / curl / bash /dev/tcp
#    4. czy TLS się zestawia, cert ważny?    openssl s_client
#    5. co odpowiada aplikacja i gdzie czas? curl -v / curl -w
#  Cel testów można zmienić:  TARGET=example.org ./08-dns-lacznosc.sh
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

T="${TARGET:-github.com}"
lesson_header "08 · DNS I ŁĄCZNOŚĆ" "cel testów: $T  (zmień: TARGET=host $0)"

# -----------------------------------------------------------------------------
section "1. Jak system rozwiązuje nazwy: nsswitch.conf -> /etc/hosts -> resolv.conf"
run "grep -E '^hosts:' /etc/nsswitch.conf" | annotate \
  'files' 'hosts: KOLEJNOŚĆ źródeł. files = /etc/hosts, dns = serwery z resolv.conf,||mdns4_minimal = .local (Avahi), resolve = systemd-resolved, myhostname = własna nazwa hosta' \
  '\[NOTFOUND=return\]' '[NOTFOUND=return] = jeśli to źródło powie "nie ma", NIE pytaj dalszych'
run "grep -vE '^\\s*(#|\$)' /etc/resolv.conf" | annotate \
  '^nameserver 127\.0\.0\.53' '127.0.0.53 = stub systemd-resolved. Prawdziwe serwery: resolvectl status' \
  '^nameserver 127\.' '127.x = lokalny cache/resolver (dnsmasq, unbound, resolved)' \
  '^nameserver' 'nameserver = serwer DNS (max 3 są używane!). Pytane po kolei: kolejny dopiero po timeout (domyślnie 5 s)' \
  '^search|^domain' 'search = domeny doklejane do krótkich nazw (ping db -> db.firma.local)' \
  '^options' 'options: ndots:N (ile kropek, by nie doklejać search — k8s ma ndots:5!), timeout:, attempts:, rotate'
run "head -3 /etc/resolv.conf | grep -i generated" | annotate \
  'Generated' 'resolv.conf jest GENEROWANY (resolvconf/dhcpcd/NM/resolved) — ręczne zmiany znikną. Edytuj źródło'
run "grep -vE '^\\s*(#|\$)' /etc/hosts" | annotate \
  '^127\.0\.0\.1' '/etc/hosts wygrywa z DNS (gdy files jest pierwsze w nsswitch). Stary wpis tutaj = klasyczna pułapka' \
  '^::1' '::1 = localhost IPv6'

pause
# -----------------------------------------------------------------------------
section "2. getent — rozwiązywanie DOKŁADNIE tak, jak robią to aplikacje (przez nsswitch)"
run "getent ahosts $T" getent | annotate \
  'STREAM' 'getent ahosts = getaddrinfo() z libc: uwzględnia /etc/hosts, nsswitch, IPv6. STREAM/DGRAM/RAW = typy gniazd' \
  ':' 'adres IPv6 (AAAA) — jeśli IPv6 nie działa, a aplikacja próbuje go pierwsza, będzie czekać na timeout'
run "getent hosts localhost; getent passwd root" getent | annotate \
  'root:' 'getent działa dla każdej bazy NSS: passwd, group, services, protocols — także z LDAP/SSSD'

pause
# -----------------------------------------------------------------------------
section "3. dig — rozmowa bezpośrednio z serwerem DNS (omija /etc/hosts i nsswitch)"
flags "+short" "same odpowiedzi" "@1.1.1.1" "zapytaj konkretny serwer" "+trace" "od root serverów w dół (delegacje)" \
      "-x IP" "rekord PTR (reverse)" "+noall +answer" "tylko sekcja ANSWER" "TYP" "A AAAA MX TXT NS SOA CNAME SRV CAA"
run "dig $T" dig | annotate \
  'status: NOERROR' 'status: NOERROR = OK; NXDOMAIN = nazwa nie istnieje; SERVFAIL = serwer nie umiał||(DNSSEC, niedostępne autorytatywne); REFUSED = serwer odmawia (brak rekursji dla Ciebie)' \
  'flags:' 'flags: qr=odpowiedź, rd=prosiłem o rekursję, ra=serwer ją oferuje, aa=odpowiedź autorytatywna,||ad=zweryfikowane DNSSEC' \
  'ANSWER SECTION' 'NAZWA  TTL  IN  TYP  WARTOŚĆ — TTL = ile sekund cache może trzymać odpowiedź (maleje w cache)' \
  'CNAME' 'CNAME = alias -> dalej rozwiązywany cel' \
  'Query time' 'Query time: 0-1 ms = z cache, dziesiątki-setki ms = pełne rozwiązywanie' \
  'SERVER:' 'SERVER: który serwer odpowiedział (127.0.0.53 = stub resolved)'
run "dig +short $T A; dig +short $T AAAA; dig +short $T MX; dig +short $T NS" dig | annotate \
  '\.$' 'kropka na końcu = FQDN (nazwa absolutna, od roota)'
note "Porównaj serwery — różne odpowiedzi = propagacja / split-horizon / cache:"
run "for s in \$(awk '/^nameserver/{print \$2}' /etc/resolv.conf) 1.1.1.1; do printf '%-16s ' \$s; dig +short +time=2 +tries=1 @\$s $T A | head -1; done" dig

pause
# -----------------------------------------------------------------------------
section "4. ping / tracepath / traceroute — czy i którędy dochodzą pakiety"
flags "-c N" "N pakietów" "-W s" "timeout odpowiedzi" "-i s" "odstęp" "-M do -s 1472" "test MTU (DF bit)" "-4/-6" "wymuś protokół"
run "ping -c 4 -W 2 $T" ping | annotate \
  'bytes from' 'icmp_seq = numer (dziury = straty), ttl = pozostałe skoki (64/128/255 - liczba hopów),||time = RTT w ms' \
  'packet loss' '% strat. Brak odpowiedzi NIE musi oznaczać awarii — ICMP bywa blokowany (testuj TCP: sekcja 5)' \
  'rtt min/avg/max/mdev' 'mdev = rozrzut (jitter). Duże mdev = przeciążone łącze / Wi-Fi' \
  'Destination .* Unreachable' 'ICMP Unreachable od routera = brak trasy / filtr po drodze'
run "tracepath -n -m 15 $T" tracepath | annotate \
  'pmtu' 'tracepath nie wymaga roota i pokazuje PMTU (MTU ścieżki) — świetne do problemów z MTU' \
  'no reply' 'no reply = router nie odpowiada na sondy (często normalne — liczy się czy KOLEJNE hopy odpowiadają)' \
  'Resume:' 'Resume: pmtu X hops N back M — podsumowanie'
run "traceroute -n -w 1 -q 1 -m 15 $T" traceroute | annotate \
  '^ *1 ' 'hop 1 = Twoja brama. Każdy hop = router; czas = RTT do niego' \
  '\* *$' '* = brak odpowiedzi na sondę (filtr ICMP/rate-limit) — nie musi oznaczać awarii' \
  '!H|!N|!X' '!H/!N = host/sieć nieosiągalna, !X = administracyjnie zabronione (firewall)'
note "TCP traceroute przez firewall: traceroute -T -p 443 $T (root). Ciągły pomiar strat per hop: mtr -rwc 50 $T"

pause
# -----------------------------------------------------------------------------
section "5. Czy port jest otwarty? nc / bash /dev/tcp"
run "nc -zv -w 3 $T 443" nc | annotate \
  'succeeded|open|Connected' 'TCP handshake się udał => routing + firewall + usługa OK' \
  'refused' 'Connection refused = host odpowiedział RST: nic nie słucha na porcie albo REJECT' \
  'timed out|Operation now in progress' 'timeout = brak odpowiedzi: DROP na firewallu / host down / brak trasy'
note "Bez żadnych narzędzi — wbudowane w bash /dev/tcp (timeout zabija próbę po 3 s):"
run "timeout 3 bash -c 'exec 3<>/dev/tcp/$T/443' && echo 'port 443 OTWARTY' || echo 'port 443 zamknięty/filtrowany'" | annotate \
  'OTWARTY' '/dev/tcp/HOST/PORT to pseudo-plik basha: otwarcie = connect(). Działa na minimalnych kontenerach'

pause
# -----------------------------------------------------------------------------
section "6. curl -w — gdzie ucieka czas żądania HTTP(S)"
run "curl -o /dev/null -sS -w 'dns:        %{time_namelookup}s\\ntcp:        %{time_connect}s\\ntls:        %{time_appconnect}s\\nTTFB:       %{time_starttransfer}s\\ntotal:      %{time_total}s\\nhttp_code:  %{http_code}\\nip:         %{remote_ip}\\nhttp_ver:   %{http_version}\\n' https://$T/" curl | annotate \
  '^dns:' 'Czasy są SKUMULOWANE od startu. dns = rozwiązanie nazwy (> 100 ms => wolny resolver)' \
  '^tcp:' 'tcp - dns = czas handshake TCP ≈ 1 RTT' \
  '^tls:' 'tls - tcp = handshake TLS (1-2 RTT + kryptografia)' \
  '^TTFB:' 'TTFB - tls = czas myślenia SERWERA (backend, baza). Tu zwykle leży problem "wolnej strony"' \
  '^total:' 'total - TTFB = transfer treści' \
  '^http_code' 'http_code: 2xx ok, 3xx przekierowanie (-L żeby iść dalej), 4xx błąd klienta, 5xx serwera||000 = nie było odpowiedzi HTTP (DNS/TCP/TLS padło)'
run "curl -sS -o /dev/null -v https://$T/ 2>&1 | grep -E '^(\\*|<|>) ' | grep -vE 'Request completely sent|^\\* +[A-Za-z ]+ \\(OUT\\)' | head -25" curl | annotate \
  '^\* +Trying' '* = informacje curla: Trying IP:PORT = próba połączenia (kolejne Trying = poprzednie się nie udało)' \
  'Connected to' 'Connected = TCP OK' \
  'SSL connection using|TLSv1\.[23]' 'wynegocjowana wersja TLS i szyfr' \
  'ALPN' 'ALPN = negocjacja protokołu aplikacji (h2 = HTTP/2, http/1.1)' \
  'subject:|expire date' 'certyfikat serwera: subject = dla kogo, expire date = do kiedy ważny' \
  '^> ' '> = nagłówki WYSŁANE (żądanie)' \
  '^< ' '< = nagłówki ODEBRANE (odpowiedź serwera)'
cheat <<'EOF'
curl -sv --resolve app.firma.pl:443:10.0.0.5 https://app.firma.pl/   # testuj konkretny backend z poprawnym SNI/Host
curl -H 'Host: app.firma.pl' http://10.0.0.5/                          # to samo dla HTTP
curl -4 / -6 ...                                                       # wymuś IPv4/IPv6
curl --connect-timeout 3 -m 10 ...                                     # timeouty
EOF

pause
# -----------------------------------------------------------------------------
section "7. openssl s_client — TLS i certyfikat"
run "echo | openssl s_client -connect $T:443 -servername $T 2>/dev/null | openssl x509 -noout -subject -issuer -dates -ext subjectAltName" openssl | annotate \
  '^subject' 'subject CN = dla kogo wystawiony' \
  '^issuer' 'issuer = kto podpisał (CA). Self-signed: subject == issuer' \
  '^notBefore' 'notBefore/notAfter = okres ważności. Wygasły cert = klasyczna awaria o 1 w nocy' \
  'DNS:' 'subjectAltName = WSZYSTKIE nazwy, dla których cert jest ważny (CN jest ignorowany przez przeglądarki)'
note "Ile dni do wygaśnięcia (sed wycina datę, date liczy różnicę):"
run "end=\$(echo | openssl s_client -connect $T:443 -servername $T 2>/dev/null | openssl x509 -noout -enddate | sed 's/notAfter=//'); echo \"wygasa: \$end  => za \$(( (\$(date -d \"\$end\" +%s) - \$(date +%s)) / 86400 )) dni\"" openssl
run "echo | openssl s_client -connect $T:443 -servername $T 2>&1 | grep -E 'Verify return code|Protocol *:|Cipher *:' | sort -u" openssl | annotate \
  'Verify return code: 0' 'Verify return code: 0 (ok) = łańcuch zaufania poprawny. 21/20 = brak pośredniego certu w łańcuchu' \
  'Protocol' 'wersja TLS'
