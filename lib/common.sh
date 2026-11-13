# shellcheck shell=bash
# =============================================================================
#  lib/common.sh — wspólne helpery dla wszystkich lekcji
# =============================================================================
#  Ładowane przez:  source "$(dirname "$0")/lib/common.sh"
#
#  ZASADA: każda komenda jest uruchamiana NA ŻYWO na Twojej maszynie.
#  Nie ma tu żadnych spreparowanych outputów. Jeśli narzędzia brakuje, skrypt
#  mówi, jaki pakiet doinstalować; jeśli trzeba roota — używa sudo.
#
#  Najważniejsze funkcje:
#    section  "Tytuł"                 – nagłówek sekcji
#    note     "tekst"                 – komentarz/wyjaśnienie
#    flags    "-a" "opis" "-b" "opis" – tabelka flag komendy
#    run "komenda" [narzędzie] [root] – pokazuje i uruchamia komendę (pipe dozwolony)
#    annotate 'regex' 'wyjaśnienie' … – filtr (awk): przepuszcza output i pod
#                                       PIERWSZĄ linią pasującą do regexa dopisuje
#                                       wyjaśnienie. Na końcu wypisuje (wyszarzone)
#                                       wzorce, które w Twoim outpucie nie wystąpiły.
#    pause                            – czeka na Enter
#
#  Zmienne środowiskowe:
#    NOPAUSE=1          – nie zatrzymuj się między sekcjami
#    NOCOLOR=1          – bez kolorów (np. do `| less -R` niepotrzebne, do pliku tak)
#    ANNOTATE_ALL=1     – wyjaśnienie pod KAŻDĄ pasującą linią, nie tylko pierwszą
#    ANNOTATE_UNSEEN=0  – nie pokazuj wyjaśnień dla wzorców, których nie było
#    QUIZ=1             – tryb powtórki: przy każdej objaśnianej linii najpierw pytanie,
#                         wyjaśnienie dopiero po Enterze (możesz wpisać swoją odpowiedź)
#    MAXLINES=40        – ile linii outputu pokazywać
#    MAXWIDTH=150       – przycinaj dłuższe linie
# =============================================================================

set -o pipefail

if [[ -t 1 && -z "${NOCOLOR:-}" ]]; then
  C_HEAD=$'\e[1;36m'; C_CMD=$'\e[1;33m'; C_EXPL=$'\e[0;32m'
  C_FLAG=$'\e[1;35m'; C_DIM=$'\e[2m';    C_WARN=$'\e[1;31m'; C_RESET=$'\e[0m'
else
  C_HEAD=''; C_CMD=''; C_EXPL=''; C_FLAG=''; C_DIM=''; C_WARN=''; C_RESET=''
fi

MAXLINES="${MAXLINES:-40}"
MAXWIDTH="${MAXWIDTH:-${COLUMNS:-150}}"

# narzędzie -> pakiet (Void | Debian/Ubuntu | RHEL/Fedora | Arch)
declare -A PKG=(
  [dig]="bind-utils | dnsutils | bind-utils | bind"
  [tcpdump]="tcpdump" [lsof]="lsof" [strace]="strace" [ethtool]="ethtool"
  [iostat]="sysstat" [pidstat]="sysstat" [mpstat]="sysstat"
  [nft]="nftables" [conntrack]="conntrack-tools | conntrack | conntrack-tools | conntrack-tools"
  [mtr]="mtr | mtr-tiny | mtr | mtr" [traceroute]="traceroute"
  [pstree]="psmisc" [iptables]="iptables" [nc]="openbsd-netcat | netcat-openbsd | nmap-ncat | openbsd-netcat"
  [curl]="curl" [nstat]="iproute2" [ss]="iproute2" [ip]="iproute2" [slabtop]="procps-ng"
  [getent]="glibc" [resolvectl]="systemd" [nmcli]="NetworkManager" [arping]="iputils"
)

section() {
  printf '\n%s══════════════════════════════════════════════════════════════════════%s\n' "$C_HEAD" "$C_RESET"
  printf '%s  %s%s\n' "$C_HEAD" "$*" "$C_RESET"
  printf '%s══════════════════════════════════════════════════════════════════════%s\n' "$C_HEAD" "$C_RESET"
}

note() { printf '%s  » %s%s\n' "$C_EXPL" "$*" "$C_RESET"; }
warn() { printf '%s  ! %s%s\n' "$C_WARN" "$*" "$C_RESET"; }

# Ściągawka (komendy, których NIE uruchamiamy, bo coś zmieniają) — z stdin.
cheat() {
  printf '%s  Ściągawka (nie uruchamiane — zmieniają system):%s\n' "$C_DIM" "$C_RESET"
  sed "s/^/  ${C_FLAG}│${C_RESET} /"
}

flags() {
  printf '%s  Flagi:%s\n' "$C_DIM" "$C_RESET"
  while (($# >= 2)); do
    printf '    %s%-22s%s %s\n' "$C_FLAG" "$1" "$C_RESET" "$2"
    shift 2
  done
}

show_cmd() { printf '\n%s$ %s%s\n' "$C_CMD" "$*" "$C_RESET"; }

have() { command -v "$1" >/dev/null 2>&1; }
is_root() { [[ ${EUID:-$(id -u)} -eq 0 ]]; }

pause() {
  [[ -n "${NOPAUSE:-}" || ! -t 0 ]] && return 0
  printf '%s  [Enter = dalej, q = koniec]%s ' "$C_DIM" "$C_RESET"
  local k; read -r k
  [[ "$k" == q ]] && exit 0
  return 0
}

# Poproś o hasło sudo raz, na początku lekcji (jeśli lekcja ma sekcje rootowe).
need_sudo() {
  is_root && return 0
  if ! have sudo; then warn "brak sudo — sekcje wymagające roota zostaną pominięte (uruchom jako root)"; return 0; fi
  if [[ -t 0 ]]; then
    note "Część komend wymaga roota — sudo zapyta o hasło raz (tylko odczyt, nic nie zmieniamy)."
    sudo -v || warn "sudo nieudane — sekcje rootowe pokażą błąd"
  fi
  return 0
}

# -----------------------------------------------------------------------------
# annotate — serce repo. Czyta stdin, wypisuje każdą linię, a pod linią
# pasującą do regexa (ERE, składnia awk) dopisuje wyjaśnienie.
#
#   ps aux | annotate '^USER' 'nagłówek: kolumny...' ' Z ' 'proces zombie'
#
# Jak to działa (warto przeczytać — ten sam trik przyda się w one-linerach):
#   * argumenty trafiają do awk przez ARGV (nie -v), więc backslashe w regexach
#     nie są dodatkowo interpretowane,
#   * w BEGIN przepisujemy je do tablic re[] i ex[], potem ARGC=1, żeby awk
#     nie potraktował ich jako nazw plików i czytał stdin,
#   * `$0 ~ re[i]` to dynamiczne dopasowanie regexa trzymanego w zmiennej,
#   * "||" w opisie = złamanie linii.
# -----------------------------------------------------------------------------
annotate() {
  # QUIZ=1: przed wyjaśnieniem pytanie i czekanie na Enter (czytane z /dev/tty, bo stdin to potok)
  local quiz=""
  [[ -n "${QUIZ:-}" ]] && { : < /dev/tty; } 2>/dev/null && quiz=1
  awk -v C="$C_EXPL" -v D="$C_DIM" -v R="$C_RESET" -v Q="$C_FLAG" -v QUIZ="$quiz" \
      -v ALL="${ANNOTATE_ALL:-}" -v UNSEEN="${ANNOTATE_UNSEEN:-1}" '
    function ask(   ans) {
      printf "%s      ❓ Co oznacza ta linia? Pomyśl, potem Enter…%s ", Q, R; fflush()
      getline ans < "/dev/tty"
      if (ans != "") printf "%s      (Twoja odpowiedź: %s)%s\n", D, ans, R
      quizzed++
    }
    function explain(i, color, mark,   m, j, parts) {
      m = split(ex[i], parts, "\\|\\|")
      for (j = 1; j <= m; j++)
        printf "%s      %s %s%s\n", color, (j == 1 ? mark : "   "), parts[j], R
    }
    BEGIN {
      for (i = 1; i < ARGC; i += 2) { n++; re[n] = ARGV[i]; ex[n] = ARGV[i+1] }
      ARGC = 1
    }
    {
      print
      # linie samego skryptu ("$ komenda", "  ! uwaga", "  » notka") nie są outputem — pomijamy
      if ($0 ~ /^(\033\[[0-9;]*m)?(\$ |  [!»] )/) next
      asked = 0
      for (i = 1; i <= n; i++)
        if ((ALL || !seen[i]) && $0 ~ re[i]) {
          seen[i] = 1
          if (QUIZ && !asked++) ask()
          explain(i, C, "└─▶")
        }
    }
    END {
      if (UNSEEN != "1" || QUIZ) exit
      for (i = 1; i <= n; i++) if (!seen[i]) { if (!hdr++) printf "%s  ┄┄ nie wystąpiło teraz w Twoim outpucie (ale warto wiedzieć):%s\n", D, R
        printf "%s      ○ /%s/%s\n", D, re[i], R; explain(i, D, "  ") }
    }' "$@"
}

# Przycina długi output (żeby lekcja była czytelna).
clip() {
  awk -v max="$MAXLINES" -v w="$MAXWIDTH" -v D="$C_DIM" -v R="$C_RESET" '
    NR <= max { if (length($0) > w) $0 = substr($0, 1, w - 1) "…"; print; next }
    END { if (NR > max) printf "%s  … (%d linii pominięto, MAXLINES=%d)%s\n", D, NR - max, max, R }'
}

# run "komenda" [narzędzie] [root]
#   Uruchamia komendę na żywo. Komenda to stały string napisany w lekcji
#   (stąd eval / bash -c). Gdy trzeba roota, a nim nie jesteś -> sudo bash -c.
run() {
  local cmd="$1" tool="${2:-}" need_root="${3:-}"
  if [[ -n "$tool" ]] && ! have "$tool"; then
    show_cmd "$cmd"
    warn "brak '$tool' w systemie — zainstaluj pakiet: ${PKG[$tool]:-$tool}  (Void | Debian | RHEL | Arch)"
    return 0
  fi
  if [[ -n "$need_root" ]] && ! is_root; then
    show_cmd "sudo $cmd"
    if ! have sudo; then warn "wymaga roota — uruchom lekcję jako root"; return 0; fi
    if [[ -t 0 ]]; then sudo bash -c "$cmd" 2>&1 | clip
    else sudo -n bash -c "$cmd" 2>&1 | clip || warn "wymaga roota (sudo bez hasła niedostępne) — uruchom: sudo $0"
    fi
  else
    show_cmd "$cmd"
    eval "$cmd" 2>&1 | clip
  fi
  return 0
}

lesson_header() {
  printf '%s\n' "$C_HEAD"
  printf '  ┌────────────────────────────────────────────────────────────────┐\n'
  printf '  │ %-62s │\n' "$1"
  printf '  └────────────────────────────────────────────────────────────────┘\n'
  printf '%s' "$C_RESET"
  [[ -n "${2:-}" ]] && note "$2"
  return 0
}
