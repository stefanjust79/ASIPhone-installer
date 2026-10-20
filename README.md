# ASIPhone Server Installer

Öffentlicher Installer für den ASIPhone Server. Dieses Repository enthält nur
das Installationsskript und diese Anleitung, keine Installationsdaten oder
Zugangsdaten. Das Serverabbild wird ohne GitHub-Anmeldung aus
`ghcr.io/stefanjust79/asiphone-server` geladen.

## Voraussetzungen

- Frischer Debian- oder Ubuntu-Server mit systemd
- x86-64 oder ARM64
- Mindestens 6 GB freier Speicher
- Internetzugang und sudo-Berechtigung
- TUN-Unterstützung (`/dev/net/tun`) für WireGuard

## Installation

Das Skript wird mit Administratorrechten ausgeführt. Prüfe den Inhalt vor der
Ausführung, wenn du ihn noch nicht kennst.

```bash
curl -fsSL https://raw.githubusercontent.com/stefanjust79/ASIPhone-installer/main/install.sh | sudo bash
```

Alternativ zuerst herunterladen und prüfen; der zweite Befehl prüft nur die
grundlegenden Voraussetzungen und installiert nichts:

```bash
curl -fsSL https://raw.githubusercontent.com/stefanjust79/ASIPhone-installer/main/install.sh -o asiphone-install.sh
sudo bash asiphone-install.sh --check
sudo bash asiphone-install.sh
```

Der Installer installiert Docker bei Bedarf, lädt das öffentliche Serverabbild
und richtet den Dienst `asiphone.service` ein. Am Ende zeigt er die lokale
Webadresse `http://<Server-IP>:8090` und verweist auf die Einrichtung im Browser.

Beim allerersten Aufruf ist kein Kennwort erforderlich. Der Assistent führt durch:

1. Eigenes Admin-Passwort festlegen und bestätigen.
2. Lokale AGFEO-Telefonanlage konfigurieren.
3. Öffentlichen DNS-Namen oder integriertes ASIPhone-DynDNS auswählen.
4. WireGuard einrichten (Vorgaben: UDP 51820 und `10.77.0.0/24`).
5. Portweiterleitung bestätigen oder den lizenzierten Relay-Service aktivieren.

Nach dem ersten Schritt ist das festgelegte Admin-Passwort erforderlich. Eine
unterbrochene Einrichtung wird fortgesetzt; abgeschlossene und bestehende
Installationen öffnen die normale Verwaltung. Neue Benutzer werden bei gültiger
Lizenz und freiem Benutzerplatz automatisch aktiviert. Ohne Freigabe bleiben sie
deaktiviert, mit einem Hinweis auf den Grund.

Jede Installation erzeugt eigene Schlüssel und Zertifikate. Bestehende
Anlagenzugangsdaten sind nicht im Installer enthalten.

## Netzwerk

Verwaltung nur aus einem vertrauenswürdigen lokalen Netz erlauben. Für den
externen App-Zugang wird nach der WireGuard-Konfiguration standardmäßig
**UDP 51820** weitergeleitet. HTTPS, SIP und Audio sind über den VPN-Tunnel
erreichbar; diese Ports müssen nicht öffentlich weitergeleitet werden.

Ist UFW bereits aktiv, ergänzt der Installer Regeln für die lokale Verwaltung
und WireGuard. Er aktiviert keine zuvor inaktive Firewall und ersetzt keine
Router- oder Netzsegmentierung. Die tatsächliche Freigabe am Router muss der
Administrator selbst konfigurieren.

## Aktualisierung

Denselben Installationsbefehl erneut ausführen. Standardmäßig wird das Image
`main` verwendet. Vorhandene Konfiguration und Kundendaten werden beibehalten;
vor dem Austausch einer vorhandenen Installation wird eine Datensicherung
unter `/var/backups/asiphone` angelegt.

## Dienst und Diagnose

```bash
sudo systemctl status asiphone
sudo docker compose --project-directory /opt/asiphone logs --tail=100
```

Konfiguration: `/etc/asiphone/asiphone.env` (enthält vertrauliche Daten).
Persistente Serverdaten liegen im Docker-Volume `asiphone_asiphone-data`.
Logs und Konfigurationsdateien vor jeder Weitergabe auf vertrauliche Inhalte
prüfen.
