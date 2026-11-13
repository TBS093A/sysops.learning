#!/usr/bin/env bash
# =============================================================================
#  health-check.sh — szybki przegląd systemu metodą USE (Brendan Gregg)
# =============================================================================
#  Dla każdego zasobu: Utilization (zajętość), Saturation (kolejka/czekanie),
#  Errors (błędy). Wypisuje stan OK / UWAGA / ŹLE, przy problemach mówi, co
#  sprawdzić dalej i w której lekcji jest o tym mowa.
#
#  ./health-check.sh            (bez roota — część sprawdzeń pominięta)
#  sudo ./health-check.sh       (pełny: dmesg, wszystkie procesy)
#  ./health-check.sh -q         tylko problemy
#  Kod wyjścia = liczba stanów ŹLE (przydatne w cronie/monitoringu).
# =============================================================================
source "$(dirname "$0")/lib/common.sh"
QUIET=""; [[ "${1:-}" == -q ]] && QUIET=1
NCPU=$(nproc)
CRIT=0; WARNS=0

# st POZIOM ZASÓB TYP "pomiar" "co dalej"
st() {
  local lvl=$1 res=$2 typ=$3 msg=$4 next=${5:-} tag col
  case $lvl in
    ok)   tag=" OK  "; col=$C_EXPL ;;
    warn) tag="UWAGA"; col=$'\e[1;33m'; ((WARNS++)) ;;
    crit) tag=" ŹLE "; col=$C_WARN; ((CRIT++)) ;;
    skip) tag="  -  "; col=$C_DIM ;;
  esac
  [[ -z $C_RESET ]] && col=""
  [[ -n $QUIET && ( $lvl == ok || $lvl == skip ) ]] && return
  # printf liczy BAJTY, a "PAMIĘĆ" ma znaki 2-bajtowe — dopełniamy ręcznie wg ${#res} (znaki)
  printf '%s[%s]%s %s%*s %-4s %s\n' "$col" "$tag" "$C_RESET" "$res" $((9 - ${#res})) '' "$typ" "$msg"
  [[ -n $next && $lvl != ok ]] && printf '%s                       └─▶ %s%s\n' "$C_DIM" "$next" "$C_RESET"
  return 0
}
lvl() { awk -v v="$1" -v w="$2" -v c="$3" 'BEGIN{print (v+0 >= c ? "crit" : v+0 >= w ? "warn" : "ok")}'; }

# --- próbka 1 s: /proc/stat, /proc/vmstat, /proc/diskstats, /proc/net/snmp ---
snap() {
  awk '/^cpu /{print "cpu", $2+$3+$4+$7+$8+$9, $5, $6, $9}' /proc/stat
  awk '/^(pswpin|pswpout|oom_kill) /{print $1, $2}' /proc/vmstat
  awk '$3 !~ /^(loop|ram|dm-|zram|sr)/ && $3 !~ /[0-9]p[0-9]+$/ && $3 !~ /^sd[a-z]+[0-9]+$/ {print "disk", $3, $13}' /proc/diskstats
  awk '/^Tcp: [0-9]/{print "tcp", $12, $13}' /proc/net/snmp
}
mapfile -t A < <(snap); sleep 1; mapfile -t B < <(snap)
delta() { # delta KLUCZ[ POLE] — różnica pola między próbkami
  local k=$1 f=${2:-2}
  awk -v k="$k" -v f="$f" 'NR==FNR{if ($1" "$2==k || $1==k) a=$f; next} ($1" "$2==k || $1==k){print $f - a}' \
      <(printf '%s\n' "${A[@]}") <(printf '%s\n' "${B[@]}")
}

lesson_header "HEALTH CHECK (USE)" "host: $(hostname)  kernel: $(uname -r)  CPU: $NCPU  $(is_root || echo '(bez roota — część sprawdzeń pominięta)')"
printf '\n'

# ============================== CPU ==========================================
read -r _ busy1 idle1 iow1 _ <<<"$(printf '%s\n' "${A[@]}" | grep '^cpu')"
read -r _ busy2 idle2 iow2 _ <<<"$(printf '%s\n' "${B[@]}" | grep '^cpu')"
tot=$(( (busy2-busy1) + (idle2-idle1) + (iow2-iow1) )); ((tot==0)) && tot=1
cpu_util=$(( 100 * (busy2-busy1) / tot )); cpu_wa=$(( 100 * (iow2-iow1) / tot ))
st "$(lvl $cpu_util 80 95)" CPU U "zajętość ${cpu_util}% (1 s), iowait ${cpu_wa}%" "lekcja 01: top -bn1, ps --sort=-%cpu; per CPU: mpstat -P ALL 1"
read -r l1 l5 l15 _ < /proc/loadavg
lr=$(awk -v l="$l1" -v n="$NCPU" 'BEGIN{printf "%.0f", l/n*100}')
st "$(lvl "$lr" 100 200)" CPU S "load1=$l1 / $NCPU CPU = ${lr}% (5m=$l5 15m=$l15)" "load liczy też stan D (I/O)! lekcja 01: ps -eo stat | cut -c1 | sort | uniq -c"
if [[ -r /proc/pressure/cpu ]]; then
  psi=$(awk '/^some/{split($2,a,"="); print a[2]}' /proc/pressure/cpu)
  st "$(lvl "$psi" 20 50)" CPU S "PSI some avg10=${psi}% (czas, gdy zadania czekały na CPU)" "lekcja 13: /proc/pressure/cpu; throttling cgroup: cpu.stat nr_throttled"
fi
thr=$(for f in $(find /sys/fs/cgroup -maxdepth 4 -name cpu.stat 2>/dev/null); do awk '/^nr_throttled/{s+=$2} END{print s+0}' "$f"; done | awk '{s+=$1} END{print s+0}')
st "$( ((thr>0)) && echo warn || echo ok)" CPU E "throttling cgroup: nr_throttled=$thr" "lekcja 13 sekcja 7 — które cgroup uderzają w limit CPU"

# ============================== PAMIĘĆ =======================================
avail=$(awk '/^MemTotal/{t=$2} /^MemAvailable/{a=$2} END{printf "%.0f", 100-a/t*100}' /proc/meminfo)
st "$(lvl "$avail" 85 95)" PAMIĘĆ U "użyte ${avail}% (wg MemAvailable)" "lekcja 02: free -h, ps --sort=-rss"
si=$(delta pswpin); so=$(delta pswpout)
sw=$((si + so))
st "$( ((sw>100)) && echo crit || { ((sw>0)) && echo warn || echo ok; })" PAMIĘĆ S "swap in/out: ${si}/${so} stron/s" "aktywne swapowanie => brakuje RAM. lekcja 02: vmstat 1"
if [[ -r /proc/pressure/memory ]]; then
  pm=$(awk '/^full/{split($2,a,"="); print a[2]}' /proc/pressure/memory)
  st "$(lvl "$pm" 5 20)" PAMIĘĆ S "PSI full avg10=${pm}%" "lekcja 13: /proc/pressure/memory"
fi
oom=$(awk '/^oom_kill /{print $2}' /proc/vmstat)
st "$( ((${oom:-0}>0)) && echo warn || echo ok)" PAMIĘĆ E "OOM kills od startu: ${oom:-?}" "lekcja 02 sekcja 5: dmesg -T | grep -i 'killed process'"

# ============================== DYSKI ========================================
while read -r used mnt; do
  st "$(lvl "${used%\%}" 85 95)" DYSK U "$mnt zajęte $used" "lekcja 03: du -xh $mnt -d1 | sort -h"
done < <(df -P -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1{print $5, $6}')
while read -r used mnt; do
  [[ $used == - ]] && continue
  l=$(lvl "${used%\%}" 85 95); [[ $l != ok ]] && st "$l" DYSK U "$mnt INODY $used" "lekcja 03: df -i — miliony małych plików"
done < <(df -Pi -x tmpfs -x devtmpfs -x efivarfs -x overlay -x squashfs 2>/dev/null | awk 'NR>1{print $5, $6}')
for dev in $(printf '%s\n' "${B[@]}" | awk '$1=="disk"{print $2}'); do
  ms=$(delta "disk $dev" 3)
  util=$(( ms / 10 ))
  st "$(lvl "$util" 80 95)" DYSK U "$dev %util ${util}% (1 s)" "lekcja 03: iostat -xz 1 — patrz await (dla NVMe %util nie jest miarą przeciążenia)"
done
if [[ -r /proc/pressure/io ]]; then
  pio=$(awk '/^full/{split($2,a,"="); print a[2]}' /proc/pressure/io)
  st "$(lvl "$pio" 10 30)" DYSK S "PSI io full avg10=${pio}%" "lekcja 03 / 13"
fi
dcnt=$(ps -eo stat= | grep -c '^D')
st "$( ((dcnt>3)) && echo warn || echo ok)" DYSK S "procesy w stanie D (czekają na I/O): $dcnt" "lekcja 01: ps -eo pid,stat,wchan:30,comm | awk '\$2 ~ /^D/'"
ro=$(findmnt -rno TARGET,FSTYPE,OPTIONS -t ext4,xfs,btrfs 2>/dev/null | awk '$3 ~ /(^|,)ro(,|$)/{print $1}' | tr '\n' ' ')
st "$([[ -n $ro ]] && echo crit || echo ok)" DYSK E "systemy plików tylko-do-odczytu: ${ro:-brak}" "FS przeszedł w ro => błędy dysku. lekcja 13: dmesg -T -l err"
if is_root || [[ $(cat /proc/sys/kernel/dmesg_restrict) == 0 ]]; then
  ioerr=$(dmesg 2>/dev/null | grep -ciE 'I/O error|blk_update_request|EXT4-fs error|XFS .*error|BTRFS error|medium error')
  st "$( ((ioerr>0)) && echo crit || echo ok)" DYSK E "błędy I/O / FS w dmesg: $ioerr" "lekcja 13: dmesg -T | grep -iE 'I/O error|fs error'; smartctl -a /dev/X"
else
  st skip DYSK E "błędy w dmesg — wymaga roota"
fi

# ============================== SIEĆ =========================================
for i in /sys/class/net/*; do
  n=${i##*/}; [[ $n == lo ]] && continue
  e=$(( $(cat "$i/statistics/rx_errors") + $(cat "$i/statistics/tx_errors") ))
  d=$(( $(cat "$i/statistics/rx_dropped") + $(cat "$i/statistics/tx_dropped") ))
  oper=$(cat "$i/operstate")
  [[ $oper != up && $(cat "$i/flags") != 0x1003 ]] && continue
  st "$( ((e>0)) && echo warn || echo ok)" SIEĆ E "$n ($oper) errors=$e dropped=$d (od startu)" "lekcja 04: ip -s link, ethtool -S $n | grep -iE 'err|drop'"
done
rs=$(delta tcp 2); os=$(delta tcp 3)
rp=$(awk -v r="$os" -v o="$rs" 'BEGIN{printf "%.1f", (o>0 ? r/o*100 : 0)}')
st "$(lvl "$rp" 2 10)" SIEĆ E "retransmisje TCP ${rp}% (${os}/${rs} segm. w 1 s)" "lekcja 05: nstat -az TcpRetransSegs; ss -ti; lekcja 16: jak wygląda strata"
lo=$(awk '/^TcpExt:/{if(!h){split($0,k);h=1}else{split($0,v); for(i in k) if(k[i]=="ListenOverflows") print v[i]}}' /proc/net/netstat)
st "$( ((${lo:-0}>0)) && echo warn || echo ok)" SIEĆ S "ListenOverflows od startu: ${lo:-?} (pełna kolejka accept)" "lekcja 05 sekcja 1: ss -tln (Recv-Q vs Send-Q); lab scenariusz 5"
sd=$(awk '{d+=strtonum("0x"$2); s+=strtonum("0x"$3)} END{print d, s}' /proc/net/softnet_stat)
st "$( [[ ${sd%% *} -gt 0 ]] && echo warn || echo ok)" SIEĆ S "softnet dropped/time_squeeze: ${sd/ //}" "lekcja 13 sekcja 4: /proc/net/softnet_stat, netdev_max_backlog"
if [[ -r /proc/sys/net/netfilter/nf_conntrack_count ]]; then
  ct=$(awk 'NR==FNR{c=$1; next}{printf "%.0f", c/$1*100}' /proc/sys/net/netfilter/nf_conntrack_count /proc/sys/net/netfilter/nf_conntrack_max)
  st "$(lvl "$ct" 70 90)" SIEĆ U "conntrack ${ct}% ($(cat /proc/sys/net/netfilter/nf_conntrack_count)/$(cat /proc/sys/net/netfilter/nf_conntrack_max))" "lekcja 07 sekcja 3"
fi
cw=$(ss -Htan state close-wait 2>/dev/null | wc -l)
st "$( ((cw>100)) && echo warn || echo ok)" SIEĆ E "gniazda CLOSE-WAIT: $cw" "aplikacja nie zamyka gniazd. lekcja 05: ss -tanp state close-wait"
gw=$(ip route show default 2>/dev/null | awk '/via/{print $3; exit}')
if [[ -n $gw ]]; then
  if ping -c 1 -W 1 "$gw" >/dev/null 2>&1; then st ok SIEĆ E "brama $gw odpowiada"
  else st warn SIEĆ E "brama $gw nie odpowiada na ping" "lekcja 04: ip neigh show $gw (ARP), może blokuje ICMP"; fi
else
  st crit SIEĆ E "brak trasy domyślnej" "lekcja 04: ip route"
fi
if getent hosts example.com >/dev/null 2>&1; then st ok DNS E "rozwiązywanie nazw działa"
else st crit DNS E "nie rozwiązuje example.com" "lekcja 08: getent ahosts, /etc/resolv.conf"; fi

# ============================== RESZTA =======================================
read -r fa _ fm < /proc/sys/fs/file-nr
fp=$(( 100 * fa / fm ))
st "$(lvl $fp 70 90)" FD U "deskryptory plików: $fa / $fm (${fp}%)" "lekcja 13 sekcja 6; per proces: ls /proc/PID/fd | wc -l vs /proc/PID/limits"
pids=$(ls -d /proc/[0-9]* | wc -l); pmax=$(cat /proc/sys/kernel/pid_max)
st "$(lvl $(( 100 * pids / pmax )) 70 90)" PROCESY U "procesy: $pids / pid_max $pmax"
z=$(ps -eo stat= | grep -c '^Z')
st "$( ((z>0)) && echo warn || echo ok)" PROCESY E "zombie: $z" "lekcja 01: ps -eo pid,ppid,stat,comm | awk '\$3 ~ /^Z/' — zrestartuj rodzica"
if have chronyc; then
  off=$(chronyc tracking 2>/dev/null | awk '/^System time/{print $4}')
  ls_=$(chronyc tracking 2>/dev/null | awk -F': ' '/^Leap status/{print $2}')
  [[ -n $ls_ ]] && st "$([[ $ls_ == Normal ]] && echo ok || echo crit)" ZEGAR E "chrony: $ls_, offset ${off:-?} s" "chronyc sources -v"
elif have timedatectl; then
  s=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
  st "$([[ $s == yes ]] && echo ok || echo warn)" ZEGAR E "NTP zsynchronizowany: ${s:-?}" "timedatectl timesync-status"
fi
if have systemctl && [[ $(ps -p 1 -o comm=) == systemd ]]; then
  f=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
  st "$( ((f>0)) && echo crit || echo ok)" USŁUGI E "systemd failed: $f" "lekcja 11: systemctl --failed; journalctl -u NAZWA -b"
elif [[ -d /var/service ]] && is_root; then
  bad=$(sv status /var/service/* 2>/dev/null | awk '/^(down|fail)/{sub(/:$/,"",$2); print $2}' | tr '\n' ' ')
  st "$([[ -n $bad ]] && echo warn || echo ok)" USŁUGI E "runit nie działa: ${bad:-—}" "lekcja 11: sv status /var/service/*"
fi

printf '\n%s  Podsumowanie: ŹLE=%d  UWAGA=%d%s\n' "$C_HEAD" "$CRIT" "$WARNS" "$C_RESET"
exit "$CRIT"
