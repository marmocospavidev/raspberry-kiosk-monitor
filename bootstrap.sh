#!/usr/bin/env bash
# Download del repository ed esecuzione dell'installer locale.
# Esempio: bash bootstrap.sh https://github.com/OWNER/REPOSITORY.git
set -Eeuo pipefail

if [[ $# -ne 1 ]]; then
    printf 'Uso: bash bootstrap.sh https://github.com/OWNER/REPOSITORY.git\n' >&2
    exit 2
fi
REPOSITORY_URL="$1"
case "$REPOSITORY_URL" in
    https://github.com/*|git@github.com:*) ;;
    *) printf 'Errore: usa l’URL GitHub HTTPS o SSH del repository.\n' >&2; exit 2 ;;
esac

if ! command -v git >/dev/null 2>&1; then
    sudo apt-get update
    sudo apt-get install -y git
fi

TEMP_DIR="$(mktemp -d /tmp/raspberry-kiosk-bootstrap.XXXXXXXX)"
trap 'rm -rf -- "$TEMP_DIR"' EXIT

git clone --depth 1 "$REPOSITORY_URL" "$TEMP_DIR/repo"
[[ -f "$TEMP_DIR/repo/install.sh" ]] || { echo 'install.sh mancante nel repository.' >&2; exit 1; }
[[ -f "$TEMP_DIR/repo/kiosk-replica.tar.gz" ]] || { echo 'kiosk-replica.tar.gz mancante nel repository.' >&2; exit 1; }
sudo bash "$TEMP_DIR/repo/install.sh"
