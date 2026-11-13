#!/usr/bin/env bash
# =============================================================================
#  03 — Dyski i I/O: df, lsblk, findmnt, iostat, /proc/diskstats, du, lsof +L1
# =============================================================================
#  Klasyki z dyżurów:
#    * "No space left on device", a df pokazuje wolne miejsce -> df -i (inody!)
#    * df pokazuje pełny dysk, du nie widzi plików -> usunięte, ale otwarte pliki
#    * wszystko muli, load wysoki, CPU idle -> iostat -x (await, %util)
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "03 · DYSKI I I/O" "df / lsblk / findmnt / iostat / du / lsof"
need_sudo

# -----------------------------------------------------------------------------
section "1. df -hT — zajętość systemów plików"
flags "-h" "czytelne jednostki" "-T" "pokaż typ FS" "-x tmpfs" "wyklucz typ" "-i" "INODY zamiast bajtów" "--output=..." "własne kolumny"
run "df -hT -x tmpfs -x devtmpfs -x efivarfs" df | annotate \
  '^Filesystem' 'Size ≠ Used + Avail: ext4 rezerwuje ~5% dla roota (tune2fs -m 1 /dev/X zmniejszy)' \
  ' (9[0-9]|100)% ' '>= 90% — działaj! Szukaj winnych: du -xh / --max-depth=1 | sort -h' \
  '/dev/mapper' '/dev/mapper/* = LVM lub LUKS. Rozszerzanie: lvextend -r -L +50G /dev/vg/lv' \
  '^overlay' 'overlay = warstwy kontenerów Dockera — to TEN SAM dysk co /var/lib/docker' \
  ' ext4 ' 'ext4 — sprawdzanie: fsck (odmontowany!), info: tune2fs -l /dev/X' \
  ' (xfs|btrfs) ' 'xfs: xfs_info / xfs_repair; btrfs: btrfs filesystem usage / (df kłamie przy btrfs!)'

note "Wyłuskaj tylko systemy > 50% (awk: usuń '%' z kolumny 5 i porównaj liczbowo):"
run "df -P | awk 'NR>1 {u=\$5; sub(/%/,\"\",u); if (u+0 > 50) print \$6\" -> \"\$5}'"

run "df -i -x tmpfs -x devtmpfs -x efivarfs" | annotate 'IUse%' 'Inody = liczba plików. 100% IUse => "No space left" mimo wolnych GB.||Typowo: miliony małych plików (sesje PHP, cache, maildir). Szukaj: find / -xdev -type d -size +1M' \
  ' - +- ' 'IUse "-" = FS bez stałej tablicy inodów (btrfs, vfat) — nie dotyczy'

pause
# -----------------------------------------------------------------------------
section "2. lsblk / findmnt — urządzenia blokowe i punkty montowania"
flags "-f" "pokaż FS, LABEL, UUID" "-o KOLUMNY" "własne kolumny (lsblk --help | grep -A60 Available)" "-d" "tylko dyski, bez partycji" "-p" "pełne ścieżki /dev/..."
run "lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS,ROTA,MODEL" lsblk | annotate \
  'ROTA' 'ROTA=1 dysk obrotowy (HDD), 0 = SSD/NVMe' \
  ' disk ' 'disk = całe urządzenie, part = partycja' \
  'raid[0-9]' 'md* = programowy RAID (mdadm). Stan: cat /proc/mdstat' \
  ' lvm ' 'lvm = Logical Volume. Przegląd: pvs, vgs, lvs' \
  ' crypt ' 'crypt = LUKS (cryptsetup status <nazwa>)' \
  'SWAP' '[SWAP] = partycja swap. Aktywne: swapon --show' \
  ' loop' 'loop = plik podmontowany jako dysk (snap, ISO)'

run "findmnt -o TARGET,SOURCE,FSTYPE,OPTIONS -t ext4,xfs,btrfs,nfs,nfs4,vfat,zfs" findmnt | annotate \
  'TARGET' 'findmnt = czytelna wersja /proc/self/mountinfo. findmnt --verify sprawdzi /etc/fstab!' \
  ' rw,' 'rw = odczyt-zapis' \
  ' ro[ ,]' 'ro = tylko do odczytu. Jeśli FS SAM przeszedł w ro => błędy dysku, sprawdź dmesg!' \
  'relatime|noatime' 'noatime/relatime = nie aktualizuj czasu dostępu przy każdym odczycie (wydajność)' \
  'errors=remount-ro' 'errors=remount-ro = przy błędzie ext4 przemontuje się w ro (ochrona danych)'

pause
# -----------------------------------------------------------------------------
section "3. iostat -x — czy dysk jest wąskim gardłem?"
flags "-x" "rozszerzone statystyki" "-z" "pomiń bezczynne urządzenia" "-y" "pomiń pierwszy raport (średnia od bootu)" "1 2" "co 1 s, 2 razy" "-m" "MB/s zamiast KB/s"
run "iostat -xyz 1 2" iostat | annotate \
  '^Device' 'r/s, w/s = IOPS; rkB/s, wkB/s = przepustowość; *_await = średni czas obsługi żądania (ms)||aqu-sz = średnia długość kolejki; %util = % czasu, gdy urządzenie było zajęte' \
  '^sd[a-z] ' 'sd* (SATA/SAS/USB): %util ~100% + await > 20 ms + kolejka > 1 => dysk jest wąskim gardłem' \
  '^nvme' 'NVMe: await < 1 ms to norma. %util 100% NIE znaczy przeciążenia (równoległe kolejki) — patrz await' \
  '^avg-cpu' '%iowait w avg-cpu = CPU bezczynny, bo czeka na I/O'

note "Bez sysstat — surowe liczniki z /proc/diskstats (to samo czyta iostat):"
note "kolumny: 3=nazwa 4=odczyty 8=zapisy 13=ms spędzone na I/O 12=I/O w toku"
run "awk '\$3 !~ /^(loop|ram|dm-)/ && \$4+\$8 > 0 {printf \"%-10s reads=%-10d writes=%-10d in_flight=%-3d io_ms=%d\\n\", \$3, \$4, \$8, \$12, \$13}' /proc/diskstats" | annotate \
  'in_flight=[1-9]' 'in_flight > 0 = żądania aktualnie w toku — stale wysokie = kolejka' \
  'reads=' 'Liczniki narastają od bootu. Policz różnicę z dwóch odczytów co 1 s, żeby mieć IOPS'

note "Ile ten skrypt przeczytał/zapisał z dysku (bez cache):"
run "grep -E '^(read_bytes|write_bytes)' /proc/$$/io" | annotate 'read_bytes' 'read_bytes/write_bytes w /proc/PID/io = realny I/O procesu. Ranking: iotop -o / pidstat -d 1'

pause
# -----------------------------------------------------------------------------
section "4. du — co zajmuje miejsce"
flags "-x" "nie przechodź na inne FS (ważne na /)" "-h" "czytelne" "-d 1" "tylko 1 poziom" "--apparent-size" "rozmiar logiczny (pliki rzadkie!)"
run "du -xh -d1 \$HOME 2>/dev/null | sort -h | tail -8" | annotate \
  '^[0-9.,]+G' 'sort -h rozumie sufiksy K/M/G. Interaktywnie: ncdu -x /'
note "Największe pliki w \$HOME (find -printf + sort):"
run "find \$HOME -xdev -type f -size +100M -printf '%s\\t%p\\n' 2>/dev/null | sort -nr | head -5 | awk -F'\\t' '{printf \"%8.1f MiB  %s\\n\", \$1/1048576, \$2}'"

pause
# -----------------------------------------------------------------------------
section "5. Usunięte, ale wciąż otwarte pliki (df ≠ du)"
run "lsof -nP +L1 2>/dev/null | head -15" lsof root | annotate \
  'NLINK' '+L1 = pliki o liczbie linków < 1, czyli usunięte z katalogu, ale wciąż otwarte' \
  'deleted' 'Proces wciąż trzyma skasowany plik — miejsce NIE zostanie zwolnione do zamknięcia FD.||Fix bez restartu: : > /proc/PID/fd/N  (obcina plik). Na przyszłość: logrotate copytruncate/postrotate'
note "Bez lsof — to samo przez /proc (root widzi wszystkie procesy):"
run "find /proc/[0-9]*/fd -lname '*(deleted)' -printf '%p -> %l\\n' 2>/dev/null | grep -v memfd | head -10" "" root | annotate \
  'deleted' '/proc/PID/fd/N -> ścieżka (deleted). memfd: odfiltrowane — to anonimowe pliki w RAM, nie dysk'
