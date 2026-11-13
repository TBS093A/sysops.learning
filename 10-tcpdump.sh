#!/usr/bin/env bash
# =============================================================================
#  10 — tcpdump: przechwytywanie i czytanie pakietów
# =============================================================================
#  Lekcja SAMA generuje ruch (DNS + ping + HTTPS do $TARGET) i jednocześnie
#  go przechwytuje — widzisz prawdziwy handshake TCP z Twojej maszyny.
#  Wymaga roota (sudo) i pakietu tcpdump.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

T="${TARGET:-example.com}"
lesson_header "10 · TCPDUMP" "cel ruchu: $T  (zmień: TARGET=host $0)"
need_sudo

section "1. Flagi i składnia filtrów BPF"
flags "-i any|eth0" "interfejs (any = wszystkie, wtedy L2 to 'cooked')" \
      "-nn" "bez DNS i bez nazw portów (szybciej, czytelniej)" \
      "-c N" "zakończ po N pakietach" \
      "-s 0 / -s 96" "ile bajtów pakietu łapać (0 = całość)" \
      "-v / -vv" "więcej szczegółów (TTL, długość, checksum, opcje)" \
      "-e" "nagłówek L2 (MAC, VLAN)" \
      "-A / -X" "treść jako ASCII / hex+ASCII" \
      "-w plik.pcap" "zapis do pliku (otworzysz w Wiresharku); -r plik = odczyt" \
      "-tttt" "pełna data i czas" \
      "-Q in|out" "tylko ruch przychodzący / wychodzący"
cheat <<'EOF'
host 10.0.0.5            src host X / dst host X           net 10.0.0.0/8
port 443                 src port 53 / dst port 80         portrange 6000-6010
tcp | udp | icmp | arp   ip6                               vlan 100
and / or / not  + nawiasy w cudzysłowie:  'host X and (port 80 or port 443)'
'tcp[tcpflags] & (tcp-syn|tcp-fin|tcp-rst) != 0'          # tylko SYN/FIN/RST
'tcp[tcpflags] == tcp-syn'                                # tylko nowe połączenia
'icmp[icmptype] != icmp-echo and icmp[icmptype] != icmp-echoreply'   # ICMP-błędy
'udp port 53'                                             # DNS
'ether host aa:bb:cc:dd:ee:ff'                            # po MAC
tcpdump -i eth0 -nn -w /tmp/cap.pcap -C 100 -W 5 'port 5432'   # rotacja: 5 plików po 100 MB
EOF

pause
section "2. Lista interfejsów"
run "tcpdump -D" tcpdump root | annotate \
  'any' 'any = pseudo-interfejs: wszystkie naraz' \
  'Running' 'Up/Running/Wireless + Connected/Disconnected — stan interfejsu'

pause
section "3. Przechwytujemy NASZ ruch: DNS + ping + HTTPS do $T"
note "W tle startuje tcpdump (max 8 s / 40 pakietów), potem generujemy ruch."
CAP="timeout 8 tcpdump -i any -nn -l -c 40 '(udp port 53 or tcp port 53) or (icmp and host $T) or (tcp port 443 and host $T)' 2>&1 & sleep 1.5; getent ahosts $T >/dev/null; ping -c 1 -W 2 $T >/dev/null; curl -s -o /dev/null https://$T/; wait"
run "$CAP" tcpdump root | annotate \
  'listening on' 'link-type = typ nagłówka L2 (LINUX_SLL2 dla any, EN10MB dla ethernetu), snapshot = -s' \
  '\.53: [0-9]+\+' 'ZAPYTANIE DNS: ID+ (+ = recursion desired), [1au] = rekord EDNS, A?/AAAA? = typ, nazwa, (długość)' \
  '\.53 > .*: [0-9]+ [0-9]+/[0-9]+/[0-9]+' 'ODPOWIEDŹ DNS: ID odpowiedzi/autorytatywne/dodatkowe rekordy, potem rekordy A/AAAA/CNAME.||NXDomain/ServFail pojawi się tutaj zamiast liczby rekordów' \
  'ICMP echo request' 'ping: echo request (id, seq, długość)' \
  'ICMP echo reply' 'echo reply — różnica znaczników czasu = RTT' \
  'Flags \[S\],' '[S] = SYN — klient otwiera połączenie. seq = losowy numer startowy (ISN)||win = okno odbioru, options: mss (max segment), sackOK, TS (timestamps), wscale (skala okna)' \
  'Flags \[S\.\],' '[S.] = SYN+ACK — serwer akceptuje ("." to ACK). Brak S. po S => port filtrowany (DROP) / host down' \
  'Flags \[\.\], ack 1,' '[.] = ACK — koniec 3-way handshake. Od teraz seq/ack są WZGLĘDNE (od 1) — -S pokaże bezwzględne' \
  'Flags \[P\.\]' '[P.] = PUSH+ACK — dane aplikacji (tu: TLS ClientHello itd.), length = bajty danych' \
  'Flags \[F\.\]' '[F.] = FIN — strona kończy wysyłanie (grzeczne zamknięcie)' \
  'Flags \[R' '[R] / [R.] = RESET — natychmiastowe zerwanie. RST w odpowiedzi na SYN = "Connection refused"' \
  'packets captured' 'captured = złapane; dropped by kernel > 0 => tcpdump nie nadążał (użyj filtra / -w do pliku)'

note "Uwaga na offloady (GRO/TSO): możesz widzieć 'length' > MTU albo 'cksum incorrect' — to artefakt"
note "karty sieciowej, nie błąd sieci. ethtool -K eth0 gro off tso off  (tylko do testów)."

pause
section "4. Wyłuskiwanie z tcpdump: tylko flagi handshake (awk po polu 'Flags')"
note "sed -nE wyciąga adresy i flagi, reszta linii jest odrzucana:"
CAP2="timeout 6 tcpdump -i any -nn -l -c 20 'tcp port 443 and host $T' 2>/dev/null & sleep 1.5; curl -s -o /dev/null https://$T/; wait"
run "( $CAP2 ) | sed -nE 's/^([0-9:.]+) .*IP6? ([^ ]+) > ([^:]+): Flags \\[([^]]+)\\].*/\\1  \\2 -> \\3  [\\4]/p'" tcpdump root | annotate \
  '\[S\]$' 'S  -> połączenie otwiera klient' \
  '\[S\.\]$' 'S. <- serwer odpowiada' \
  '\[F\.\]$' 'F. — zamykanie połączenia' \
  '\[R' 'R — reset'
