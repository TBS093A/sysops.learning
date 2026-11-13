# sysops.learning

Interaktywne lekcje diagnostyki Linuksa w bashu. Każdy skrypt **uruchamia prawdziwe komendy na Twojej maszynie**, a jej output przepuszcza przez filtr `awk`. Filtr dopisuje wyjaśnienie pod linią pasującą do regexa:

```
$ ip -s link
2: enp0s3: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc pfifo_fast state UP ...
    link/ether 08:00:27:xx:xx:xx brd ff:ff:ff:ff:ff:ff
      └─▶ adres MAC; brd = adres rozgłoszeniowy L2 (ff:ff:ff:ff:ff:ff)
    RX:  bytes packets errors dropped  missed   mcast
      └─▶ RX: errors = uszkodzone ramki (CRC => kabel/SFP), dropped = kernel odrzucił ...
```

W skryptach nie ma spreparowanych outputów. Jeśli jakiś wzorzec nie wystąpił w Twoim outpucie (np. nie masz akurat procesów zombie ani reguł Dockera), lekcja pisze to na końcu bloku, wyszarzone, razem z wyjaśnieniem, co by oznaczał. Komendy, które **zmieniają** system (dodawanie reguł iptables, `sysctl -w`, ...), są tylko w ramkach „Ściągawka” i nigdy się nie uruchamiają.

## Lekcje

| # | Plik | Zakres |
|---|------|--------|
| 01 | `01-procesy.sh` | `ps aux` / `ps -eo` (STAT, wchan), `top -b`, `pstree`, `/proc/PID/{status,limits,fd,smaps_rollup}` |
| 02 | `02-pamiec.sh` | `free`, `/proc/meminfo`, `slabtop`, `vmstat`, kto jest w swapie, OOM killer, `oom_score` |
| 03 | `03-dyski-io.sh` | `df -hT/-i`, `lsblk`, `findmnt`, `iostat -x`, `/proc/diskstats`, `du`, usunięte-otwarte pliki (`lsof +L1`) |
| 04 | `04-ip-interfejsy-routing.sh` | `ip link/addr/route/rule/neigh`, `ip route get`, `ethtool`, netns, bridge, net-tools → iproute2 |
| 05 | `05-gniazda-ss.sh` | `ss -tulpn`, backlog, stany TCP (CLOSE-WAIT, TIME-WAIT...), `ss -ti` (rtt, cwnd, retrans), `nstat` |
| 06 | `06-iptables.sh` | tabele i łańcuchy (schemat), `-L -n -v`, `-S`, liczniki, NAT/DNAT/MASQUERADE, łańcuchy Dockera, `iptables-save`, TRACE, wzorcowy firewall |
| 07 | `07-nftables-conntrack.sh` | `nft list ruleset`, `iptables-translate`, conntrack (zapełnienie, `-L`, `-S`), ufw/firewalld |
| 08 | `08-dns-lacznosc.sh` | nsswitch / resolv.conf / hosts, `getent`, `dig`, `ping`, `tracepath`, `traceroute`, `nc`, `/dev/tcp`, `curl -w` (timingi), `openssl s_client` |
| 09 | `09-konfiguracja-sieci-sysctl.sh` | wykrywanie NM / networkd / netplan / ifupdown / dhcpcd, Twoje pliki konfiguracyjne, sieciowe `sysctl` + skąd pochodzą wartości |
| 10 | `10-tcpdump.sh` | składnia filtrów BPF, przechwycenie własnego ruchu (DNS, ICMP, handshake TCP/TLS), flagi `[S] [S.] [P.] [F.] [R]` |
| 11 | `11-uslugi-logi.sh` | systemd (`systemctl`, `journalctl`, `systemd-analyze`) **albo** runit (`sv status`, restart-loop, socklog), `last`/`lastb`, NTP |
| 12 | `12-strace-lsof.sh` | `strace -c`, jakie pliki czyta program, ENOENT, connect/DNS, wolne syscalle `-T`, `lsof` |
| 13 | `13-kernel-dmesg-psi.sh` | `dmesg` (co oznaczają typowe błędy), PSI `/proc/pressure`, przerwania, softirq, `softnet_stat`, moduły, limity, cgroups v2 i throttling |
| 14 | `14-sed-awk-wyluskiwanie.sh` | grep -o/-P, sed (grupy, zakresy), awk (pola, tablice, END, dwa pliki), dekodowanie `/proc/net/tcp` w awk, regexy |
| 15 | `15-ebpf-perf-ftrace.sh` | ftrace (tracefs, bez instalacji), bpftrace: execsnoop / opensnoop / tcpconnect+retrans / biolatency / syscount ([`bpf/*.bt`](bpf/)), `perf stat` / `perf record`, bcc tools |
| 16 | `16-tc-netem.sh` | **bez roota**, we własnych namespace'ach: opóźnienie, jitter, straty 5%, limit pasma (tbf) i bufferbloat. Po każdej zmianie pomiar przez `ping`, `curl -w`, `ss -ti`, `nstat`, `tc -s` |

## Health-check (metoda USE)

```bash
./health-check.sh        # pełny przegląd
./health-check.sh -q     # tylko problemy
sudo ./health-check.sh   # + dmesg, usługi runit
```

Dla każdego zasobu (CPU, pamięć, dyski, sieć, conntrack, FD, procesy, zegar, usługi) sprawdza **U**tilization, **S**aturation i **E**rrors. Wartości chwilowe mierzy w oknie 1 s. Przy każdym problemie mówi, co sprawdzić dalej i w której lekcji jest o tym mowa. Kod wyjścia to liczba stanów „ŹLE”, więc skrypt nadaje się do crona.

## Lab „break-fix”

```bash
./lab/lab.sh             # lista scenariuszy
./lab/lab.sh 4           # konkretny scenariusz
./lab/lab.sh random      # losowy, bez tytułu: jak prawdziwy dyżur
./lab/lab.sh selftest    # automatycznie: zepsuj, sprawdź, napraw, sprawdź (dla każdego scenariusza)
```

Lab buduje wirtualną sieć `client ─ router ─ server` (veth, routing, dnsmasq, serwery HTTP) w nowych przestrzeniach nazw: `unshare --user --net --mount --pid`. **Nie wymaga roota i nie dotyka Twojej sieci, firewalla ani `/etc`.** Po wyjściu z powłoki labu wszystko znika. Lab psuje jedną rzecz, a Ty dostajesz zgłoszenie „od użytkownika” i powłokę na hoście `client`:

| # | Scenariusz |
|---|-----------|
| 1 | router nie przekazuje pakietów |
| 2 | timeout czy *connection refused*? (DROP vs REJECT na różnych hostach) |
| 3 | brak trasy powrotnej |
| 4 | MTU blackhole: małe odpowiedzi przechodzą, duże wiszą |
| 5 | pełna kolejka accept (backlog / somaxconn) |
| 6 | DNS mówi jedno, aplikacja robi drugie |
| 7 | wolna i stratna sieć (zapomniany `tc netem`) |

Komendy w powłoce labu: `story`, `topo`, `c|r|s KOMENDA` (wykonaj na client/router/server), `enter HOST`, `check`, `hint` (podpowiedzi stopniowane), `solution`, `dnsq`, `app-restart`, `exit`. Wymagane pakiety: iproute2, iptables, python3, dnsmasq, curl. Kernel musi pozwalać na nieuprzywilejowane user namespaces (domyślnie tak jest prawie wszędzie).

## Tryb quizu

```bash
QUIZ=1 ./05-gniazda-ss.sh
```

Przy każdej objaśnianej linii najpierw pada pytanie „co oznacza ta linia?”. Możesz wpisać swoją odpowiedź, a wyjaśnienie pokazuje się dopiero po Enterze. Działa w każdej lekcji, także w 16.

## Uruchamianie

```bash
git clone https://github.com/TBS093A/sysops.learning && cd sysops.learning
./run-all.sh            # menu
./run-all.sh 06         # konkretna lekcja
./06-iptables.sh        # albo bezpośrednio
```

Lekcje, które czytają rzeczy dostępne tylko dla roota (iptables, nft, conntrack, dmesg, tcpdump, `sv status`, `ss -p`), na starcie raz pytają o hasło `sudo`. Jeśli brakuje jakiegoś narzędzia, skrypt podaje nazwę pakietu dla Void / Debiana / RHEL / Archa i przechodzi dalej.

| Zmienna | Działanie |
|---|---|
| `NOPAUSE=1` | bez zatrzymywania między sekcjami |
| `NOCOLOR=1` | bez kolorów (do pliku) |
| `ANNOTATE_ALL=1` | wyjaśnienie pod każdą pasującą linią, a nie tylko pod pierwszą |
| `ANNOTATE_UNSEEN=0` | ukryj wyjaśnienia wzorców, których nie było w outpucie |
| `MAXLINES=40` / `MAXWIDTH=150` | przycinanie długiego outputu |
| `TARGET=host` | cel testów sieciowych w lekcjach 08 i 10 |
| `QUIZ=1` | tryb powtórki: najpierw pytanie, wyjaśnienie po Enterze |

Raport ze wszystkich lekcji do pliku:

```bash
NOPAUSE=1 NOCOLOR=1 ./run-all.sh all > raport.txt 2>&1
```

## Jak działa adnotacja

Rdzeniem jest funkcja `annotate` w [`lib/common.sh`](lib/common.sh). To zwykły `awk`, który warto przeczytać, bo ten sam trik przydaje się w codziennych one-linerach:

```bash
komenda | annotate 'regex1' 'wyjaśnienie||druga linia' 'regex2' 'wyjaśnienie'
```

- pary `regex → opis` trafiają do awk przez `ARGV`, więc backslashe w regexach nie są interpretowane podwójnie,
- `ARGC=1` sprawia, że awk czyta stdin, a nie traktuje argumentów jak plików,
- `$0 ~ re[i]` to dynamiczne dopasowanie regexa trzymanego w zmiennej,
- blok `END` wypisuje wzorce, które nie wystąpiły.

Własną lekcję dopiszesz w kilku linijkach:

```bash
#!/usr/bin/env bash
source "$(dirname "$0")/lib/common.sh"
section "Moja lekcja"
run "cat /proc/loadavg" | annotate '^[0-9]' 'load 1/5/15, R/wszystkie, ostatni PID'
run "iptables -S" iptables root | annotate '^-P' 'polityka łańcucha'   # [narzędzie] [root]
```

Testowane na Void Linux (runit, iptables-nft, gawk). Lekcje celują w dowolnego Linuksa z bashem ≥ 4 i gawk. Większość działa też z mawk, poza `strtonum` w lekcjach 13 i 14.
