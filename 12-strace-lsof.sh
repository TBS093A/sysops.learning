#!/usr/bin/env bash
# =============================================================================
#  12 — strace i lsof: co proces REALNIE robi (syscalle, pliki, sockety)
# =============================================================================
#  strace przechwytuje wywołania systemowe (open, read, connect...). Na
#  produkcji używaj ostrożnie: spowalnia proces kilkukrotnie (ptrace).
#  Lekcja śledzi wyłącznie procesy, które sama uruchamia.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "12 · STRACE + LSOF" "syscalle / błędy / czasy / pliki / sockety"

# -----------------------------------------------------------------------------
section "1. strace -c — statystyka syscalli (gdzie proces spędza czas w kernelu)"
flags "-c" "tabelka podsumowania zamiast logu" "-f" "śledź też dzieci/wątki" "-p PID" "podepnij się do działającego procesu" \
      "-e trace=..." "file, network, process, memory, signal, %file, openat,connect" \
      "-T" "czas trwania każdego syscalla" "-tt" "znacznik czasu" "-s 200" "dłuższe stringi" "-o plik" "zapis do pliku" "-y" "pokazuj ścieżki zamiast numerów FD"
run "strace -c -f ls -R /etc > /dev/null" strace | annotate \
  '% time' '% time = udział w czasie spędzonym w syscallach; calls = liczba; errors = ile zwróciło błąd' \
  'getdents64' 'getdents64 = czytanie zawartości katalogów (tu ls -R)' \
  'newfstatat|statx' 'stat = metadane plików' \
  'openat' 'openat = otwieranie plików — errors tu = pliki, do których nie mamy prawa (EACCES)' \
  '^-+ ' 'Duże errors przy openat/stat => aplikacja szuka plików, których nie ma (zła ścieżka, config)'

pause
# -----------------------------------------------------------------------------
section "2. Jakie pliki otwiera program? (najczęstsze pytanie: skąd czyta config?)"
run "strace -f -e trace=openat,access -y bash -c 'cat /etc/hostname' 2>&1 | grep -vE 'ld.so|\\.so' | head -15" strace | annotate \
  'openat\(AT_FDCWD' 'openat(AT_FDCWD, "ścieżka", flagi) = FD — AT_FDCWD = względem bieżącego katalogu' \
  'ENOENT' '= -1 ENOENT = pliku nie ma. Tak znajdziesz, gdzie program SZUKA configu' \
  'EACCES|EPERM' 'EACCES/EPERM = brak uprawnień (SELinux/AppArmor też dają EACCES)' \
  'O_RDONLY' 'O_RDONLY / O_WRONLY|O_CREAT|O_TRUNC = tryb otwarcia' \
  '\+\+\+ exited' '+++ exited with N +++ = proces się zakończył z kodem N'
note "Wyłuskaj tylko NIEISTNIEJĄCE pliki, których szukał program (sed z grupą na ścieżkę):"
run "strace -f -e trace=openat,stat,newfstatat,access bash -lc true 2>&1 | sed -nE 's/.*\"([^\"]+)\".*ENOENT.*/\\1/p' | sort -u | head" strace | annotate \
  '^/' 'Pliki, które bash -l próbował wczytać, a których nie ma (profile, rc). Tak debuguje się "nie czyta mi .bashrc"'

pause
# -----------------------------------------------------------------------------
section "3. Ruch sieciowy procesu: connect(), DNS"
run "strace -f -e trace=socket,connect,sendto,recvfrom -s 60 curl -s -o /dev/null https://example.com 2>&1 | grep -vE 'resumed|SIGCHLD' | head -15" strace | annotate \
  'socket\(AF_INET' 'socket(rodzina, typ, protokół) = FD — AF_INET=IPv4, AF_INET6=IPv6, AF_UNIX=lokalne' \
  'connect\(.*53\)' 'connect na port 53 = zapytanie DNS (resolver libc pyta serwer z resolv.conf)' \
  'connect\(.*443' 'connect na 443 = połączenie HTTPS. EINPROGRESS = connect nieblokujący (normalne)' \
  'ECONNREFUSED' 'ECONNREFUSED = RST — nic nie słucha / REJECT' \
  'ETIMEDOUT' 'ETIMEDOUT = brak odpowiedzi — DROP / brak trasy' \
  'nscd|AF_UNIX' 'AF_UNIX do /run/nscd lub /var/run/nscd = libc pyta lokalny cache nazw'

pause
# -----------------------------------------------------------------------------
section "4. strace -T — które syscalle są wolne?"
run "strace -T -e trace=connect,openat,read curl -s -o /dev/null https://example.com 2>&1 | awk -F'<' 'NF>1 {t=\$NF; sub(/>.*/, \"\", t); if (t+0 > 0.005) print t \"s  \" \$1}' | sort -nr | head -8" strace | annotate \
  '^[0-9.]+s ' '<czas> na końcu linii strace -T = ile trwał syscall. awk -F"<" bierze ostatnie pole.||Długi read/recvfrom = czekanie na sieć/dysk; długi futex = czekanie na lock; długi connect = sieć'

cheat <<'EOF'
strace -f -p PID -e trace=network -tt -T          # podepnij do usługi (root / ptrace_scope=0)
strace -ff -o /tmp/tr -p PID                      # osobny plik per wątek: /tmp/tr.<TID>
strace -e trace=%file -e status=failed PROGRAM    # tylko NIEUDANE operacje na plikach
cat /proc/sys/kernel/yama/ptrace_scope            # 1 = tylko potomkowie (dlatego -p wymaga roota)
EOF
note "Twoje kernel.yama.ptrace_scope = $(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo brak) (0=każdy, 1=tylko potomkowie, 2=admin, 3=nikt)"

pause
# -----------------------------------------------------------------------------
section "5. lsof — otwarte pliki i sockety"
flags "-i" "sockety sieciowe (-i :443, -i TCP, -i @10.0.0.5)" "-nP" "bez DNS i nazw portów" "-p PID" "pliki procesu" \
      "-u USER" "pliki użytkownika" "+D /dir" "kto trzyma pliki w katalogu (umount: target is busy!)" "-t" "same PID-y (do kill)"
run "lsof -nP -i -sTCP:LISTEN" lsof root | annotate \
  'COMMAND +PID' 'COMMAND PID USER FD TYPE ... NAME — FD 3u = deskryptor 3, u=read+write (r/w)' \
  'IPv6' 'TYPE IPv4/IPv6; NAME = adres:port (LISTEN)'
run "lsof -nP -p $$ | head -15" lsof | annotate \
  ' cwd ' 'cwd = katalog bieżący; txt = plik wykonywalny; mem = zmapowane biblioteki' \
  ' [0-9]+[urw] ' 'deskryptory numeryczne: 0/1/2 = stdin/out/err'
note "Bez lsof: /proc/PID/fd i /proc/net/tcp (lekcja 14 dekoduje /proc/net/tcp awk-iem)"
note "Kto blokuje umount?   lsof +f -- /mnt/punkt   albo   fuser -vm /mnt/punkt"
