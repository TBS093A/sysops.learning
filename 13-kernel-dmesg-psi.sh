#!/usr/bin/env bash
# =============================================================================
#  13 — Kernel: dmesg, PSI (pressure), przerwania, moduły, limity, cgroups
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "13 · KERNEL" "dmesg / PSI / interrupts / softirqs / moduły / cgroups / limity"
need_sudo

# -----------------------------------------------------------------------------
section "1. Wersja i parametry startu"
run "uname -a; cat /proc/cmdline" | annotate \
  '^Linux' 'uname -a: kernel, hostname, WERSJA, data kompilacji, architektura' \
  'BOOT_IMAGE|root=' '/proc/cmdline = parametry przekazane przez bootloader (root=, quiet, mitigations=, cgroup_*...)'

pause
# -----------------------------------------------------------------------------
section "2. dmesg — bufor logów jądra"
flags "-T" "czytelny czas (może się rozjeżdżać po suspend)" "-l err,warn" "tylko poziomy" "-w" "śledź na żywo" "-H" "kolor + pager" "-k / journalctl -k" "systemd"
note "kernel.dmesg_restrict = $(cat /proc/sys/kernel/dmesg_restrict) (1 => dmesg tylko dla roota)"
run "dmesg -T -l err,warn | tail -20" dmesg root | annotate \
  'I/O error|blk_update_request|Buffer I/O' 'Błędy I/O dysku => smartctl -a /dev/X, kabel, kontroler. Bardzo poważne' \
  'EXT4-fs error|XFS .*error|BTRFS error' 'Błąd systemu plików — FS może przejść w read-only' \
  'Out of memory|oom' 'OOM killer (lekcja 02)' \
  'segfault' 'segfault at ADRES ip ... in BIBLIOTEKA = crash procesu w userspace' \
  'nf_conntrack: table full' 'tablica conntrack pełna — pakiety giną (lekcja 07)' \
  'link is not ready|Link is Down|NIC Link is' 'zmiana stanu linku karty sieciowej' \
  'hung_task|blocked for more than' 'proces w stanie D > 120 s — zawieszone I/O (NFS, dysk)' \
  'soft lockup|hard LOCKUP|rcu.*stall' 'CPU zablokowany w kernelu — bug sterownika / przeciążony hypervisor' \
  'Call Trace' 'Call Trace = stos jądra przy ostrzeżeniu/błędzie — przyda się w zgłoszeniu buga' \
  'firmware|Firmware' 'brakujący firmware — sprawdź pakiet linux-firmware'
note "Zliczenie komunikatów per podsystem (sed wycina prefiks 'nazwa:' po znaczniku czasu):"
run "dmesg | sed -nE 's/^\\[ *[0-9.]+\\] ([A-Za-z0-9_-]+)[: ].*/\\1/p' | sort | uniq -c | sort -nr | head -12" dmesg root

pause
# -----------------------------------------------------------------------------
section "3. PSI — Pressure Stall Information (najlepszy wskaźnik 'czy system cierpi')"
note "PSI mówi, jaki % czasu zadania CZEKAŁY na zasób. Dostępne od kernela 4.20 (/proc/pressure)."
run "for r in cpu memory io; do echo \"== \$r\"; cat /proc/pressure/\$r; done" | annotate \
  '^some' 'some = % czasu, gdy CO NAJMNIEJ JEDNO zadanie czekało na zasób (avg10/60/300 = średnie z 10 s/1 min/5 min)||total = łączny czas w µs (licznik narastający)' \
  '^full' 'full = % czasu, gdy WSZYSTKIE niebezczynne zadania czekały — realnie zmarnowany czas.||memory full > ~5% lub io full > ~10% stale => poważny problem. cpu full na poziomie hosta zwykle 0' \
  '^== io' 'io some wysokie = dysk spowalnia; porównaj z iostat await (lekcja 03)'
note "Wyłuskanie avg10 dla każdego zasobu (awk: split pola 'avg10=X' po '='):"
run "for r in cpu memory io; do awk -v r=\$r '{split(\$2,a,\"=\"); printf \"%-7s %-5s avg10=%s%%\\n\", r, \$1, a[2]}' /proc/pressure/\$r; done"
note "PSI per usługa/kontener: /sys/fs/cgroup/<ścieżka>/{cpu,memory,io}.pressure"

pause
# -----------------------------------------------------------------------------
section "4. Przerwania i softirqs — rozkład obciążenia sieci na CPU"
run "head -1 /proc/interrupts; grep -iE 'eth|enp|ens|eno|wlan|wlp|virtio|nvme|ahci|mlx|ixgbe|i40e' /proc/interrupts | head -12" | annotate \
  'CPU0' 'kolumny = liczba przerwań na KAŻDYM CPU od startu, potem kontroler i urządzenie' \
  '(eth|enp|ens|virtio|mlx|ixgbe|i40e)' 'przerwania karty sieciowej. Wszystkie na jednym CPU => wąskie gardło przy dużym ruchu||(sprawdź irqbalance, RSS: ethtool -l eth0 / ethtool -L eth0 combined N)'
run "grep -E 'CPU|NET_RX|NET_TX|TIMER|BLOCK' /proc/softirqs" | annotate \
  'NET_RX' 'NET_RX = przetwarzanie odebranych pakietów (softirq). Nierówny rozkład => RPS/RSS.||Wysoki %si w top + jeden CPU na 100% = klasyczny problem dużego ruchu' \
  'BLOCK' 'BLOCK = zakończenia I/O dysków'
note "Dropy na poziomie kernela per CPU (/proc/net/softnet_stat, wartości HEX; kol.1 processed, 2 dropped, 3 time_squeeze):"
run "awk '{printf \"CPU%-3d processed=%-10d dropped=%-6d time_squeeze=%d\\n\", NR-1, strtonum(\"0x\"\$1), strtonum(\"0x\"\$2), strtonum(\"0x\"\$3)}' /proc/net/softnet_stat" | annotate \
  'dropped=[1-9]' 'dropped > 0 => kolejka backlog przepełniona (net.core.netdev_max_backlog)' \
  'time_squeeze=[1-9]' 'time_squeeze > 0 => softirq nie zdążył w budżecie (net.core.netdev_budget)' \
  'processed=' 'strtonum("0x"...) = gawk zamienia HEX na liczbę dziesiętną'

pause
# -----------------------------------------------------------------------------
section "5. Moduły jądra"
run "lsmod | head -15" lsmod | annotate \
  '^Module' 'Module, Size, Used by = ile/które moduły od niego zależą (nie można go wtedy usunąć)' \
  '^nf_|^nft_|^xt_|^ip_tables' 'nf_*/nft_*/xt_* = netfilter (firewall, NAT, conntrack)' \
  '^br_netfilter|^bridge|^overlay|^veth' 'bridge/br_netfilter/overlay/veth = sieć i FS kontenerów' \
  '^wireguard|^tun' 'wireguard / tun = VPN'
run "modinfo -F description -F version -F filename nf_conntrack 2>&1 | head -4" modinfo | annotate \
  'filename' 'modinfo = info o module: opis, parametry (-F parm), plik .ko. Parametry załadowanego: /sys/module/X/parameters/'

pause
# -----------------------------------------------------------------------------
section "6. Limity zasobów"
run "ulimit -a" | annotate \
  'open files' 'open files (-n) = max FD procesu — "Too many open files"' \
  'max user processes' 'max user processes (-u) = limit procesów/wątków użytkownika' \
  'core file size' 'core file size 0 = zrzuty pamięci (core dump) wyłączone' \
  'stack size' 'stack size = rozmiar stosu głównego wątku'
run "cat /proc/sys/fs/file-nr; cat /proc/sys/fs/file-max; cat /proc/sys/kernel/pid_max; cat /proc/sys/kernel/threads-max" | annotate \
  '^[0-9]+	[0-9]+	[0-9]+' 'file-nr: przydzielone FD | wolne | max (globalnie dla systemu)' \
  '^[0-9]+$' 'kolejno: fs.file-max, kernel.pid_max, kernel.threads-max'
note "Limity działającej usługi zawsze sprawdzaj w /proc/PID/limits — nie w ulimit swojego shella!"

pause
# -----------------------------------------------------------------------------
section "7. cgroups — limity kontenerów i usług"
run "stat -fc %T /sys/fs/cgroup; cat /proc/self/cgroup" | annotate \
  'cgroup2fs' 'cgroup2fs = cgroups v2 (zunifikowana hierarchia). tmpfs = v1 (stare)' \
  '^0::' '0::/ścieżka = cgroup tego procesu w v2. Plik limitów: /sys/fs/cgroup/<ścieżka>/memory.max itd.'
run "ls /sys/fs/cgroup/ | head -30" | annotate \
  'memory\.' 'memory.max / memory.current / memory.events (licznik oom_kill!)' \
  'cpu\.' 'cpu.max = "QUOTA PERIOD" — limit CPU (throttling widać w cpu.stat: nr_throttled)'
note "Throttling CPU kontenerów (dla każdej cgroup z limitem — awk czyta cpu.stat):"
run "for f in \$(find /sys/fs/cgroup -name cpu.stat -maxdepth 4 2>/dev/null); do awk -v f=\"\${f%/cpu.stat}\" '/^nr_throttled/{if (\$2>0) print \$2, \"throttled\", f}' \$f; done | sort -nr | head -5" | annotate \
  'throttled' 'nr_throttled > 0 = cgroup uderzała w limit CPU (k8s limits!) — opóźnienia w aplikacji'
