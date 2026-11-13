#!/usr/bin/env bash
# =============================================================================
#  15 — Obserwowalność jądra: ftrace (zawsze dostępny), bpftrace (eBPF), perf
# =============================================================================
#  ps/top/iostat pokazują STAN i ŚREDNIE. Te narzędzia pokazują ZDARZENIA:
#  każdy exec, każde open(), każde połączenie, każdą retransmisję, rozkład
#  opóźnień — prawie bez narzutu i bez restartu aplikacji.
#
#  Każda sekcja sama generuje ruch/obciążenie, a w tym czasie śledzi system,
#  więc output pochodzi z Twojej maszyny. Programy bpftrace leżą w bpf/*.bt.
#  Wymaga roota (sudo). ftrace jest w każdym kernelu; bpftrace i perf to pakiety.
# =============================================================================
D="$(cd "$(dirname "$0")" && pwd)"
source "$D/lib/common.sh"
PKG[bpftrace]="bpftrace"
PKG[perf]="perf | linux-perf | perf | perf"

lesson_header "15 · eBPF / PERF / FTRACE" "śledzenie zdarzeń w jądrze na żywo"
need_sudo

# Obciążenie testowe: kilka execów, otwarć plików, połączenie TCP, trochę I/O.
WORK="(sleep 1.5; ls /etc >/dev/null; cat /etc/hostname /nie/ma/takiego >/dev/null 2>&1; curl -s -o /dev/null -m 5 https://example.com; dd if=/dev/zero of=/var/tmp/.sysops-io bs=1M count=20 oflag=direct status=none; rm -f /var/tmp/.sysops-io) >/dev/null 2>&1 &"

# -----------------------------------------------------------------------------
section "0. Czy kernel jest gotowy?"
run "uname -r; ls -l /sys/kernel/btf/vmlinux; cat /proc/sys/kernel/perf_event_paranoid; cat /proc/sys/kernel/unprivileged_bpf_disabled" | annotate \
  '/sys/kernel/btf/vmlinux' 'BTF = opis typów jądra. Jest => bpftrace/CO-RE działają bez nagłówków kernela' \
  '^[0-9]+\.[0-9]+' 'eBPF z sensownymi możliwościami: kernel >= 4.18, wygodnie >= 5.8' \
  '^-?[0-9]$' 'perf_event_paranoid: -1 wszystko dla wszystkich, 0/1 = ograniczenia, 2 = user tylko własne procesy, bez kernela||unprivileged_bpf_disabled: 1/2 = eBPF tylko dla roota (bezpieczne ustawienie)'

pause
# -----------------------------------------------------------------------------
section "1. ftrace — wbudowany tracer jądra (bez instalowania czegokolwiek)"
note "tracefs: /sys/kernel/tracing. Włączamy zdarzenie sched_process_exec na 4 s, potem SPRZĄTAMY (enable=0)."
FT='T=/sys/kernel/tracing; [ -d $T/events ] || T=/sys/kernel/debug/tracing; echo > $T/trace; echo 1 > $T/events/sched/sched_process_exec/enable; echo 1 > $T/events/sched/sched_process_exit/enable; '"$WORK"' timeout 4 cat $T/trace_pipe; echo 0 > $T/events/sched/sched_process_exec/enable; echo 0 > $T/events/sched/sched_process_exit/enable'
run "$FT" "" root | annotate \
  'sched_process_exec' 'TASK-PID [CPU] FLAGI CZAS: zdarzenie: pola. sched_process_exec = proces wykonał execve()||filename = program, pid, old_pid' \
  'sched_process_exit' 'sched_process_exit = proces się zakończył (comm, pid, prio)' \
  '\[[0-9]{3}\]' '[00N] = numer CPU; ciąg typu "....." = flagi: przerwania wyłączone, need-resched, kontekst hardirq/softirq' \
  'curl' 'Widać nasz curl, ls, cat, dd — także procesy żyjące milisekundy'
cheat <<'EOF'
cat /sys/kernel/tracing/available_events | grep -E '^(tcp|sock|block|sched|syscalls):' | head
echo function_graph > /sys/kernel/tracing/current_tracer   # graf wywołań funkcji jądra (ciężkie!)
echo nop > /sys/kernel/tracing/current_tracer              # wyłącz
trace-cmd record -e sched_switch sleep 5; trace-cmd report  # wygodny frontend (pakiet trace-cmd)
EOF

pause
# -----------------------------------------------------------------------------
section "2. bpftrace: execsnoop — każdy uruchomiony program"
run "$WORK timeout 5 bpftrace $D/bpf/execsnoop.bt" bpftrace root | annotate \
  '^Attaching' 'bpftrace kompiluje program do bajtkodu eBPF, weryfikator jądra go sprawdza, potem podpina pod tracepoint' \
  '^TIME' 'TIME od startu, PID, PPID, RODZIC = comm procesu, który wywołał execve, PROGRAM = co uruchomił' \
  ' /usr/bin/(ls|cat|curl|dd)' 'Wszystkie procesy z naszego obciążenia — nawet te, które żyły 1 ms'
note "Klasyczne użycie: load wysoki, top nic nie pokazuje => execsnoop odkrywa pętlę krótkich procesów."

pause
# -----------------------------------------------------------------------------
section "3. bpftrace: opensnoop — otwierane pliki i błędy"
run "$WORK timeout 5 bpftrace $D/bpf/opensnoop.bt | grep -vE ' (bpftrace|sudo|timeout) ' | head -30" bpftrace root | annotate \
  '^PID' 'FD >= 0 = sukces, -2 = ENOENT (brak pliku), -13 = EACCES (brak uprawnień)' \
  ' -2 /nie/ma' 'Nasz celowy błąd: cat /nie/ma/takiego -> ENOENT. Tak szukasz "gdzie program szuka configu"' \
  ' -2 ' 'ENOENT — pliku nie ma. Dużo takich = aplikacja przeszukuje wiele ścieżek (np. ładowanie bibliotek)'

pause
# -----------------------------------------------------------------------------
section "4. bpftrace: połączenia TCP i retransmisje"
run "$WORK timeout 6 bpftrace $D/bpf/tcpconnect.bt" bpftrace root | annotate \
  'CONNECT' 'CONNECT = gniazdo przeszło w SYN_SENT: proces, PID i adres:port celu. Widzisz KAŻDE wyjście w świat.||Świetne do audytu: "z czym ta aplikacja się łączy?"' \
  'RETRANS' 'RETRANS = retransmisja segmentu z adresami. Seria do jednego celu => straty na tej ścieżce'

pause
# -----------------------------------------------------------------------------
section "5. bpftrace: biolatency — histogram opóźnień dysku"
note "Generujemy zapis z O_DIRECT (dd oflag=direct omija cache, więc trafia na dysk)."
run "$WORK timeout -s INT 6 bpftrace $D/bpf/biolatency.bt" bpftrace root | annotate \
  '^@usecs' 'Histogram log2: [od, do) mikrosekund | liczba żądań | słupek' \
  '\[[0-9]+, [0-9]+[KM]?\)' 'Każdy wiersz = przedział czasu. Szukaj "ogona": kilka żądań w [512K, 1M) = pół sekundy czekania!||SSD/NVMe: zwykle dziesiątki-setki µs. HDD: ms. Dwa garby = dwa rodzaje I/O (np. cache kontrolera vs talerz)'

pause
# -----------------------------------------------------------------------------
section "6. bpftrace: syscalle i profil CPU wg procesu"
run "$WORK timeout -s INT 5 bpftrace $D/bpf/syscount.bt" bpftrace root | annotate \
  'TOP syscalle' '@syscalls[comm] = count() — mapa (tablica) zliczana w jądrze, drukowana na końcu' \
  'TOP próbki' 'profile:hz:99 — 99 próbek/s na CPU; więcej próbek = częściej na CPU (99 ≈ 1 pełny rdzeń przez 1 s)'

pause
# -----------------------------------------------------------------------------
section "7. perf — liczniki sprzętowe i profilowanie"
run "perf stat -e task-clock,context-switches,cpu-migrations,page-faults,cycles,instructions -- python3 -c 'sum(i*i for i in range(3*10**6))' 2>&1 | grep -vE '^\$'" perf | annotate \
  'task-clock' 'task-clock = czas CPU w ms; "CPUs utilized" = ile rdzeni średnio zajmował' \
  'context-switches' 'context-switches / cpu-migrations — dużo migracji = proces skacze między CPU (cache misses)' \
  'page-faults' 'page-faults = pierwsze dotknięcia stron pamięci (alokacje)' \
  'instructions' 'instructions / cycles = IPC. IPC < 1 => CPU czeka na pamięć (memory-bound), > 2 = wydajny kod' \
  'not supported|not counted' '<not supported> = brak liczników PMU (typowe w maszynach wirtualnych)'
run "perf record -F 499 -g -o /tmp/.sysops-perf.data -- python3 -c 'import json; [json.dumps(list(range(500))) for _ in range(20000)]' 2>&1 | tail -2; perf report -i /tmp/.sysops-perf.data --stdio --no-children --sort comm,dso,symbol 2>/dev/null | grep -E '^ +[0-9]' | head -12; rm -f /tmp/.sysops-perf.data" perf | annotate \
  'perf record' 'record: -F 499 = próbkowanie 499 Hz, -g = zapisuj stosy wywołań (do flame graphów)' \
  '%' 'report: % próbek w danej funkcji. [k] = funkcja jądra, [.] = userspace. Tak znajdujesz gorącą pętlę'
cheat <<'EOF'
perf top -g                                   # "top" dla funkcji (cały system, root)
perf record -F 99 -a -g -- sleep 30           # profil całego systemu przez 30 s
perf script | stackcollapse-perf.pl | flamegraph.pl > flame.svg   # flame graph (FlameGraph Brendana Gregga)
perf trace -s -p PID                          # jak strace, ale tańszy
EOF

pause
# -----------------------------------------------------------------------------
section "8. Dalej: gotowe narzędzia bcc / bpftrace"
run "ls /usr/share/bcc/tools 2>/dev/null | head -40 | column -c 120; ls /usr/share/bpftrace/tools 2>/dev/null | column -c 120; ls /usr/sbin/*-bpfcc 2>/dev/null | head" | annotate \
  'execsnoop|opensnoop' 'bcc tools: execsnoop, opensnoop, tcpconnect, tcpretrans, tcplife, biolatency, runqlat, ext4slower,||cachestat, oomkill, killsnoop... Debian: nazwa-bpfcc, Void/Arch: /usr/share/bcc/tools/nazwa'
note "Brak listy = pakiety nieinstalowane. Void: xbps-query -Rs bcc ; xbps-install bpftrace | Debian: apt install bpfcc-tools bpftrace"
note "Polecane: 'BPF Performance Tools' i '60-second Linux analysis' Brendana Gregga — ta lekcja to ich skrót."
