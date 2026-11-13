#!/usr/bin/env bash
# =============================================================================
#  02 — Pamięć: free, /proc/meminfo, vmstat, swap, OOM killer
# =============================================================================
#  Pytania diagnostyczne:
#    * czy brakuje RAM, czy to "tylko cache"?  -> free -h (kolumna available)
#    * czy system swapuje AKTYWNIE?            -> vmstat 1 (si/so), nie samo "used swap"
#    * kto zabił mój proces?                   -> dmesg | grep -i oom
#    * kto siedzi w swapie?                    -> /proc/*/status VmSwap
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "02 · PAMIĘĆ" "free / meminfo / vmstat / swap / OOM"
need_sudo

# -----------------------------------------------------------------------------
section "1. free -h"
flags "-h" "jednostki czytelne dla człowieka" "-w" "osobno buffers i cache" "-s 2" "odświeżaj co 2 s"
run "free -hw" free | annotate \
  'available' 'used = procesy (bez cache), free = całkowicie nieużyte (zwykle małe i to OK!)||shared = tmpfs + pamięć współdzielona (/dev/shm)||buffers = metadane FS, cache = page cache (treść plików) — odzyskiwalne' \
  '^Mem:' 'KLUCZOWA kolumna: available. Gdy spada do ~0 -> zaczyna się swap / OOM.||"Linux zjadł mi RAM" — nie, cache to dobra rzecz (linuxatemyram.com)' \
  '^Swap:' 'Zajęty swap sam w sobie NIE jest problemem. Problemem jest ciągłe si/so w vmstat.'

pause
# -----------------------------------------------------------------------------
section "2. /proc/meminfo — surowe dane, z których korzysta free"
run "grep -E '^(MemTotal|MemAvailable|Cached|Dirty|Writeback|AnonPages|Shmem|Slab|SReclaimable|SUnreclaim|Committed_AS|CommitLimit|HugePages_Total):' /proc/meminfo" | annotate \
  '^MemAvailable' 'MemAvailable = szacunek kernela: free + odzyskiwalny cache i slab' \
  '^Cached' 'Cached = page cache (pliki w RAM)' \
  '^Dirty' 'Dirty = zmienione strony czekające na zapis (duże => wolny dysk / fsync storm)||progi: vm.dirty_background_ratio / vm.dirty_ratio' \
  '^Writeback' 'Writeback = strony aktualnie zapisywane' \
  '^AnonPages' 'AnonPages = pamięć "anonimowa" procesów (heap, stack) — tego nie da się wyrzucić bez swapu' \
  '^Shmem' 'Shmem = tmpfs + shm. Pełny /tmp na tmpfs zjada RAM!' \
  '^SUnreclaim' 'SUnreclaim = slab jądra, którego NIE da się odzyskać. Rośnie bez końca => leak w kernelu/module.||Szczegóły: sudo slabtop -o | head' \
  '^Committed_AS' 'Committed_AS = ile pamięci procesy "obiecały" sobie zaalokować (overcommit).||vm.overcommit_memory=0 (heurystyka), 1 (zawsze tak), 2 (twardy limit = CommitLimit)'

note "Procent dostępnej pamięci (awk: zapamiętaj dwie wartości, policz w END):"
run "awk '/^MemTotal/{t=\$2} /^MemAvailable/{a=\$2} END{printf \"available: %.1f%% (%d MiB z %d MiB)\\n\", a/t*100, a/1024, t/1024}' /proc/meminfo"

note "Top 8 cache'y slab jądra (root):"
run "slabtop -o -s c | head -15" slabtop root | annotate \
  'OBJS +ACTIVE' 'posortowane po CACHE SIZE. dentry / inode_cache duże = dużo plików w cache (zwykle OK)||kmalloc-* rosnące bez końca = podejrzenie wycieku w sterowniku'

pause
# -----------------------------------------------------------------------------
section "3. vmstat — pamięć + CPU + I/O w czasie"
flags "1 4" "co 1 s, 4 próbki (PIERWSZA linia = średnia od bootu — ignoruj ją!)" \
      "-w" "szerokie kolumny" "-S M" "jednostki MiB" "-s" "statystyki zbiorcze" "-d" "statystyki dysków"
run "vmstat -w 1 4" vmstat | annotate \
  '^ *r +b' 'r = procesy czekające na CPU (r > nproc => CPU saturation)||b = procesy zablokowane na I/O (stan D)||swpd/free/buff/cache w KiB; si/so = swap in/out KiB/s; bi/bo = bloki/s z/na dysk||in = przerwania/s, cs = przełączenia kontekstu/s; us sy id wa st jak w top' \
  '^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[1-9][0-9]* ' 'si > 0 => strony wracają ze swapu. Stale si+so > 0 => THRASHING, brakuje RAM.' \
  '^ *[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +[0-9]+ +0 +0 ' 'si=0 so=0 => swap nie jest aktywnie używany — dobrze' \
  '^ *[0-9]+ +[1-9][0-9]* ' 'b > 0 => procesy czekają na I/O — zobacz lekcję 03 (iostat)'

pause
# -----------------------------------------------------------------------------
section "4. Kto siedzi w swapie? (pętla po /proc + awk)"
note "awk czyta każdy plik status: zapamiętuje Name i Pid, a przy VmSwap > 0 drukuje wiersz"
run "for f in /proc/[0-9]*/status; do awk '/^Name/{n=\$2} /^Pid/{p=\$2} /^VmSwap/{if(\$2>0) printf \"%8d KiB  %s (%s)\\n\", \$2, n, p}' \$f 2>/dev/null; done | sort -nr | head -10" | annotate \
  'KiB' 'Proces z dużym swapem nie musi być problemem — liczy się, czy jest aktywnie podnoszony (si w vmstat).||Wymuszenie powrotu do RAM: swapoff -a && swapon -a (tylko gdy jest dość wolnego RAM!)'

run "swapon --show" swapon | annotate \
  'TYPE' 'TYPE partition / file; PRIO — wyższy priorytet używany pierwszy. zram = skompresowany swap w RAM'
note "Agresywność swapowania: vm.swappiness = $(cat /proc/sys/vm/swappiness 2>/dev/null) (0..200; niżej = później swapuj)"

pause
# -----------------------------------------------------------------------------
section "5. OOM killer — kto i dlaczego zabił proces"
run "dmesg -T | grep -iE 'invoked oom-killer|oom-kill:|Killed process|Out of memory' | tail -20" dmesg root | annotate \
  'invoked oom-killer' 'Ten proces POPROSIŁ o pamięć i wywołał OOM — to nie zawsze ofiara!' \
  'CONSTRAINT_MEMCG' 'CONSTRAINT_MEMCG = limit cgroup (kontener / MemoryMax= w systemd / limits w k8s),||a NIE brak RAM w całym systemie. CONSTRAINT_NONE = globalny brak pamięci.' \
  'Killed process' 'Ofiara: PID, anon-rss = ile realnie zajmowała. W k8s widać to jako OOMKilled (exit 137 = 128+SIGKILL).'

note "Ranking kandydatów do OOM TERAZ (oom_score: większy ginie pierwszy):"
run "for p in /proc/[0-9]*; do s=\$(cat \$p/oom_score 2>/dev/null) && printf '%5s %6s %s\\n' \"\$s\" \"\${p#/proc/}\" \"\$(cat \$p/comm 2>/dev/null)\"; done | sort -nr | head -6" | annotate \
  '^ *[0-9]+ ' 'kolumny: oom_score  PID  nazwa. Ochrona: echo -1000 > /proc/PID/oom_score_adj (albo OOMScoreAdjust=)'
