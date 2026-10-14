# Installing Serk Finance on an office computer

Release 0.4.0-rc1 ships installers that put Serk Finance on one computer in the office (the "server computer"). Everyone else in the office uses it from a web browser. The installer brings its own PostgreSQL 17 database, so nothing else needs to be installed.

This guide matches `deploy/installer/README-INSTALL.txt`, which is installed with the program and opens from the Start menu (Windows) or `/opt/serk-finance/README-INSTALL.txt` (Linux).

> **Release candidate.** Not approved for live financial use until independent accountant and security acceptance. See [Known limitations](#known-limitations). In particular, the Windows installer has been built but **not yet run on real Windows**.

## What gets installed

| | Windows | Linux |
|---|---|---|
| Program | `C:\Program Files\Serk Finance` | `/opt/serk-finance` |
| Company data, database, backups, logs | `C:\ProgramData\SerkFinance` | `/var/lib/serk-finance` |
| Background service | `SerkFinance` (account `LocalService`, delayed automatic start) | `serk-finance` systemd unit (account `serk-finance`) |
| Command for backups and recovery | Start menu shortcuts, or `serk-server.exe` | `sudo serk-finance …` |

- The database listens on `127.0.0.1` only (port 55432) and accepts password logins from this computer only. Other computers can never reach it directly.
- The web interface listens on port 8080. It serves the whole office network unless you choose "this computer only".
- The data folder holds `serk.json`, which contains the installation's secrets: the database passwords and the key that encrypts authenticator secrets and AI provider keys. Only administrators and the service account can read it.
  - Windows: the data folder is restricted to Administrators, SYSTEM and LocalService. The program folder is also locked so that only administrators can change the files the service runs.
  - Linux: the data folder is owned by the `serk-finance` system user with mode 0700. The service runs with `NoNewPrivileges`, `ProtectSystem=full` and `ProtectHome`.

## Requirements

- Windows 10 or 11 (64-bit), or Windows Server 2016 or later.
- Linux: 64-bit with systemd (Ubuntu 20.04+, Debian 11+). The `.deb` needs `adduser`, `curl` and `systemd`.
- 4 GB RAM and 2 GB free disk space or more, plus room for backups.
- A trusted office network. The office connection uses plain HTTP (see [Security notes](#security-notes)).

## 1. Download and check the files

A release contains:

| File | For |
|---|---|
| `SerkFinance-0.4.0-rc1-Setup.exe` | Windows |
| `serk-finance_0.4.0~rc1_amd64.deb` | Debian and Ubuntu |
| `serk-finance-0.4.0-rc1-linux-amd64.tar.gz` | Other Linux with systemd |
| `SHA256SUMS` | Checksums of the three files |

Get `SHA256SUMS` from the same place as the installer, then check the installer before running it. Do not install a file whose checksum does not match.

Windows (PowerShell):

```powershell
Get-FileHash .\SerkFinance-0.4.0-rc1-Setup.exe -Algorithm SHA256
# compare the Hash with the SerkFinance-0.4.0-rc1-Setup.exe line in SHA256SUMS
```

or `certutil -hashfile SerkFinance-0.4.0-rc1-Setup.exe SHA256` in a command prompt.

Linux:

```bash
sha256sum -c SHA256SUMS --ignore-missing
```

The Windows installer is not code-signed in this release. Windows SmartScreen may warn about an unknown publisher. Check the checksum first, then choose "More info" → "Run anyway".

## 2. Install

### Windows

1. Run `SerkFinance-0.4.0-rc1-Setup.exe` as an administrator.
2. Accept the licence and choose the components:
   - **Serk Finance** (required).
   - **Allow other computers in the office to connect.** This adds a Windows Firewall rule for TCP port 8080 on **private and domain networks only**. Leave it unticked to use Serk Finance on this computer only; the service then listens on 127.0.0.1.
   - **Start menu and desktop shortcuts**, including "Back up now", "Reset a password" and "Installation guide".
3. The installer registers and starts the `SerkFinance` service. On the last page, "Open Serk Finance and set up my company" opens the setup page.

If `C:\ProgramData\SerkFinance` already holds data from an earlier installation, the installer asks before using it. Installing over an existing version keeps the company data; make a backup first. Installing an older version over a newer one is not supported.

### Debian or Ubuntu

```bash
sudo apt install ./serk-finance_0.4.0~rc1_amd64.deb
```

The package creates the `serk-finance` system user and `/var/lib/serk-finance`, then enables and starts the service.

### Other Linux (.tar.gz)

```bash
tar -xzf serk-finance-0.4.0-rc1-linux-amd64.tar.gz
cd serk-finance
sudo ./install.sh                # or: sudo ./install.sh --local-only   (this computer only)
```

`install.sh` copies the program to `/opt/serk-finance`, installs the `serk-finance` command to `/usr/local/bin`, writes the systemd unit, starts the service and waits for it to become ready. It prints the setup address, including the token address for setup from another computer.

The first start takes a little longer: it creates the database and applies all migrations.

## 3. First-run setup

Open **http://localhost:8080** on the server computer. The setup page opens automatically until a company exists.

Enter:

- The company name, legal currency (ETB by default) and whether the company is VAT-registered.
- A short **workspace** name: 2–40 lowercase letters, digits or hyphens. People type it when they sign in. `demo` is reserved.
- The fiscal year: Ethiopian (Hamle–Sene, the default) or Gregorian.
- The branch codes (`HQ` if none are given).
- The first administrator's name, email and password (at least 14 characters).
- Optionally, **"Also create the demo practice workspace"**. This adds the sample company `demo` for training, with sample users such as `admin@serk.demo` and `accountant@serk.demo`. They share a generated password, separate from the administrator's. It is **shown once** when setup finishes; write it down. It is also stored in `serk.json` as `practice_password`.

**Setup from another computer.** The setup page answers without a token only on the server computer itself (a loopback connection that did not come through a proxy). From another computer, use the one-time token in the data folder:

```
http://SERVER-NAME:8080/setup?token=<contents of setup-token.txt>
```

The token file is `C:\ProgramData\SerkFinance\setup-token.txt` or `/var/lib/serk-finance/setup-token.txt`. It is deleted when setup finishes.

**If setup is interrupted** (power cut, closed browser), open the setup page again and submit the form with the **same workspace and administrator email**. Setup continues where it stopped. A different workspace is refused until the first one is completed.

After setup, sign in. As the administrator:

- Add people under **Users & roles**.
- Switch modules on or off under **Modules & features**.
- Optionally configure the AI assistant (see [AI assistant](#ai-assistant-optional)).

Two-factor authentication (an authenticator app) is optional in an office installation. Users can enrol from their profile.

## 4. Adding office computers

Other computers need only a browser. They open:

```
http://SERVER-NAME:8080
```

or the server's IP address, for example `http://192.168.1.20:8080`. The server accepts its own computer name and each of its local network addresses. When it starts, it prints the addresses other computers can use (`journalctl -u serk-finance` on Linux).

- **Windows:** tick "Allow other computers" during installation, or add the firewall rule later by running the installer again.
- **Linux:** the service listens on the network by default. If a firewall is active, allow TCP 8080 from the office network only, for example `sudo ufw allow from 192.168.1.0/24 to any port 8080 proto tcp`.
- Give the server computer a fixed IP address or a DHCP reservation, so the address does not change.
- To use a name that is not the server's own computer name (for example behind an HTTPS proxy), add the exact origin, such as `"https://finance.example.local"`, to `extra_origins` in `serk.json` and restart the service.

To change the port, stop the service, edit `"port"` in `serk.json`, start the service, and on Windows update the firewall rule.

## 5. Backups

Back up every day, and keep copies away from the server computer.

| | Command |
|---|---|
| Windows | Start menu → Serk Finance → **Back up now** (asks for administrator rights) |
| Linux | `sudo serk-finance backup` |

The backup is a `.zip` in the `backups` folder of the data folder, named `serk-backup-YYYYMMDD-HHMMSS.zip`. `--out FILE` writes it somewhere else.

- **Online.** Serk Finance keeps running while the backup is taken, and people can keep working. The backup uses PostgreSQL's base-backup API. A temporary replication slot holds the write-ahead log for the duration of the backup, so no log segment needed for recovery can be recycled while files are copied. The backup is refused if the starting log segment is not in the archive, so an incomplete backup is never reported as successful.
- **Contents.** The database files, the write-ahead log needed to make them consistent, and `serk.json`. The archive therefore contains the installation's secrets as well as all financial data. Store it as carefully as the server itself, for example on an encrypted USB drive kept off-site.
- A backup is written to a `.partial` file first and renamed only when it is complete.

Test a restore on a spare computer from time to time. A backup that has never been restored is not proven.

## 6. Restore

Stop Serk Finance first. A restore is refused while the database is running.

Windows (administrator command prompt):

```bat
sc stop SerkFinance
"C:\Program Files\Serk Finance\serk-server.exe" restore --data "C:\ProgramData\SerkFinance" --from D:\serk-backup-20261014-180000.zip
sc start SerkFinance
```

Linux:

```bash
sudo systemctl stop serk-finance
sudo serk-finance restore --from /path/serk-backup-20261014-180000.zip
sudo systemctl start serk-finance
```

What restore does:

- It checks that the file is a Serk Finance backup with a backup label, and refuses unsafe paths inside the archive.
- It unpacks into a staging folder, then swaps it in. The current database is **kept** beside it as `pgdata.before-restore-<time>`, so a mistaken restore can be undone. If the swap fails, the previous database is put back. Delete the kept folder yourself once you are satisfied.
- It never takes server configuration (`postgresql.conf`, `postgresql.auto.conf`, `pg_hba.conf`, `pg_ident.conf`) from the archive. The installation's own files are used, so a tampered backup cannot change how the database runs or who may connect.
- Recovery completes when Serk Finance next starts.
- If the database folder is missing but a `pgdata.before-restore-*` folder exists (for example after an interrupted restore), Serk Finance refuses to start rather than create a new, empty database. Rename the kept folder back to `pgdata`, or restore a backup.

**Restoring on a new computer.** Install Serk Finance and let it start once. Then stop it and restore with `--with-settings`, which also restores `serk.json` and therefore the original passwords and encryption key. Without the original key, authenticator enrolments and stored AI provider keys cannot be read. After an incident, ask users to sign in again and review who has access.

## 7. Forgotten password

| | Command |
|---|---|
| Windows | Start menu → Serk Finance → **Reset a password** (asks for the workspace and email) |
| Linux | `sudo serk-finance reset-password --workspace NAME --email user@example.com` |

Serk Finance must be running. The command asks for the new password twice (at least 14 characters) and does not show it. The change signs out all of that user's sessions and is recorded in the administrative log.

## 8. Other commands

`serk-server` (Windows: in the program folder; Linux: through `sudo serk-finance`, which runs it as the service account with the right data folder):

| Command | Purpose |
|---|---|
| `run` | Start in the foreground (default). Opens the browser on first run unless `--no-browser`. |
| `service` | Used by the Windows service and the systemd unit. |
| `backup [--out FILE]` | Online backup (server running). |
| `restore --from FILE [--with-settings]` | Restore (server stopped). |
| `reset-password --workspace W --email E` | Set a user's password. |
| `stop-database` | Stop the bundled database after a crash left it running. |
| `version` | Print the version. |

Options: `--data DIR` (data folder), `--local-only` (serve this computer only), `--no-browser`.

## 9. AI assistant (optional)

The assistant answers questions from the books and prepares **drafts only**. People still review, submit and approve everything. See [AI architecture](AI_ARCHITECTURE.md).

An administrator with company-wide `configuration.manage` opens **Modules & features → AI assistant provider** and either:

- enters an Anthropic (Claude) API key, or
- chooses "OpenAI-compatible" and enters the address of a model server in the office, for example Ollama at `http://localhost:11434/v1`.

Plain-HTTP model servers are accepted only on the server computer itself (`localhost` or a loopback address). To use a model server on another office computer over plain HTTP, set `SERK_AI_ALLOW_PRIVATE_HTTP=true` for the service, then restart it:

- Windows (administrator): `reg add HKLM\SYSTEM\CurrentControlSet\Services\SerkFinance /v Environment /t REG_MULTI_SZ /d SERK_AI_ALLOW_PRIVATE_HTTP=true`, then `sc stop SerkFinance` and `sc start SerkFinance`.
- Linux: `sudo systemctl edit serk-finance`, add `[Service]` and `Environment=SERK_AI_ALLOW_PRIVATE_HTTP=true`, then `sudo systemctl restart serk-finance`.

Use this only for a model server on your own office network.

With a cloud provider, questions and the figures the assistant looks up are sent to that provider. With an office model server, they stay on your network.

## 10. Uninstall

| | |
|---|---|
| Windows | Settings → Apps → Serk Finance → Uninstall. The service and firewall rule are removed. You are asked whether to delete the company data and backups in `C:\ProgramData\SerkFinance`; the default keeps them. |
| Debian/Ubuntu | `sudo apt remove serk-finance` keeps `/var/lib/serk-finance`. `sudo apt purge serk-finance` deletes it and the service user. |
| .tar.gz | `sudo ./uninstall.sh` keeps the data. `sudo ./uninstall.sh --purge` deletes it. |

Take a final backup and copy it elsewhere before purging.

## Troubleshooting

| Symptom | What to check |
|---|---|
| The page does not open on the server computer | Is the service running? Windows: `sc query SerkFinance`. Linux: `systemctl status serk-finance`. The first start takes longer while the database is created. |
| Other computers cannot connect | Was "Allow other computers" ticked (Windows) or `--local-only` used (Linux)? Is the firewall open for TCP 8080 on this network? Windows only opens it for private and domain networks, so check the network is not marked "Public". Use the address the server printed at start. |
| Sign-in from another computer fails with `origin_denied` | Use the server's computer name or one of its local IP addresses. For any other name, add it to `extra_origins` in `serk.json`. |
| The setup page asks for a token | You are not on the server computer, or you came through a proxy. Use `setup-token.txt`, or open the page on the server computer. |
| "An earlier setup … did not finish" | Submit the setup form again with that workspace and the same administrator email. |
| The service stops at start: "the database folder is missing but … before-restore … exists" | A restore was interrupted. Rename that folder back to `pgdata`, or restore a backup. |
| The database is still running after a crash | Stop the service, then run `serk-server stop-database` (Linux: `sudo serk-finance stop-database`). |
| "do not run Serk Finance as root" | On Linux, use `sudo serk-finance …`, which runs commands as the service account. |
| Backup: "the server is not running" | Backups need Serk Finance running. Restore needs it stopped. |
| Logs | Windows: `C:\ProgramData\SerkFinance\logs\serk-server.log` and `postgres.log`. Linux: `journalctl -u serk-finance`, and `/var/lib/serk-finance/logs/postgres.log` for the database. |
| The AI assistant says it is not set up | An administrator must enter a provider key or model server address under Modules & features. The user's role needs "Use the AI assistant" (`ai.use`), and the AI assistant module must be on. |

## Security notes

- The office connection uses plain HTTP. Use it only on a trusted office network. For access over the internet, use the cloud deployment, or put the server behind an HTTPS reverse proxy or VPN and add the proxy's origin to `extra_origins`.
- Session cookies are not marked Secure in an office installation, because the connection is HTTP. CSRF protection, Origin checks, row-level security, maker-checker approval and the audit trail work exactly as in the cloud deployment.
- Backups and `serk.json` contain secrets. Anyone with a backup can read the company's books.
- Only administrators should be able to sign in to the server computer itself.

## Known limitations

- **Windows has not been verified on real Windows.** The installer has been built, but it has not yet been installed and run on a real Windows 10/11 or Windows Server machine. Under Wine, the bundled `postgres.exe` does not start because of a Wine limitation unrelated to Serk Finance, so Wine testing could not cover it either. Treat the Windows installer as untested until a Windows run is recorded.
- **Linux:** the `.deb` was installed and verified end to end on a Linux host.
- The Windows installer is not code-signed.
- One server computer per company. There is no offline synchronisation between offices or with the cloud yet (roadmap Phase 5).
- No scheduled backups: run "Back up now" or `serk-finance backup` yourself, or schedule it with Task Scheduler or a systemd timer / cron.
- Backups are not encrypted by Serk Finance. Store them on encrypted media.
- Upgrading from one installer version to the next keeps the data and applies new migrations on start, but downgrading is not supported. Back up before every upgrade.
