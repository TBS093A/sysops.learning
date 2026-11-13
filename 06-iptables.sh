#!/usr/bin/env bash
# =============================================================================
#  06 — iptables: tabele, łańcuchy, reguły, liczniki, NAT, Docker, śledzenie
# =============================================================================
#  Wszystkie komendy tutaj TYLKO CZYTAJĄ reguły (-L, -S, iptables-save).
#  Komendy zmieniające firewall są w ściągawkach i NIE są uruchamiane.
#
#  iptables to interfejs do netfilter w jądrze. Dziś zwykle działa jako
#  iptables-nft (te same komendy, pod spodem nftables) — sprawdzisz w sekcji 1.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "06 · IPTABLES" "tabele / łańcuchy / liczniki / NAT / Docker / TRACE"
need_sudo

# -----------------------------------------------------------------------------
section "0. Schemat: przez które łańcuchy przechodzi pakiet (do zapamiętania)"
cat <<'EOF'
                     PAKIET PRZYCHODZI (np. eth0)
                               │
                  ┌────────────▼────────────┐
                  │ PREROUTING  raw → (conntrack) → mangle → nat(DNAT)
                  └────────────┬────────────┘
                     decyzja routingu: do mnie czy dalej?
              ┌────────────────┴─────────────────┐
              ▼ (adres lokalny)                  ▼ (forward, net.ipv4.ip_forward=1)
   ┌─────────────────────┐            ┌──────────────────────┐
   │ INPUT mangle→filter │            │ FORWARD mangle→filter│  <- Docker, routery, k8s
   └──────────┬──────────┘            └──────────┬───────────┘
              ▼                                  │
       PROCES LOKALNY                            │
              │                                  │
   ┌──────────▼──────────────────────┐           │
   │ OUTPUT raw→mangle→nat→filter    │           │
   └──────────┬──────────────────────┘           │
              └──────────────┬───────────────────┘
                  ┌──────────▼──────────────────┐
                  │ POSTROUTING mangle → nat(SNAT/MASQUERADE)
                  └──────────┬──────────────────┘
                             ▼  WYCHODZI
  TABELE:  filter = przepuść/odrzuć (domyślna)   nat = zmiana adresów/portów
           mangle = zmiana nagłówków, MARK        raw = przed conntrack (NOTRACK)
  CELE:    ACCEPT | DROP (cicho -> klient ma timeout) | REJECT (ICMP/RST -> "refused")
           RETURN (wróć do łańcucha wywołującego) | LOG | MARK | DNAT | SNAT | MASQUERADE
  Reguły czytane OD GÓRY, pierwsza pasująca z celem kończącym (ACCEPT/DROP/REJECT) wygrywa.
  Gdy nic nie pasuje -> POLITYKA łańcucha (policy ACCEPT/DROP).
EOF

pause
# -----------------------------------------------------------------------------
section "1. Wersja i backend"
run "iptables -V" iptables | annotate \
  'nf_tables' '(nf_tables) = iptables-nft: składnia iptables, reguły lądują w nftables (nft list ruleset je pokaże)' \
  'legacy' '(legacy) = stary backend x_tables. NIE mieszaj legacy i nft na jednym hoście — reguły się "zgubią"'
run "ls -l \$(command -v iptables)" iptables | annotate \
  'xtables' 'iptables to symlink na xtables-nft-multi / xtables-legacy-multi — tu też widać backend'

pause
# -----------------------------------------------------------------------------
section "2. iptables -L -n -v — tabela filter z licznikami"
flags "-L [ŁAŃCUCH]" "listuj reguły (domyślnie tabela filter)" \
      "-n" "bez DNS (inaczej lista może wisieć minutami!)" \
      "-v" "liczniki pakietów/bajtów + interfejsy in/out" \
      "-x" "dokładne liczby (bez K/M/G)" \
      "--line-numbers" "numery reguł (do -D / -I N)" \
      "-t TABELA" "filter | nat | mangle | raw | security" \
      "-w" "czekaj na lock xtables (gdy inny proces właśnie zmienia reguły)"
run "iptables -w -L -n -v --line-numbers" iptables root | annotate \
  '^Chain [A-Z]+ \(policy' 'Chain X (policy P N packets, M bytes): wbudowany łańcuch, P = co się dzieje z pakietem,||który nie pasował do żadnej reguły. Liczniki przy policy = ile pakietów skończyło na polityce' \
  'policy DROP' 'policy DROP = "domyślnie odmów" — wszystko, czego jawnie nie wpuszczono, ginie (bez odpowiedzi)' \
  '\([0-9]+ references\)' 'Chain X (N references) = łańcuch użytkownika; N = ile reguł do niego skacze (-j X).||0 references = martwy łańcuch (nikt go nie używa)' \
  '^num +pkts' 'num = pozycja, pkts/bytes = ile trafiło (od startu/zerowania), target = cel (-j),||prot = protokół, opt = opcje (-- / -f fragmenty), in/out = interfejs (* = dowolny),||source/destination = adresy (0.0.0.0/0 = każdy), a na końcu dodatkowe dopasowania (-m ...)' \
  'ctstate (RELATED,ESTABLISHED|ESTABLISHED,RELATED)' 'RELATED,ESTABLISHED ACCEPT = przepuść odpowiedzi na ruch, który już zaakceptowaliśmy.||Musi być WYSOKO — inaczej każdy pakiet przechodzi całą listę (wydajność) / blokujesz odpowiedzi' \
  'ctstate INVALID' 'INVALID = pakiet nie pasuje do żadnego stanu conntrack (śmieci, ataki, asymetryczny routing)' \
  'dpt:[0-9]+' 'tcp dpt:22 = port docelowy (spt = źródłowy); multiport dports 80,443 = kilka portów' \
  ' lo ' 'reguła z in=lo: zawsze wpuszczaj loopback (inaczej lokalne usługi przestaną działać)' \
  'icmp' 'ICMP: nie blokuj całego! type 3 code 4 (fragmentation needed) jest potrzebny do PMTU discovery' \
  'reject-with' 'REJECT reject-with icmp-port-unreachable / tcp-reset = szybka odmowa ("Connection refused")' \
  'DOCKER' 'Łańcuchy DOCKER* tworzy dockerd: DOCKER (DNAT-y portów -p), DOCKER-ISOLATION-STAGE-1/2||(izolacja sieci między bridge), DOCKER-USER = TU wpisuj własne reguły dla ruchu do kontenerów —||Docker ich nie nadpisuje. Reguły w INPUT NIE chronią opublikowanych portów kontenerów (idą przez FORWARD)!' \
  'LOG ' 'LOG = zapisz do logu kernela (dmesg/journal) i idź dalej. --log-prefix pomaga grepować' \
  'limit: avg' 'limit = rate-limit dopasowania (np. logów lub ICMP), burst = ile na start' \
  'f2b-|fail2ban' 'f2b-* = łańcuchy fail2ban — banowane IP lądują tu jako REJECT/DROP' \
  'ufw-' 'ufw-* = łańcuchy UFW (Ubuntu) — zarządzaj przez ufw status verbose' \
  'KUBE-|cali-|CILIUM' 'KUBE-*/cali-*/CILIUM_* = kube-proxy / Calico / Cilium. Nie edytuj ręcznie'

pause
# -----------------------------------------------------------------------------
section "3. iptables -S — reguły w formacie komend (najlepsze do czytania i kopiowania)"
run "iptables -w -S" iptables root | annotate \
  '^-P ' '-P ŁAŃCUCH POLITYKA = polityka domyślna wbudowanego łańcucha' \
  '^-N ' '-N X = utwórz łańcuch użytkownika X' \
  '^-A ' '-A ŁAŃCUCH ... -j CEL = dopisz regułę na KONIEC (-I = wstaw na początek / na pozycję N)' \
  ' -m conntrack --ctstate' '-m MODUŁ = załaduj moduł dopasowania (conntrack, multiport, limit, recent, set, comment...)' \
  ' ! -[io] ' '! = negacja, np. -i docker0 ! -o docker0 = wchodzi z docker0, ale nie wychodzi nim' \
  ' -j [A-Z-]+$' '-j = cel (jump). Cel będący łańcuchem = "wywołanie funkcji", RETURN = powrót' \
  ' -g ' '-g = goto: skok bez powrotu (RETURN wraca wtedy wyżej)' \
  '--comment' '-m comment --comment "..." = opis reguły, widoczny w listingu — używaj!'

note "Wyłuskiwanie: które porty TCP są jawnie otwarte w INPUT? (grep + sed z grupą przechwytującą)"
run "iptables -w -S INPUT | grep -E -- '-j ACCEPT' | sed -nE 's/.*-p tcp.*--dports? ([0-9,:]+).*/otwarte TCP: \\1/p'" iptables root | annotate \
  'otwarte' '--dport 22 albo -m multiport --dports 80,443 albo zakres 6000:6010'
note "(pusto = brak reguł ACCEPT na porty w INPUT — przy polityce ACCEPT i tak wszystko jest otwarte)"

pause
# -----------------------------------------------------------------------------
section "4. Liczniki — które reguły faktycznie łapią ruch? (awk filtruje pkts > 0)"
note "-x = dokładne liczby (bez 'K'/'M'), więc awk może porównać kolumnę 1 liczbowo"
run "iptables -w -L -n -v -x | awk '/^Chain/{c=\$2} \$1 ~ /^[0-9]+\$/ && \$1 > 0 {printf \"%-26s %10d pkts %12d B  -> %s\\n\", c, \$1, \$2, \$3}' | sort -k2 -nr | head -15" iptables root | annotate \
  'pkts' 'Reguły, które coś złapały, posortowane po pakietach. Reguła z 0 po długim czasie = martwa / źle napisana.||Zerowanie liczników: iptables -Z [ŁAŃCUCH]  — przydatne przed testem: wyzeruj, wygeneruj ruch, patrz'

pause
# -----------------------------------------------------------------------------
section "5. Tabela nat — DNAT (przekierowanie portów) i MASQUERADE (wyjście w świat)"
run "iptables -w -t nat -L -n -v --line-numbers" iptables root | annotate \
  '^Chain PREROUTING' 'PREROUTING nat = DNAT: zmiana ADRESU DOCELOWEGO zanim zapadnie decyzja routingu (port forwarding)' \
  '^Chain POSTROUTING' 'POSTROUTING nat = SNAT/MASQUERADE: zmiana ADRESU ŹRÓDŁOWEGO tuż przed wyjściem' \
  '^Chain OUTPUT' 'OUTPUT nat = DNAT dla ruchu generowanego lokalnie (np. curl localhost:8080 -> kontener)' \
  'MASQUERADE' 'MASQUERADE = SNAT na adres interfejsu wyjściowego (dynamiczny IP). Tu: sieć kontenerów/VM||wychodzi w świat jako adres hosta. Wymaga net.ipv4.ip_forward=1' \
  'ADDRTYPE match dst-type LOCAL' 'dst-type LOCAL = pakiet do KTÓREGOKOLWIEK adresu tego hosta -> skocz do DOCKER (obsługa -p)' \
  'DNAT .*to:' 'DNAT to:IP:PORT = przepisz cel. Odpowiedź wraca automatycznie dzięki conntrack' \
  'RETURN .*docker0|RETURN +all +-- +docker0' 'RETURN dla ruchu z docker0 = nie DNAT-uj ruchu wewnątrz bridge'
cheat <<'EOF'
# port forwarding: 8080 na hoście -> 10.0.0.20:80
iptables -t nat -A PREROUTING -i eth0 -p tcp --dport 8080 -j DNAT --to-destination 10.0.0.20:80
iptables -A FORWARD -p tcp -d 10.0.0.20 --dport 80 -m conntrack --ctstate NEW -j ACCEPT
sysctl -w net.ipv4.ip_forward=1
# NAT dla sieci wewnętrznej przez eth0 (router)
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j MASQUERADE
# stały adres zamiast MASQUERADE (szybsze, gdy IP się nie zmienia)
iptables -t nat -A POSTROUTING -s 10.0.0.0/24 -o eth0 -j SNAT --to-source 203.0.113.10
EOF

pause
# -----------------------------------------------------------------------------
section "6. Tabele mangle i raw"
run "iptables -w -t mangle -S; iptables -w -t raw -S" iptables root | annotate \
  '^-P PREROUTING' 'Same -P = tabela pusta (tylko polityki). Większość hostów nie używa mangle/raw' \
  'MARK|CONNMARK' 'MARK/CONNMARK = znakowanie pakietów/połączeń (fwmark) -> ip rule / tc / QoS' \
  'TCPMSS' 'TCPMSS --clamp-mss-to-pmtu = naprawa MTU dla tuneli (PPPoE/VPN)' \
  'NOTRACK|CT --notrack' 'raw NOTRACK = pomiń conntrack (bardzo obciążone usługi typu DNS/UDP)' \
  'TRACE' 'TRACE = śledzenie pakietu przez wszystkie reguły (sekcja 8)'

pause
# -----------------------------------------------------------------------------
section "7. iptables-save — pełny zrzut (format do iptables-restore)"
run "iptables-save | head -40" iptables-save root | annotate \
  '^# Generated' 'Komentarz z wersją/datą. Tak wygląda plik /etc/iptables/rules.v4 (Debian) / iptables.rules' \
  '^\*[a-z]+' '*TABELA = początek sekcji tabeli' \
  '^:[A-Z-]+ [A-Z-]+ \[' ':ŁAŃCUCH POLITYKA [pakiety:bajty] — "-" zamiast polityki = łańcuch użytkownika' \
  '^COMMIT' 'COMMIT = zatwierdź tabelę ATOMOWO. iptables-restore ładuje wszystko naraz — bez okna bez firewalla'
note "Statystyka reguł per tabela (awk liczy linie -A w sekcjach *tabela):"
run "iptables-save | awk '/^\\*/{t=\$1} /^-A/{n[t]++} END{for (k in n) print k, n[k], \"reguł\"}'" iptables-save root
cheat <<'EOF'
iptables-save > /root/fw-$(date +%F).rules          # backup ZAWSZE przed zmianą
iptables-restore --test < plik.rules                # walidacja bez ładowania
iptables-restore < plik.rules                       # atomowe załadowanie
# trwałość:  Debian/Ubuntu: netfilter-persistent save   (-> /etc/iptables/rules.v4|v6)
#            RHEL: iptables-services (/etc/sysconfig/iptables)  |  Void: /etc/iptables/iptables.rules + sv iptables
# BEZPIECZNA zmiana zdalnie (auto-rollback, jeśli odetnie Ci SSH):
iptables-apply -t 60 plik.rules
EOF

pause
# -----------------------------------------------------------------------------
section "8. Diagnostyka: gdzie ginie mój pakiet?"
note "Czy w logu kernela są wpisy z reguł LOG (np. UFW BLOCK / własny --log-prefix)?"
run "dmesg -T | grep -E 'IN=[a-z0-9]* OUT=' | tail -5" dmesg root | annotate \
  'IN=' 'Format LOG: IN=/OUT= interfejsy, SRC/DST adresy, PROTO, SPT/DPT porty, SYN/ACK flagi —||prefix przed IN= mówi, która reguła zalogowała'
cheat <<'EOF'
# 1) liczniki: wyzeruj, wygeneruj ruch, sprawdź która reguła rośnie
iptables -Z; curl -m3 http://cel:80; iptables -L -n -v -x | awk '$1>0'
# 2) LOG tuż przed DROP (rate-limit, żeby nie zalać logów)
iptables -I INPUT 5 -p tcp --dport 8080 -m limit --limit 5/min -j LOG --log-prefix "FW-8080: "
# 3) TRACE — każdy krok pakietu przez reguły (tabela raw):
iptables -t raw -A PREROUTING -p tcp --dport 8080 -j TRACE
xtables-monitor --trace        # backend nft;  legacy: dmesg | grep TRACE
iptables -t raw -D PREROUTING -p tcp --dport 8080 -j TRACE   # posprzątaj!
# 4) DROP vs REJECT po stronie klienta:
#    timeout          -> DROP (albo brak trasy / host down)
#    connection refused -> REJECT tcp-reset albo nic nie słucha na porcie (sprawdź ss -tlnp)
EOF

pause
# -----------------------------------------------------------------------------
section "9. Wzorcowy minimalny firewall hosta (ściągawka, nie uruchamiana)"
cheat <<'EOF'
iptables -P INPUT DROP ; iptables -P FORWARD DROP ; iptables -P OUTPUT ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 5/s -j ACCEPT
iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -s 10.0.0.0/8 -m conntrack --ctstate NEW -j ACCEPT
# anty-brute-force SSH: max 4 nowe połączenia / 60 s z jednego IP
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --set --name ssh
iptables -A INPUT -p tcp --dport 22 -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 4 --name ssh -j DROP
# limit równoległych połączeń z jednego IP do HTTP
iptables -A INPUT -p tcp --syn --dport 80 -m connlimit --connlimit-above 50 -j REJECT --reject-with tcp-reset
iptables -A INPUT -p tcp -m multiport --dports 80,443 -j ACCEPT
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited   # albo zostaw politykę DROP
# Docker: ogranicz dostęp do opublikowanych portów kontenerów
iptables -I DOCKER-USER -i eth0 ! -s 10.0.0.0/8 -j DROP
# usuwanie: po numerze  iptables -D INPUT 3   |  po treści  iptables -D INPUT -p tcp --dport 80 -j ACCEPT
# IPv6 to OSOBNY firewall: ip6tables (ta sama składnia) — nie zapomnij!
EOF
run "ip6tables -w -L INPUT -n -v | head -15" ip6tables root | annotate \
  'policy ACCEPT' 'IPv6 INPUT z polityką ACCEPT i bez reguł = host może być OTWARTY po IPv6, choć IPv4 jest zamknięte!'
