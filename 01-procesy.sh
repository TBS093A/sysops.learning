#!/usr/bin/env bash
# =============================================================================
#  01 — Procesy: ps, top, pstree, /proc/<PID>
# =============================================================================
#  Pytania diagnostyczne, na które odpowiadają te narzędzia:
#    * co zjada CPU / RAM?           -> ps --sort, top -b
#    * kto jest rodzicem procesu?    -> pstree -p, ps -o ppid
#    * czemu proces "wisi"?          -> STAT (D = czeka na I/O), wchan
#    * ile ma wątków / FD / limitów? -> /proc/PID/status, /proc/PID/limits
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "01 · PROCESY" "ps / top / pstree / /proc — kto, ile, czemu"

# Regex kolumny STAT w `ps aux`: litera stanu + modyfikatory, a za nią START i TIME.
st() { printf ' %s[slNL<+]* +[A-Z0-9][a-z0-9:]+ +[0-9]+:[0-9]+ ' "$1"; }

# -----------------------------------------------------------------------------
section "1. ps aux — klasyczny przegląd wszystkich procesów (styl BSD)"
flags "a" "procesy wszystkich użytkowników (z terminalem)" \
      "u" "format 'user-oriented' (USER, %CPU, %MEM, VSZ, RSS...)" \
      "x" "także procesy BEZ terminala (demony)" \
      "--sort=-%cpu" "sortuj malejąco po CPU (minus = malejąco)"

run "ps aux --sort=-%cpu | head -20" ps | annotate \
  '^USER +PID' 'VSZ = pamięć wirtualna (KiB, zarezerwowana, nie musi być użyta)||RSS = Resident Set Size – realnie zajęta pamięć fizyczna (KiB)||TIME = łączny czas CPU, nie czas działania! %CPU = średnia od startu procesu, nie "teraz"' \
  '\[[a-zA-Z0-9/:_.+-]+\]$' 'nazwa w [nawiasach] = wątek jądra (kworker, ksoftirqd, kswapd...) – nie ma cmdline' \
  "$(st R)" 'STAT R = Running/runnable – wykonuje się lub czeka w kolejce na CPU' \
  "$(st S)" 'STAT S = śpi (czeka na zdarzenie). Modyfikatory: s=lider sesji, l=wielowątkowy,||+=na pierwszym planie terminala, <=wysoki priorytet, N=niski (nice)' \
  "$(st I)" 'STAT I = idle kernel thread — wątek jądra bez pracy, nie liczy się do load' \
  "$(st D)" 'STAT D = uninterruptible sleep – czeka na I/O (dysk/NFS). Dużo D => problem z I/O,||nie da się takiego procesu zabić nawet kill -9; liczy się do load average!' \
  "$(st Z)" 'STAT Z = zombie – proces zakończony, rodzic nie zrobił wait().||Nie zajmuje RAM, tylko wpis w tablicy PID. Napraw/zrestartuj RODZICA (ps -o ppid= -p PID)' \
  "$(st T)" 'STAT T = zatrzymany (Ctrl+Z / SIGSTOP / debugger). Wznowienie: kill -CONT PID'

pause
# -----------------------------------------------------------------------------
section "2. ps -eo — własne kolumny (styl UNIX) + wyłuskiwanie awk"
flags "-e" "wszystkie procesy" \
      "-o pid,ppid,..." "dokładnie te kolumny; '=' po nazwie usuwa nagłówek" \
      "nlwp" "liczba wątków (Number of Light Weight Processes)" \
      "wchan:22" "funkcja jądra, w której proces śpi (szerokość 22)" \
      "etimes" "ile SEKUND proces żyje (etime = format [[dd-]hh:]mm:ss)"

run "ps -eo pid,ppid,user,nlwp,rss,stat,wchan:22,etimes,comm --sort=-rss | head -10" ps | annotate \
  '^ *PID' 'Posortowane po RSS — największe zużycie RAM na górze' \
  'do_epoll_wait|ep_poll' 'do_epoll_wait = proces czeka na zdarzenia (sockety) — typowe dla serwerów, normalne' \
  'futex' 'futex_* = wątek czeka na lock/zmienną warunkową — normalne, chyba że wszystkie wątki stoją (deadlock)' \
  'io_schedule|wait_on_page|folio_wait|nfs|rpc_wait' 'czeka na I/O dysku/NFS — przy STAT=D to wskazuje winowajcę' \
  'hrtimer_nanosleep|do_nanosleep' 'sleep() — proces po prostu odczekuje' \
  'pipe_read|pipe_wait|anon_pipe' 'czeka na dane z potoku'

note "Suma RSS per użytkownik (awk agreguje po kolumnie 1, RSS w KiB -> MiB):"
run "ps -eo user=,rss= | awk '{m[\$1]+=\$2} END{for(u in m) printf \"%-12s %8.1f MiB\\n\", u, m[u]/1024}' | sort -k2 -nr"

note "Ile procesów w każdym stanie (pierwsza litera STAT):"
run "ps -eo stat= | cut -c1 | sort | uniq -c | sort -nr" | annotate \
  ' S$' 'S = śpiące — zwykle zdecydowana większość' \
  ' R$' 'R = działające; jest tu zawsze co najmniej sam ps' \
  ' D$' 'D > 0 przez dłuższy czas -> sprawdź iostat/dmesg (dysk, NFS)' \
  ' Z$' 'zombie – znajdź rodzica: ps -o ppid= -p <PID>'

pause
# -----------------------------------------------------------------------------
section "3. top w trybie wsadowym — nagłówek to mini-dashboard"
flags "-b" "batch: tekst zamiast interfejsu (do pipe/logów)" \
      "-n 1" "jedna iteracja" \
      "-o %MEM" "sortuj po kolumnie" \
      "-H" "pokazuj wątki zamiast procesów"
note "Liczba CPU (nproc) = $(nproc) — z nią porównuj load average"

run "top -b -n 1 | head -5" top | annotate \
  'load average' 'load average 1/5/15 min = średnia liczba procesów R + D.||load > nproc => kolejka do CPU (albo dużo D = I/O). Rosnące 1 > 5 > 15 = narasta' \
  '^Tasks' 'running / sleeping / stopped / zombie — zombie > 0 patrz sekcja 1' \
  ' us,' 'us=user, sy=kernel, ni=nice, id=idle, wa=IO-wait (CPU czeka na dysk!),||hi/si=przerwania hard/soft (si duże => ruch sieciowy), st=steal (hypervisor zabiera CPU VM-ce)' \
  'buff/cache' 'buff/cache to cache plików — jądro odda je, gdy trzeba. Patrz "avail Mem", nie "free"' \
  'avail Mem' 'avail Mem = ile realnie możesz zaalokować bez swapowania'

note "Wyłuskanie samego %wa (sed -n + /p: wypisz tylko linie, gdzie podstawienie się udało):"
run "top -bn1 | sed -nE 's/.* ([0-9.]+) wa,.*/IO-wait: \\1%/p'" top
note "Load vs liczba CPU (awk liczy z /proc/loadavg):"
run "awk -v n=\$(nproc) '{printf \"load1=%s  cpus=%d  => %.0f%% wykorzystania kolejki\\n\", \$1, n, \$1/n*100}' /proc/loadavg"

pause
# -----------------------------------------------------------------------------
section "4. pstree — drzewo rodzic/dziecko"
flags "-p" "pokaż PID-y" "-a" "pokaż argumenty" "-s PID" "pokaż przodków danego PID" "-u" "zmiany UID"
run "pstree -p | head -25" pstree | annotate \
  '\{[^}]+\}' '{nazwa} w klamrach = WĄTEK procesu, nie osobny proces' \
  '---' '--- łączy rodzica z jedynym dzieckiem, -+- rozgałęzienie' \
  '^(systemd|init|runit)' 'PID 1 = init systemu (systemd / runit / openrc / init) — przodek wszystkich procesów'
note "Ten sam efekt bez psmisc (-N --ppid 2 = wszystko OPRÓCZ wątków jądra, dzieci kthreadd):"
run "ps -N --ppid 2 --forest -o pid,ppid,user,comm | head -25" | annotate \
  '\\_' '\_ = dziecko procesu z linii wyżej (wcięcie = głębokość w drzewie)'

pause
# -----------------------------------------------------------------------------
section "5. /proc/<PID> — źródło prawdy dla ps/top"
P=$$
note "Bierzemy PID tego skryptu: $P"
run "grep -E '^(Name|State|PPid|Threads|VmRSS|VmSwap|voluntary_ctxt|nonvoluntary_ctxt)' /proc/$P/status" | annotate \
  '^State' 'State — to samo co STAT w ps' \
  '^VmRSS' 'VmRSS = to samo co RSS w ps' \
  '^VmSwap' 'VmSwap = ile tego procesu wylądowało w swapie' \
  '^voluntary' 'voluntary = proces sam oddał CPU (czeka na I/O/lock) — typowe dla I/O-bound' \
  '^nonvoluntary' 'nonvoluntary = kernel wywłaszczył (koniec kwantu) — dużo => CPU-bound/za mało CPU'

run "grep -E 'open files|processes|locked' /proc/$P/limits" | annotate \
  'open files' '"Too many open files" => ten limit (ulimit -n / LimitNOFILE= w systemd / nofile w limits.conf)' \
  'processes' 'max procesów/wątków użytkownika — "fork: Resource temporarily unavailable"'

run "ls -l /proc/$P/fd" | annotate \
  '-> /dev/(pts|tty|null)' 'fd 0/1/2 = stdin/stdout/stderr' \
  'pipe:' 'pipe:[inode] — potok między procesami (np. nasz | annotate)' \
  'socket:' 'socket:[inode] — inode zmapujesz na połączenie przez: ss -tanpe | grep ino:INODE'

note "Inne skarby: /proc/PID/cmdline (argumenty rozdzielone \\0), /proc/PID/environ,"
note "/proc/PID/cwd, /proc/PID/exe, /proc/PID/stack (root), /proc/PID/smaps_rollup (Pss, Swap)"
run "tr '\\0' ' ' < /proc/$P/cmdline; echo"
run "cat /proc/$P/smaps_rollup | head -8" | annotate \
  '^Rss' 'Rss liczy strony współdzielone (biblioteki) w CAŁOŚCI dla każdego procesu' \
  '^Pss' 'Pss = proportional: strony współdzielone dzielone przez liczbę procesów — uczciwa suma'
