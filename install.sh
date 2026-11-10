#!/usr/bin/env bash
# Raspberry Pi Chromium / Cage kiosk installer.
# Il TAR distribuito viene soltanto validato ed estratto: nessun suo file viene riscritto.
set -Eeuo pipefail
umask 077

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE="$SCRIPT_DIR/kiosk-replica.tar.gz"
STAGE=''
BACKUP_DIR=''
AP_PASSWORD=''

say() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\nERRORE: %s\n' "$*" >&2; exit 1; }
cleanup() {
    unset AP_PASSWORD || true
    if [[ -n "$STAGE" && -d "$STAGE" ]]; then rm -rf -- "$STAGE"; fi
}
on_error() {
    local code=$?
    printf '\nInstallazione interrotta (codice %s).\n' "$code" >&2
    if [[ -n "$BACKUP_DIR" ]]; then
        printf 'Backup dei file precedenti: %s\n' "$BACKUP_DIR" >&2
    fi
}
trap cleanup EXIT
trap on_error ERR

[[ $EUID -eq 0 ]] || die 'Esegui con sudo: sudo bash install.sh'
[[ -t 0 ]] || die 'Serve un terminale interattivo.'
[[ -f "$ARCHIVE" ]] || die "Archivio mancante accanto all'installer: $ARCHIVE"
[[ -e /dev/tty0 ]] || die 'Manca /dev/tty0: serve un Raspberry con console video.'
for prog in systemctl apt-get python3 ip; do
    command -v "$prog" >/dev/null 2>&1 || die "Comando mancante: $prog"
done
[[ -r /etc/os-release ]] || die '/etc/os-release mancante.'
# Supporto mirato all'immagine collaudata: Debian / Raspberry Pi OS Trixie.
. /etc/os-release
[[ "${VERSION_ID:-}" == '13' ]] || die 'Serve Raspberry Pi OS / Debian 13 (Trixie).'

SSID="$(hostname -s)"
[[ "$SSID" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] || die "Hostname non adatto come SSID: $SSID"
[[ ${#SSID} -le 32 ]] || die 'L’hostname supera i 32 byte consentiti per SSID.'
[[ "$SSID" != 'localhost' && "$SSID" != 'raspberrypi' ]] || die 'Imposta prima un hostname univoco con hostnamectl.'

printf '\nRaspberry Pi Kiosk — installazione\nHostname / SSID hotspot: %s\n\n' "$SSID"
printf 'ATTENZIONE: il login locale su tty1 verra disabilitato.\n'
printf 'Esegui via SSH con connessione Ethernet e mantieni un accesso amministrativo alternativo.\n\n'

# Best effort: non interrompere la connessione SSH usata dall’installazione.
if [[ -n "${SSH_CONNECTION:-}" ]]; then
    SSH_PEER="${SSH_CONNECTION%% *}"
    if [[ "$SSH_PEER" == *.* ]]; then
        ROUTE="$(ip -4 route get "$SSH_PEER" 2>/dev/null || true)"
        [[ " $ROUTE " == *' dev eth0 '* ]] || die 'SSH non risulta instradato su eth0. Collegati via Ethernet.'
    fi
fi

while :; do
    IFS= read -r -s -p "Password WPA2 hotspot '${SSID}' (8-63 caratteri ASCII): " AP_PASSWORD
    printf '\n'
    if [[ ${#AP_PASSWORD} -ge 8 && ${#AP_PASSWORD} -le 63 ]] \
        && LC_ALL=C grep -qE '^[ -~]+$' <<<"$AP_PASSWORD"; then
        break
    fi
    printf 'Password non valida. Inserisci da 8 a 63 caratteri ASCII stampabili.\n'
done

while :; do
    IFS= read -r -p 'URL da aprire in Chromium (http:// o https://): ' APP_URL
    if python3 - "$APP_URL" <<'PY'
import sys
from urllib.parse import urlsplit
url = sys.argv[1]
try:
    x = urlsplit(url)
    valid = (x.scheme in ('http', 'https') and x.hostname
             and x.port != 0 and not x.username and not x.password
             and all(33 <= ord(ch) <= 126 and ch not in "\\\"'" for ch in url))
except ValueError:
    valid = False
sys.exit(0 if valid else 1)
PY
    then
        break
    fi
    printf 'URL non valido: usa un indirizzo completo senza spazi, credenziali o caratteri di controllo.\n'
done

say 'Verifica del sistema'
if systemctl is-active --quiet display-manager.service; then
    die 'Display manager grafico attivo: installa Raspberry Pi OS Lite o disabilitalo prima.'
fi
DM_ENABLED="$(systemctl is-enabled display-manager.service 2>/dev/null || true)"
[[ "$DM_ENABLED" != 'enabled' ]] || die 'Un display manager è abilitato: potrebbe occupare il terminale di Cage.'
[[ -d /sys/class/net/eth0 ]] || die 'Interfaccia eth0 non presente.'
[[ -d /sys/class/net/wlan0 ]] || die 'Interfaccia wlan0 non presente.'

say 'Validazione del TAR standard (senza modifiche)'
STAGE="$(mktemp -d /tmp/raspberry-kiosk.XXXXXXXX)"
python3 - "$ARCHIVE" "$STAGE" <<'PY'
import pathlib
import sys
import tarfile
archive, stage = sys.argv[1:]
required = {
    'etc/systemd/system/kiosk.service',
    'etc/systemd/system/kiosk-wifi.service',
    'etc/pam.d/cage',
    'etc/chromium/policies/managed/kiosk.json',
    'etc/udev/rules.d/99-kiosk-disable-pointer.rules',
    'etc/NetworkManager/dnsmasq-shared.d/kiosk-dns.conf',
    'usr/local/bin/kiosk-browser',
    'usr/local/bin/kiosk-ethernet-online',
    'usr/local/sbin/kiosk-provision-firewall',
    'etc/kiosk-provision.nft',
    'opt/kiosk-wifi/portal.py',
}
with tarfile.open(archive, 'r:gz') as tar:
    seen = set()
    members = []
    for item in tar.getmembers():
        path = item.name.removeprefix('./').rstrip('/')
        parts = pathlib.PurePosixPath(path).parts
        if not path or item.name.startswith('/') or '..' in parts:
            raise SystemExit(f'Percorso TAR non sicuro: {item.name}')
        if not (item.isfile() or item.isdir()):
            raise SystemExit(f'TAR contiene link o tipo inatteso: {item.name}')
        if item.isfile():
            if path in ('opt/kiosk-wifi/offline.html', 'opt/kiosk-wifi/networks.json') or '__pycache__' in parts:
                raise SystemExit(f'Il TAR non deve contenere dati generati o locali: {path}')
            if path not in required and not path.startswith('opt/kiosk-wifi/'):
                raise SystemExit(f'File TAR non previsto: {path}')
            if path in seen:
                raise SystemExit(f'File duplicato nel TAR: {path}')
            seen.add(path)
        members.append(item)
    missing = sorted(required - seen)
    if missing:
        raise SystemExit('File mancanti nel TAR:\n  ' + '\n  '.join(missing))
    tar.extractall(stage, members=members, filter='data')
print('TAR valido')
PY

# Compatibilità controllata PRIMA di installare o alterare i servizi.
python3 - "$STAGE" <<'PY'
from pathlib import Path
import json
import re
import sys
s = Path(sys.argv[1])
browser = (s / 'usr/local/bin/kiosk-browser').read_text()
portal = (s / 'opt/kiosk-wifi/portal.py').read_text()
unit = (s / 'etc/systemd/system/kiosk.service').read_text()
policy = json.loads((s / 'etc/chromium/policies/managed/kiosk.json').read_text())
checks = {
  'kiosk-browser: APP_URL deve leggere KIOSK_URL (non un URL hardcoded)':
      bool(re.search(r'(?m)^\s*APP_URL\s*=.*\bKIOSK_URL\b', browser)),
  'kiosk-browser: script eseguibile Bash': browser.startswith('#!/bin/bash') or browser.startswith('#!/usr/bin/env bash'),
  'portal.py: lettura SSID dal profilo NetworkManager': 'def ap_ssid(' in portal,
  'portal.py: lettura password dal profilo NetworkManager': 'def ap_password(' in portal,
  'portal.py: generazione QR code': 'def hotspot_qrcode(' in portal,
  'portal.py: controllo ethernet': 'def ethernet_online(' in portal,
  'portal.py: connessione Wi-Fi': 'def connect_new_wifi(' in portal,
  'portal.py: riavvio kiosk non bloccante': '--no-block' in portal,
  'kiosk.service: grafica nel graphical.target': bool(re.search(r'(?m)^WantedBy=graphical\.target\s*$', unit)),
  'kiosk.service: utente kiosk': bool(re.search(r'(?m)^User=kiosk\s*$', unit)),
  'kiosk.service: PAM Cage': bool(re.search(r'(?m)^PAMName=cage\s*$', unit)),
  'kiosk.service: script browser': '/usr/local/bin/kiosk-browser' in unit,
  'policy Chromium: nessuna allowlist di domini fissa': not policy.get('URLBlocklist') and not policy.get('URLAllowlist'),
}
for desc, ok in checks.items():
    if not ok:
        print('TAR NON COMPATIBILE:', desc, file=sys.stderr)
if not all(checks.values()):
    raise SystemExit('Correggi i sorgenti del TAR una sola volta, poi rigenera l’archivio.')
print('Contratto applicativo verificato.')
PY

say 'Installazione dipendenze'
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
    chromium cage xwayland network-manager dnsmasq-base nftables \
    qrencode curl python3 ca-certificates avahi-daemon iw openssh-server
for prog in nmcli nft qrencode cage chromium curl; do
    command -v "$prog" >/dev/null || die "Programma non disponibile dopo apt: $prog"
done
systemctl enable --now NetworkManager.service
systemctl enable --now ssh.service

say 'Configurazione utente Kiosk'
if id kiosk >/dev/null 2>&1; then
    usermod -s /usr/sbin/nologin kiosk
else
    useradd -m -s /usr/sbin/nologin kiosk
fi
passwd -l kiosk >/dev/null
usermod -aG video,render,input kiosk
install -d -m 0700 -o kiosk -g kiosk /home/kiosk/.config/chromium-kiosk

say 'Installazione file dal TAR, senza alterarne i contenuti'
BACKUP_DIR="$(mktemp -d /var/backups/kiosk-before-install-XXXXXXXX)"
TARGETS=(
    /etc/systemd/system/kiosk.service
    /etc/systemd/system/kiosk-wifi.service
    /etc/pam.d/cage
    /etc/chromium/policies/managed/kiosk.json
    /etc/udev/rules.d/99-kiosk-disable-pointer.rules
    /etc/NetworkManager/dnsmasq-shared.d/kiosk-dns.conf
    /usr/local/bin/kiosk-browser
    /usr/local/bin/kiosk-ethernet-online
    /usr/local/sbin/kiosk-provision-firewall
    /etc/kiosk-provision.nft
)
for target in "${TARGETS[@]}"; do
    if [[ -f "$target" ]]; then
        install -d "$BACKUP_DIR$(dirname "$target")"
        cp -a "$target" "$BACKUP_DIR$target"
    fi
done
if [[ -d /opt/kiosk-wifi ]]; then
    cp -a /opt/kiosk-wifi "$BACKUP_DIR/"
fi

# Prima di sovrascrivere eventuali file già in uso.
systemctl stop kiosk-wifi.service 2>/dev/null || true
systemctl stop kiosk.service 2>/dev/null || true
for target in "${TARGETS[@]}"; do
    case "$target" in
        /usr/local/bin/*|/usr/local/sbin/*) perm=0755 ;;
        *) perm=0644 ;;
    esac
    install -D -m "$perm" "$STAGE$target" "$target"
done
install -d -m 0755 /opt/kiosk-wifi
cp -a "$STAGE/opt/kiosk-wifi/." /opt/kiosk-wifi/
rm -f /opt/kiosk-wifi/offline.html /opt/kiosk-wifi/networks.json
rm -rf /opt/kiosk-wifi/__pycache__
chmod 0755 /opt/kiosk-wifi

say 'Configurazione URL tramite EnvironmentFile systemd'
# SOLO un file di configurazione esterno al TAR, non una patch di kiosk-browser.
install -d -m 0755 /etc/kiosk
TEMP_ENV="$(mktemp /etc/kiosk/.kiosk.env.XXXXXXXX)"
printf 'KIOSK_URL=%s\n' "$APP_URL" > "$TEMP_ENV"
chmod 0600 "$TEMP_ENV"
mv -f "$TEMP_ENV" /etc/kiosk/kiosk.env
install -d -m 0755 /etc/systemd/system/kiosk.service.d
cat > /etc/systemd/system/kiosk.service.d/10-environment.conf <<'EOF'
[Service]
EnvironmentFile=/etc/kiosk/kiosk.env
EOF
chmod 0644 /etc/systemd/system/kiosk.service.d/10-environment.conf

say 'Configurazione WPA2 tramite NetworkManager (nessun segreto nel TAR)'
# Il PSK è conservato nel profilo di sistema NetworkManager; il portale legge lì.
mapfile -t AP_UUIDS < <(nmcli -t --escape no -f UUID,NAME connection show | awk -F: '$2=="kiosk-setup"{print $1}')
[[ ${#AP_UUIDS[@]} -le 1 ]] || die 'Profili kiosk-setup duplicati. Risolverli per UUID.'
if [[ ${#AP_UUIDS[@]} -eq 1 ]]; then
    nmcli connection modify uuid "${AP_UUIDS[0]}" \
        connection.interface-name wlan0 \
        connection.autoconnect no \
        wifi.ssid "$SSID" wifi.mode ap wifi.band bg \
        wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pmf 1 \
        wifi-sec.pairwise ccmp wifi-sec.group ccmp wifi-sec.psk "$AP_PASSWORD" \
        ipv4.method shared ipv4.addresses '192.168.4.1/24' \
        ipv6.method disabled
else
    nmcli connection add \
        type wifi ifname wlan0 con-name kiosk-setup ssid "$SSID" \
        wifi.mode ap wifi.band bg \
        wifi-sec.key-mgmt wpa-psk wifi-sec.proto rsn wifi-sec.pmf 1 \
        wifi-sec.pairwise ccmp wifi-sec.group ccmp wifi-sec.psk "$AP_PASSWORD" \
        ipv4.method shared ipv4.addresses '192.168.4.1/24' \
        ipv6.method disabled connection.autoconnect no
fi
unset AP_PASSWORD
if [[ "$(nmcli -g GENERAL.CONNECTION device show wlan0 2>/dev/null || true)" == 'kiosk-setup' ]]; then
    nmcli connection down id kiosk-setup
fi

say 'Verifica script e generazione HTML/QR tramite il controller installato'
bash -n /usr/local/bin/kiosk-browser
sh -n /usr/local/bin/kiosk-ethernet-online
sh -n /usr/local/sbin/kiosk-provision-firewall
python3 -m py_compile /opt/kiosk-wifi/portal.py
nft -c -f /etc/kiosk-provision.nft
python3 - <<'PY'
import pathlib
import runpy
page_file = pathlib.Path('/opt/kiosk-wifi/offline.html')
module = runpy.run_path('/opt/kiosk-wifi/portal.py')
module['render_offline']()
if not page_file.is_file():
    raise SystemExit('Il controller non ha prodotto offline.html')
page = page_file.read_text()
if 'data:image/png;base64,' not in page or '>None<' in page or 'src="None"' in page:
    raise SystemExit('QR code non generato: verificare portal.py nel TAR.')
page_file.chmod(0o644)
print('HTML e QR code generati correttamente.')
PY

say 'Avvio automatico senza login locale'
systemctl daemon-reload
systemctl disable --now getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service
systemctl set-default graphical.target
systemctl reenable kiosk.service
systemctl enable kiosk-wifi.service
udevadm control --reload-rules
udevadm trigger --subsystem-match=input

# Prima provisioning, poi grafica. Non riavviare il Raspberry automaticamente.
systemctl start kiosk-wifi.service
systemctl start --no-block kiosk.service
# Il controller Wi-Fi può riavviare kiosk.service durante il cambio modalità.
# Attendere uno stato stabile, verificando anche il processo Chromium effettivo.
say 'Attesa avvio stabile di Cage/Chromium (massimo 60 secondi)'
KIOSK_READY=false
KIOSK_STABLE=0
for ((attempt=1; attempt<=60; attempt++)); do
    if systemctl is-active --quiet kiosk-wifi.service \
        && systemctl is-active --quiet kiosk.service \
        && pgrep -u kiosk -f '^/usr/lib/chromium/chromium( |$)' >/dev/null 2>&1; then
        ((KIOSK_STABLE+=1))
        if ((KIOSK_STABLE >= 5)); then
            KIOSK_READY=true
            break
        fi
    else
        KIOSK_STABLE=0
    fi
    sleep 1
done

if [[ "$KIOSK_READY" != true ]]; then
    journalctl -u kiosk-wifi.service -u kiosk.service -n 70 --no-pager >&2 || true
    die 'Cage/Chromium non risultano stabilmente avviati entro il timeout.'
fi

say 'Installazione completata'
printf 'Hostname/SSID  : %s\n' "$SSID"
printf 'Portale        : http://kiosk.lan\n'
printf 'Dashboard      : %s\n' "$APP_URL"
printf 'Config URL     : /etc/kiosk/kiosk.env\n'
printf 'Password WPA2  : conservata nel profilo NetworkManager kiosk-setup\n'
printf 'Utente kiosk   : /usr/sbin/nologin, password bloccata\n'
printf 'Boot target    : %s\n' "$(systemctl get-default)"
printf 'Login su tty1  : %s\n' "$(systemctl is-enabled getty@tty1.service 2>/dev/null || true)"
printf 'Backup         : %s\n' "$BACKUP_DIR"
printf '\nRiavvio manuale dopo le verifiche: sudo reboot\n'
