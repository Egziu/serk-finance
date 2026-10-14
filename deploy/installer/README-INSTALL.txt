SERK FINANCE — INSTALLATION AND OFFICE SERVER GUIDE
====================================================

What gets installed
-------------------
* The Serk Finance application and web interface.
* Its own PostgreSQL 17 database, which runs on this computer only (127.0.0.1).
* A background service that starts with the computer:
    Windows: the "Serk Finance" service (account: LocalService)
    Linux:   the serk-finance systemd service (account: serk-finance)

Company data lives in:
    Windows: C:\ProgramData\SerkFinance        (administrators and the service only)
    Linux:   /var/lib/serk-finance             (the serk-finance account only)

First start
-----------
1. Open http://localhost:8080 on the server computer. The setup page opens.
2. Enter the company name, a short workspace name (people type it when they sign in), the
   fiscal year (Ethiopian Hamle–Sene by default, or Gregorian), the branches and the first
   administrator. Tick "practice workspace" to also get the demo company for training.
3. Sign in. As administrator, open Users & roles to add your accountants, managers and other
   staff, and Modules & features to switch modules on or off.
From another computer, setup needs the token in the data folder (setup-token.txt):
   http://SERVER-NAME:8080/setup?token=...

Using it from other computers
-----------------------------
Other computers in the office open http://SERVER-NAME:8080 (or the server's IP address, for
example http://192.168.1.20:8080). On Windows the installer opens port 8080 in Windows Firewall
for private and domain networks when "Allow other computers" is ticked.
The connection inside the office uses plain HTTP: use it only on a trusted office network. For
access over the internet, use the cloud edition or put the server behind an HTTPS proxy/VPN.

Backups (do this every day)
---------------------------
Windows: Start menu > Serk Finance > Back up now
Linux:   sudo serk-finance backup
The backup is a .zip in the backups folder of the data folder. Copy it to a USB drive or
another computer. It also contains the installation's secret keys, so keep it safe.

Restore:
Windows (administrator command prompt):
    sc stop SerkFinance
    "C:\Program Files\Serk Finance\serk-server.exe" restore --data "C:\ProgramData\SerkFinance" --from D:\serk-backup-....zip
    sc start SerkFinance
Linux:
    sudo systemctl stop serk-finance
    sudo serk-finance restore --from /path/serk-backup-....zip
    sudo systemctl start serk-finance
The previous database is kept beside the restored one (pgdata.before-restore-...). To restore
on a NEW computer, add --with-settings so the original secret keys are used.

Forgotten password
------------------
Windows: Start menu > Serk Finance > Reset a password
Linux:   sudo serk-finance reset-password --workspace NAME --email user@example.com

AI assistant (optional)
-----------------------
Administrators open Modules & features > AI assistant provider and enter an Anthropic (Claude)
API key, or the address of an AI model server in the office (OpenAI-compatible, for example
Ollama at http://localhost:11434/v1). The assistant answers from the books and prepares drafts;
people still review, submit and approve everything.
To use an office model server on another computer over plain HTTP, set the environment variable
SERK_AI_ALLOW_PRIVATE_HTTP=true for the service.

Changing the port
-----------------
Stop the service, edit "port" in serk.json in the data folder, start the service, and on
Windows update the firewall rule.

Uninstalling
------------
Windows: Settings > Apps > Serk Finance > Uninstall (company data is kept unless you choose
         to delete it).
Linux:   sudo apt remove serk-finance   (data kept)   or   sudo apt purge serk-finance
         For the .tar.gz installation: sudo ./uninstall.sh [--purge]

Requirements
------------
Windows 10 or 11 (64-bit), or Windows Server 2016 or later. Linux: 64-bit with systemd
(Ubuntu 20.04+, Debian 11+). 4 GB RAM and 2 GB free disk space or more.
