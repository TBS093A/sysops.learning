#!/usr/bin/env bash
# =============================================================================
#  lab/lab.sh — laboratorium "break-fix": coś jest zepsute, znajdź i napraw
# =============================================================================
#  ./lab/lab.sh            lista scenariuszy
#  ./lab/lab.sh 3          scenariusz 3
#  ./lab/lab.sh random     losowy scenariusz bez tytułu (prawdziwy dyżur)
#  ./lab/lab.sh selftest   automatycznie: zepsuj -> check=FAIL -> napraw -> check=OK
#
#  NIE wymaga roota: lab startuje w nowych przestrzeniach nazw
#  (unshare --user --net --mount --pid), w których jesteś "rootem" tylko dla
#  wirtualnej sieci labu. Host, jego sieć, firewall i /etc są nietknięte.
#  Wymaga: iproute2, iptables, python3, dnsmasq, curl, tc.
# =============================================================================
LAB_DIR="$(cd "$(dirname "$0")" && pwd)"
export LAB_DIR
source "$LAB_DIR/scenarios.sh"

if [[ -z "${LAB_INNER:-}" ]]; then
  missing=()
  for t in ip iptables python3 dnsmasq curl tc unshare; do command -v $t >/dev/null || missing+=("$t"); done
  ((${#missing[@]})) && { echo "Brakuje: ${missing[*]}"; exit 1; }

  if [[ -z "${1:-}" ]]; then
    nsx() { :; }
    echo "Scenariusze:"
    for n in "${SCENARIOS[@]}"; do printf '  %s) %s\n' "$n" "$(s${n}_title)"; done
    echo; echo "Użycie: $0 NUMER | random | selftest"; exit 0
  fi
  userns=(--user --map-root-user); [[ $EUID -eq 0 ]] && userns=()
  exec unshare "${userns[@]}" --net --mount --pid --fork --mount-proc --propagation private \
       env LAB_INNER=1 bash "$0" "$@"
fi

# ---------------------- wewnątrz przestrzeni labu ----------------------------
source "$LAB_DIR/lib-lab.sh"
build_lab || { echo "budowa labu nie powiodła się"; exit 1; }

if [[ "$1" == selftest ]]; then
  rc=0
  for n in "${SCENARIOS[@]}"; do
    "s${n}_setup"
    if "s${n}_check"; then fail "[$n] $(s${n}_title): check przechodzi PRZED naprawą"; rc=1; fi
    "s${n}_fix"
    if "s${n}_check"; then ok "[$n] $(s${n}_title)"; else fail "[$n] $(s${n}_title): check nie przechodzi PO naprawie"; rc=1; fi
  done
  exit $rc
fi

if [[ "$1" == random ]]; then
  export LAB_RANDOM=1
  set -- "${SCENARIOS[RANDOM % ${#SCENARIOS[@]}]}"
fi
[[ " ${SCENARIOS[*]} " == *" $1 "* ]] || { echo "Nie ma scenariusza $1"; exit 1; }
export LAB_SC=$1
"s${LAB_SC}_setup"
# Powłoka labu startuje "na kliencie": gołe komendy (ping, curl, ss) idą z hosta client.
exec ip netns exec client bash --rcfile "$LAB_DIR/labrc" -i
