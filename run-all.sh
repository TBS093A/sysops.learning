#!/usr/bin/env bash
# Menu lekcji. Uruchom bez argumentów (menu) albo z numerem: ./run-all.sh 06
# Wszystkie naraz bez pauz do pliku:  NOPAUSE=1 NOCOLOR=1 ./run-all.sh all > raport.txt 2>&1
cd "$(dirname "$0")" || exit 1
mapfile -t L < <(ls [0-9][0-9]-*.sh)

if [[ "${1:-}" == all ]]; then
  for f in "${L[@]}"; do ./"$f"; done; exit
elif [[ -n "${1:-}" ]]; then
  f=$(ls "$1"-*.sh 2>/dev/null | head -1)
  [[ -n "$f" ]] && exec ./"$f"
  echo "Brak lekcji $1"; exit 1
fi

echo "Lekcje sysops.learning:"
for f in "${L[@]}"; do printf '  %s\n' "${f%.sh}"; done
read -rp "Numer lekcji (np. 06) albo 'all': " n
exec "$0" "$n"
