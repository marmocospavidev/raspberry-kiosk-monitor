# Raspberry Pi Chromium Kiosk

Sistema di installazione per utilizzare un Raspberry Pi come **display Kiosk**: Chromium apre automaticamente un URL a schermo intero mediante Cage (Wayland), senza desktop tradizionale e senza richiesta di login sul monitor.

Il sistema gestisce la connessione di rete in questo ordine:

1. **Ethernet con accesso Internet:** avvia direttamente l'URL configurato.
2. **Wi-Fi già configurato:** apre l'URL configurato.
3. **Nessuna connessione disponibile:** avvia un hotspot protetto da WPA2 e mostra sul monitor le istruzioni e un QR code per collegare lo smartphone. Da `http://kiosk.lan` è possibile selezionare una rete Wi-Fi rilevata, inserire la relativa password e completare la configurazione. In caso di errore, l'hotspot viene ripristinato.

Il dispositivo utilizza un'unica interfaccia Wi-Fi (`wlan0`): l'hotspot viene spento quando il Raspberry tenta la connessione a una rete esterna.

## Requisiti

- Raspberry Pi con Wi-Fi integrato (`wlan0`), porta Ethernet (`eth0`) e uscita HDMI; configurazione progettata per Raspberry Pi 5.
- Alimentatore adeguato, scheda microSD o SSD e monitor HDMI.
- **Raspberry Pi OS Lite 64-bit basato su Debian 13 (Trixie)**.
- Connessione Ethernet con Internet durante l'installazione, per scaricare i pacchetti.
- Accesso SSH con un utente amministratore autorizzato a usare `sudo`.
- Repository GitHub contenente `install.sh`, `bootstrap.sh` e `kiosk-replica.tar.gz` nella stessa directory.

> L'installazione disabilita il login locale sul terminale `tty1` e usa quel terminale per il Kiosk. Verificare che SSH via Ethernet sia funzionante prima di avviare l'installer. Non installare un desktop o un display manager aggiuntivo.

## 1. Installazione del sistema operativo

1. Scaricare e aprire [Raspberry Pi Imager](https://www.raspberrypi.com/software/) sul proprio computer.
2. Selezionare il modello di Raspberry Pi e il supporto di avvio (microSD o SSD).
3. Come sistema operativo scegliere **Raspberry Pi OS Lite (64-bit)** nella release basata su **Debian 13 Trixie**.
4. Nelle impostazioni di personalizzazione dell'Imager configurare:
   - **Hostname univoco**, che diventerà il nome dell'hotspot Wi-Fi.
   - **Utente amministratore e password** per l'accesso via SSH.
   - **SSH abilitato**, preferibilmente con chiave pubblica.
   - **Paese Wi-Fi** corrispondente a quello di installazione.
5. Scrivere l'immagine, inserire il supporto nel Raspberry e collegare **Ethernet, HDMI e alimentazione**.
6. Individuare l'indirizzo IP assegnato dal router e connettersi via SSH:

```bash
ssh <utente>@<indirizzo-ip>
```

7. Aggiornare il sistema:

```bash
sudo apt-get update
sudo apt-get full-upgrade -y
sudo reboot
```

Dopo il riavvio, ricollegarsi via SSH.

## 2. Installazione del Kiosk

### Metodo standard: Git

```bash
sudo apt-get install -y git

git clone https://github.com/OWNER/REPOSITORY.git raspberry-kiosk
cd raspberry-kiosk
sudo bash install.sh
```

Sostituire `OWNER/REPOSITORY` con il percorso effettivo del repository GitHub.

### Metodo rapido: comando di bootstrap

Per un repository pubblico è possibile scaricare soltanto il bootstrap e lasciare che sia lui a clonare il progetto e avviare `install.sh`:

```bash
curl -fsSL https://raw.githubusercontent.com/OWNER/REPOSITORY/main/bootstrap.sh -o /tmp/kiosk-bootstrap.sh \
  && bash /tmp/kiosk-bootstrap.sh https://github.com/OWNER/REPOSITORY.git
```

Il bootstrap non richiede di copiare manualmente il repository sul Raspberry. In un repository privato è necessario predisporre l'autenticazione GitHub per `git clone` e usare il metodo standard o l'URL SSH.

### Dati richiesti dall'installer

L'installer richiede **esclusivamente due valori**:

- **Password WPA2 dell'hotspot** (inserimento nascosto, minimo 8 caratteri e massimo 63).
- **URL da aprire in Chromium** (indirizzo completo `https://...` oppure `http://...`).

L'**SSID dell'hotspot coincide automaticamente con l'hostname** impostato in Raspberry Pi Imager. Non viene chiesto all'utente.

L'installer installa i pacchetti necessari, i servizi Cage/Chromium e il controller di rete, configura l'avvio automatico su `graphical.target`, crea l'utente `kiosk` senza shell interattiva, disabilita il login su `tty1` e genera la pagina con QR code.

L'URL viene salvato nella configurazione di sistema del Kiosk, mentre la password dell'hotspot viene conservata nel profilo protetto di NetworkManager. Non è necessario inserire alcun valore nel codice dei file applicativi.

## 3. Riavvio e verifica

Al termine dell'installazione, controllare lo stato dei servizi:

```bash
systemctl status kiosk.service --no-pager
systemctl status kiosk-wifi.service --no-pager
systemctl get-default
```

Il target di avvio deve essere `graphical.target` e i servizi devono risultare attivi.

Riavviare:

```bash
sudo reboot
```

**Comportamento atteso:** con Internet disponibile appare direttamente l'URL configurato. Senza rete viene mostrata la pagina di configurazione e viene attivato l'hotspot con SSID uguale all'hostname. Dal telefono si può collegare l'hotspot tramite QR code, aprire `http://kiosk.lan` e selezionare la rete Wi-Fi a cui collegare il Raspberry.

### Comandi diagnostici

```bash
nmcli connection show
nmcli device status
sudo journalctl -u kiosk.service -b -n 60 --no-pager
sudo journalctl -u kiosk-wifi.service -b -n 60 --no-pager
```

## Contenuto del repository

```text
raspberry-kiosk/
├── bootstrap.sh
├── install.sh
├── kiosk-replica.tar.gz
└── README.md
```

`kiosk-replica.tar.gz` è il pacchetto applicativo standard distribuito insieme all'installer. Durante l'installazione viene validato ed estratto **senza sostituzioni di testo né modifiche ai suoi sorgenti**.

Se il repository è pubblico, verificare prima della pubblicazione che l'archivio non contenga credenziali, profili Wi-Fi salvati o altri dati riservati.
