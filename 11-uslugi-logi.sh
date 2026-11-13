#!/usr/bin/env bash
# =============================================================================
#  11 — Usługi i logi: systemd (systemctl, journalctl) albo runit (sv, socklog)
# =============================================================================
#  Lekcja wykrywa init (PID 1) i pokazuje komendy właściwe dla Twojego systemu.
#  Ściągawka dla drugiego systemu init jest na końcu.
# =============================================================================
source "$(dirname "$0")/lib/common.sh"

lesson_header "11 · USŁUGI I LOGI" "systemctl / journalctl / sv / logi tekstowe"
need_sudo

INIT=$(ps -p 1 -o comm=)
note "PID 1 = $INIT"

if [[ "$INIT" == systemd ]]; then
# -----------------------------------------------------------------------------
section "1. systemctl --failed — co leży?"
run "systemctl --failed --no-pager" systemctl | annotate \
  'UNIT +LOAD' 'LOAD = czy unit się wczytał, ACTIVE = stan ogólny, SUB = szczegół (running/exited/failed/dead)' \
  'failed' 'Unit w stanie failed. Dalej: systemctl status NAZWA ; journalctl -u NAZWA -b' \
  '0 loaded units' 'Brak awarii'

pause
section "2. systemctl status — anatomia"
SVC=$(systemctl list-units --type=service --state=running --no-legend 2>/dev/null | awk '/ssh|cron|journald/{print $1; exit}')
run "systemctl status ${SVC:-systemd-journald.service} --no-pager -n 8" systemctl | annotate \
  'Loaded:' 'Loaded: ścieżka pliku unit; enabled = startuje przy boot; preset = domyślna polityka dystrybucji||"drop-in" niżej = nadpisania z /etc/systemd/system/NAZWA.d/*.conf (systemctl edit)' \
  'Active: active \(running\)' 'active (running) od kiedy; inne: activating, deactivating, failed (Result: exit-code/signal/timeout)' \
  'Main PID' 'Main PID = główny proces usługi' \
  'Tasks:' 'Tasks = procesy/wątki w cgroup usługi (limit TasksMax)' \
  'Memory:' 'Memory = zużycie cgroup (z cache!). Limit: MemoryMax=' \
  'CGroup:' 'CGroup = drzewo procesów usługi — systemd zabija CAŁĄ cgroup przy stop'
run "systemctl cat ${SVC:-systemd-journald.service} --no-pager | grep -vE '^\\s*(#|\$)' | head -25" systemctl | annotate \
  '^\[Unit\]' '[Unit]: Description, After=/Requires=/Wants= (kolejność vs zależność!)' \
  '^\[Service\]' '[Service]: Type=simple|forking|notify|oneshot, ExecStart=, Restart=on-failure, User=,||LimitNOFILE=, Environment=, sandboxing: ProtectSystem=, PrivateTmp=' \
  '^\[Install\]' '[Install] WantedBy=multi-user.target = co tworzy "enable"'

pause
section "3. journalctl — logi"
flags "-u UNIT" "tylko usługa" "-b / -b -1" "ten boot / poprzedni boot" "-p err" "priorytet err i gorsze (0 emerg..7 debug)" \
      "--since '1 hour ago'" "zakres czasu" "-f" "śledź na żywo" "-k" "tylko kernel (jak dmesg)" "-o json-pretty / cat / short-precise" "format" "-g REGEX" "grep po wiadomości"
run "journalctl -p err -b --no-pager -n 15" journalctl | annotate \
  ' kernel: ' 'kernel: = wpis z jądra (to samo co dmesg)' \
  'Failed|failed' 'Failed to start ... = usługa nie wstała — journalctl -u NAZWA -b pokaże szczegóły'
note "Top 10 najgłośniejszych źródeł błędów w tym bootcie (awk zlicza pole 5 = identyfikator):"
run "journalctl -p warning -b --no-pager -o short | awk '{sub(/\\[[0-9]+\\]:?\$/, \"\", \$5); sub(/:\$/, \"\", \$5); c[\$5]++} END{for(k in c) print c[k], k}' | sort -nr | head" journalctl
run "journalctl --disk-usage; journalctl --list-boots --no-pager | tail -5" journalctl | annotate \
  'take up' 'Rozmiar journala. Limit: SystemMaxUse= w /etc/systemd/journald.conf; sprzątanie: journalctl --vacuum-size=500M' \
  '^ *-?[0-9]+ ' 'Lista bootów: 0 = bieżący, -1 = poprzedni. Brak poprzednich => journal nie jest trwały (Storage=persistent)'

pause
section "4. Czas startu"
run "systemd-analyze; systemd-analyze blame --no-pager | head -10" systemd-analyze | annotate \
  'Startup finished' 'czas firmware + loader + kernel + initrd + userspace' \
  '[0-9.]+(s|ms) ' 'blame = ile trwała inicjalizacja unitów (równolegle!). Ścieżka krytyczna: systemd-analyze critical-chain'

cheat <<'EOF'
# ---- runit (Void, Artix, kontenery) — dla porównania ----
sv status /var/service/*        sv up|down|restart NAZWA        ln -s /etc/sv/NAZWA /var/service/   (= enable)
EOF

else
# -----------------------------------------------------------------------------
section "1. runit: stan usług (sv status)"
note "Usługi zdefiniowane w /etc/sv/NAZWA/run; aktywne = symlinki w /var/service (runsvdir je nadzoruje)"
run "sv status /var/service/*" sv root | annotate \
  '^run:' 'run: NAZWA: (pid N) Xs = działa od X sekund. Mały X przy długim uptime => usługa się RESTARTUJE w kółko!' \
  '^down:' 'down: = zatrzymana. "normally up" = powinna działać => coś jest nie tak' \
  '^fail:' 'fail: = runsv nie potrafi uruchomić ./run' \
  'normally up' 'normally up = zatrzymana ręcznie (sv down), choć domyślnie ma działać' \
  'want up' 'want up = runit próbuje ją podnieść'
note "Usługi, które żyją krócej niż 60 s (awk wyłuskuje sekundy sprzed 's;' i porównuje):"
run "sv status /var/service/* | awk -F'[ :]+' '/^run:/{for(i=1;i<=NF;i++) if(\$i ~ /^[0-9]+s;?\$/){s=\$i; sub(/s;?/,\"\",s); if (s+0 < 60) print \$2, \"działa dopiero\", s, \"s — restart-loop?\"}}'" sv root
run "cat /etc/sv/sshd/run" | annotate \
  '^exec' 'run = skrypt uruchamiający usługę na PIERWSZYM planie (exec, bez demonizowania!)||runsv restartuje ją, gdy padnie. Opcjonalnie: ./finish, ./log/run (logger), ./conf (zmienne)'
run "ps -eo pid,ppid,comm | awk '\$3 ~ /^(runsvdir|runsv)\$/' | head" | annotate \
  'runsvdir' 'runsvdir = nadzorca katalogu /var/service' \
  'runsv' 'runsv = osobny nadzorca dla każdej usługi (i jej loggera)'

pause
section "2. Logi: socklog / svlogd / pliki w /var/log"
note "Void domyślnie nie ma sysloga — logi trafią do /var/log/socklog/* po: xbps-install socklog-void && ln -s /etc/sv/socklog-unix /etc/sv/nanoklogd /var/service/"
run "ls -la /var/log/" | annotate \
  'socklog' 'socklog/ = podkatalogi per facility (everything, daemon, kernel...), plik "current"' \
  'dmesg.log' 'dmesg.log = zrzut bufora kernela z czasu startu' \
  'wtmp|btmp|lastlog' 'wtmp/btmp/lastlog = binarne logi logowań: last, lastb (nieudane, root), lastlog'
run "last -n 8 -F" last | annotate \
  'reboot' 'reboot = start systemu (pseudo-użytkownik)' \
  'still logged in' 'sesja wciąż trwa' \
  'crash' 'crash = brak poprawnego wylogowania/wyłączenia (twardy reset, awaria zasilania, kernel panic)'
run "lastb -n 8" lastb root | annotate \
  'ssh' 'nieudane logowania — dużo z jednego IP = brute force (fail2ban / iptables recent)'
[[ -d /var/log/socklog ]] && run "tail -n 15 /var/log/socklog/everything/current" "" root

cheat <<'EOF'
# ---- systemd — dla porównania ----
systemctl --failed                     journalctl -u NAZWA -b -p warning --since '1h ago'
systemctl status NAZWA                 systemctl edit NAZWA (drop-in)   systemctl daemon-reload
systemd-analyze blame / critical-chain journalctl -k (kernel)  -f (follow)
EOF
fi

pause
# -----------------------------------------------------------------------------
section "Wspólne: kto ostatnio był zalogowany, uptime, zegar"
run "uptime; who -a 2>/dev/null | head -5" | annotate \
  'load average' 'uptime: czas od startu, liczba użytkowników, load 1/5/15 (lekcja 01)' \
  'run-level|system boot' 'system boot = czas startu'
run "date; (chronyc tracking 2>/dev/null || timedatectl 2>/dev/null) | head -8" | annotate \
  'System time|Last offset' 'chrony: offset zegara względem NTP. Rozjechany zegar psuje TLS, Kerberos, logi, klastry (etcd!)' \
  'Leap status' 'Leap status: Normal = synchronizacja OK; Not synchronised = brak NTP' \
  'synchronized: yes' 'timedatectl: zegar zsynchronizowany'
