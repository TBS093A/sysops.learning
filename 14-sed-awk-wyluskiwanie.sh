#!/usr/bin/env bash
# =============================================================================
#  14 — Sztuka wyłuskiwania: grep / sed / awk / cut / sort / uniq na
#       PRAWDZIWYCH danych systemu (/proc, /etc, ip, ss, ps)
# =============================================================================
#  Wszystkie poprzednie lekcje używały tych technik — tu są zebrane i rozebrane.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "14 · SED / AWK — WYŁUSKIWANIE" "regexy, pola, agregacja, dekodowanie /proc"

# -----------------------------------------------------------------------------
section "1. grep — wybór linii"
flags "-E" "rozszerzone regexy (| + ? {} bez backslashy)" "-o" "wypisz TYLKO dopasowanie, nie całą linię" "-v" "odwróć" \
      "-c" "policz" "-w" "całe słowo" "-A/-B/-C N" "kontekst po/przed/wokół" "-P" "regex Perla (\\d, lookahead)" "-r -n -H" "rekursywnie, numer linii, nazwa pliku"
run "ip addr | grep -oE 'inet [0-9.]+/[0-9]+'" | annotate \
  '^inet' 'grep -o: z całej linii zostaje tylko pasujący fragment'
run "grep -oP '(?<=inet )[0-9.]+' <(ip addr)" | annotate \
  '^[0-9]' '-P z lookbehind (?<=inet ) = dopasuj adres, ale bez słowa "inet" w wyniku'

pause
# -----------------------------------------------------------------------------
section "2. sed — podstawienia i wycinanie"
note "s/regex/zamiana/flagi  |  -n + p = drukuj tylko to, co jawnie każę  |  -E = ERE  |  \\1 = grupa"
run "sed -nE 's/^([^:]+):[^:]*:([0-9]+):.*:([^:]+)\$/\\1 uid=\\2 shell=\\3/p' /etc/passwd | head -5" | annotate \
  'uid=' '/etc/passwd: login:x:UID:GID:opis:home:shell — trzy grupy ( ) przechwytują pola 1, 3 i ostatnie'
run "sed -n '/^\\[/,/^\$/p' /etc/os-release 2>/dev/null | head -3; sed -n '1,3p' /etc/os-release" | annotate \
  '=' "sed -n '1,3p' = linie 1-3; '/start/,/stop/p' = zakres między wzorcami (świetne do bloków configu)"
run "sed -E 's/#.*//; /^[[:space:]]*\$/d' /etc/hosts" | annotate \
  '.' 'Dwa polecenia rozdzielone ;: usuń komentarze, potem (d) usuń puste linie => czysty config'
run "ip route get 1.1.1.1 | sed -nE 's/.*1\\.1\\.1\\.1( via ([0-9.]+))? dev ([^ ]+).* src ([0-9.]+).*/brama=\\2 interfejs=\\3 źródło=\\4/p'" | annotate \
  'brama=' 'Opcjonalna grupa ( via ([0-9.]+))? — numeracja grup liczy nawiasy otwierające od lewej, więc brama to \2.||Ten sam wzór na logach auth: s/.*Failed password for (invalid user )?([^ ]+) from ([0-9.]+).*/\2 \3/'

pause
# -----------------------------------------------------------------------------
section "3. awk — myślenie kolumnami"
note "awk 'WZORZEC { AKCJA }'   \$1..\$NF = pola, NR = nr linii, NF = liczba pól, -F = separator"
run "awk -F: '\$3 >= 1000 && \$7 !~ /nologin|false/ {print \$1, \$6, \$7}' /etc/passwd" | annotate \
  '/' 'Prawdziwi użytkownicy: UID >= 1000 i z prawdziwym shellem. Warunek liczbowy + negacja regexa (!~)'
run "awk '{print \$1}' /proc/loadavg; awk 'END{print NR, \"linii w /etc/services\"}' /etc/services" | annotate \
  'linii' 'blok END wykonuje się po przeczytaniu wszystkiego — NR = liczba linii (jak wc -l)'
note "Tablice asocjacyjne = GROUP BY. Ile procesów ma każdy użytkownik:"
run "ps -eo user= | awk '{c[\$1]++} END{for (u in c) printf \"%-14s %d\\n\", u, c[u]}' | sort -k2 -nr"
note "Średnia / min / max w jednym przejściu (RSS procesów w MiB):"
run "ps -eo rss= | awk '\$1>0 {s+=\$1; n++; if(\$1>max) max=\$1; if(min==\"\"||\$1<min) min=\$1} END{printf \"n=%d avg=%.1fMiB min=%.1fMiB max=%.1fMiB\\n\", n, s/n/1024, min/1024, max/1024}'"
note "Sklejanie danych z DWÓCH plików (NR==FNR = pierwszy plik): nazwy grup dla użytkowników"
run "awk -F: 'NR==FNR {g[\$3]=\$1; next} \$3>=1000 && \$3<65534 {print \$1, \"-> grupa główna:\", g[\$4]}' /etc/group /etc/passwd"

pause
# -----------------------------------------------------------------------------
section "4. Dekodowanie /proc/net/tcp awk-iem (jak ss działa pod spodem)"
note "Adresy są w HEX, little-endian: 0100007F:0016 = 127.0.0.1:22. Stan 0A = LISTEN, 01 = ESTABLISHED"
run "head -3 /proc/net/tcp" | annotate \
  'local_address' 'sl local_address rem_address st tx_queue:rx_queue ... uid ... inode' \
  ':' 'st = stan TCP w hex (01 ESTAB, 02 SYN_SENT, 03 SYN_RECV, 04 FIN_WAIT1, 06 TIME_WAIT, 08 CLOSE_WAIT, 0A LISTEN)'
run "awk 'function ip(h,  i,o){o=\"\"; for(i=7;i>=1;i-=2) o=o (o?\".\":\"\") strtonum(\"0x\" substr(h,i,2)); return o}
  BEGIN{st[\"01\"]=\"ESTAB\"; st[\"06\"]=\"TIME_WAIT\"; st[\"08\"]=\"CLOSE_WAIT\"; st[\"0A\"]=\"LISTEN\"; st[\"02\"]=\"SYN_SENT\"}
  NR>1 {split(\$2,l,\":\"); split(\$3,r,\":\"); printf \"%-11s %15s:%-5d -> %15s:%-5d uid=%s\\n\", (\$4 in st ? st[\$4] : \$4), ip(l[1]), strtonum(\"0x\" l[2]), ip(r[1]), strtonum(\"0x\" r[2]), \$8}' /proc/net/tcp | head -12" | annotate \
  'LISTEN' 'Funkcja ip(): bierze bajty hex od końca (little-endian) i zamienia na dziesiętne — dokładnie to robi ss' \
  'ESTAB' 'strtonum("0x0016") = 22 (gawk). W mawk zamiast strtonum użyj: printf "%d", "0x16" w shellu'

pause
# -----------------------------------------------------------------------------
section "5. Klasyczne potoki: sort | uniq -c | sort -nr | head"
note "Najczęstsze powłoki użytkowników:"
run "cut -d: -f7 /etc/passwd | sort | uniq -c | sort -nr" | annotate \
  '^ +[0-9]+ ' 'cut -d: -f7 = 7. pole; uniq -c liczy SĄSIEDNIE duplikaty (dlatego najpierw sort)'
note "Rozszerzenia plików w /etc (sed bierze tekst po ostatniej kropce):"
run "find /etc -maxdepth 2 -type f -name '*.*' 2>/dev/null | sed -E 's/.*\\.//' | sort | uniq -c | sort -nr | head -8"
note "Kolumny obok siebie: paste + column"
run "paste <(ip -o link | awk -F': ' '{print \$2}') <(ip -o link | grep -oE 'state [A-Z]+') | column -t" column

pause
# -----------------------------------------------------------------------------
section "6. Ściągawka regexów (ERE: grep -E, sed -E, awk)"
cheat <<'EOF'
.        dowolny znak            ^ $     początek / koniec linii
*  +  ?  0+ / 1+ / 0-1 razy      {2,4}   od 2 do 4 razy
[0-9]    klasa znaków            [^:]    wszystko OPRÓCZ ':' (najprzydatniejsze do pól!)
( )      grupa (\1 w sed)        a|b     alternatywa
[[:space:]] [[:digit:]] [[:alpha:]]  klasy POSIX (działają wszędzie)
IPv4:    [0-9]{1,3}(\.[0-9]{1,3}){3}
MAC:     ([0-9a-f]{2}:){5}[0-9a-f]{2}
czas:    [0-9]{2}:[0-9]{2}:[0-9]{2}
sed 's/a/b/g'  g = wszystkie wystąpienia  |  sed -i.bak = edycja pliku z kopią
awk -v x="$VAR" '...'  — przekazanie zmiennej shella do awk (nie wklejaj $VAR w kod awk!)
EOF
