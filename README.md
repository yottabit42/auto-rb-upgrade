# MikroTik RouterOS Automatic Backup & Upgrade

Automated RouterOS software updates, RouterBOOT firmware upgrades, and local or emailed configuration backups for MikroTik devices running **RouterOS v7.10+**.

Originally forked from [beeyev/Mikrotik-RouterOS-automatic-backup-and-update](https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update) and modernized for RouterOS v7 with native v7 syntax, simplified internals, CHR/x86 safety, and safe local flash retention on 16 MiB devices.

## Features

- **End-to-end automated upgrades (`osupdate`)**: Checks the configured RouterOS update channel, saves pre-upgrade backups, upgrades RouterOS packages, upgrades bundled RouterBOOT firmware on RouterBOARD hardware, and saves post-upgrade backups.
- **Dual backup formats**: Creates both a binary system backup (`.backup`, optionally password-encrypted) and a compact plain-text export (`.rsc`, optionally including sensitive credentials via `show-sensitive`).
- **Safe for small-flash routers (16 MiB)**: Automatically detects `flash/` vs. root storage and prunes only older backups created by this script when free storage drops below `minFreeSpaceBytes` (default `1.5 MiB`), preserving `backup_before_update_*` files during upgrades unless free space is critically low (`< 512 KiB`).
- **Multiple operating modes**: Run full automated upgrades (`osupdate`), notification-only checks (`osnotify`), or backups only (`backup`).
- **Optional patch-only mode**: Restrict automatic upgrades to patch releases within the same `major.minor` train (for example, `7.25` -> `7.25.1` or `7.24.2` -> `7.24.3`), alerting you when a minor or major upgrade requires manual review.
- **Optional email notifications**: Email notifications and backup attachments via `/tool e-mail` are disabled by default (`sendEmail=false`) so local-only setups work out of the box. When enabled, a failing email delivery aborts the pending upgrade so you are never left without an off-router pre-upgrade backup.
- **CHR / x86 safe**: Automatically skips `/system routerboard` firmware checks on virtual or x86 routers without RouterBOARD hardware.

## Requirements

- **MikroTik RouterOS v7.10 or newer** (relies on ISO `YYYY-MM-DD` clock dates, RouterOS v7 `/export show-sensitive`, and `/tool e-mail get server`).
- **Internet access** from the router to reach GitHub (for wrapper installation) and MikroTik update servers.
- **System Clock / NTP** configured so backup filenames carry accurate timestamps.
- **System Identity** set (`System -> Identity`) to a unique router name so backups are clearly identifiable.

## Quick Install / Update

Run the following commands in a RouterOS terminal to download and run the idempotent installer wrapper [`installBackupAndUpdate.rsc`](installBackupAndUpdate.rsc):

```routeros
{
  /tool fetch url="https://raw.githubusercontent.com/yottabit42/auto-rb-upgrade/master/installBackupAndUpdate.rsc" output=file as-value
  /import file-name="installBackupAndUpdate.rsc"
  :delay 2s
  /file remove [find where name="installBackupAndUpdate.rsc"]
}
```

This creates (or safely updates in place if already installed):
- `/system script` **`BackupAndUpdate`** with policies `ftp,reboot,read,write,policy,test,sensitive`
- `/system scheduler` **`BackupAndUpdate`** running daily at `03:00:00`

> **Note:** Re-running the snippet overwrites the `BackupAndUpdate` script source and scheduler schedule with the defaults from this repository. If you customized configuration variables inside the script, re-apply your local settings afterward or edit the script directly.

To run the script immediately for testing:

```routeros
/system script run BackupAndUpdate
```

## Manual Installation

1. Copy the contents of [`BackupAndUpdate.rsc`](BackupAndUpdate.rsc) and adjust the configuration variables at the top of the file as needed.
2. In WinBox, WebFig, or CLI, create a script named **`BackupAndUpdate`** (the exact name is required because the temporary post-reboot schedulers invoke `/system script run BackupAndUpdate`) with policies **`ftp,reboot,read,write,policy,test,sensitive`**:
   - **GUI:** `System -> Scripts -> Add` -> Name: `BackupAndUpdate`, check `ftp`, `reboot`, `read`, `write`, `policy`, `test`, `sensitive`, paste the script into `Source`, and save.
3. Create a daily scheduled task:
   ```routeros
   /system scheduler add name="BackupAndUpdate" start-date=1970-01-01 start-time=03:00:00 interval=1d \
     on-event="/system script run BackupAndUpdate;" policy=ftp,reboot,read,write,policy,test,sensitive
   ```
4. Test by running `/system script run BackupAndUpdate` and watching `Log` (`Bkp&Upd:` prefix).

## Configuration Reference

All user-configurable variables are defined at the top of [`BackupAndUpdate.rsc`](BackupAndUpdate.rsc):

| Variable | Default | Description |
| :--- | :--- | :--- |
| `scriptMode` | `"osupdate"` | Operating mode: `"osupdate"` (backup + upgrade), `"osnotify"` (notify only), or `"backup"` (backup only). |
| `forceBackup` | `false` | When `true`, create backups on every run even in `"osupdate"` or `"osnotify"` mode when no update is available. |
| `updateChannel` | `"stable"` | RouterOS release channel: `"stable"`, `"long-term"`, `"testing"`, or `"development"`. |
| `installOnlyPatchUpdates` | `false` | When `true` in `"osupdate"` mode, only auto-install patch updates within the same `major.minor` train; report minor/major updates for manual installation. |
| `backupPassword` | `""` | Encryption password for `.backup` files. Leave empty (`""`) for unencrypted backups. |
| `includeSensitiveData` | `true` | Include secrets in exported `.rsc` files (`show-sensitive`) when `true`; omit them (`hide-sensitive`) when `false`. |
| `sendEmail` | `false` | Enable email notifications and backup attachments via `/tool e-mail`. |
| `emailAddress` | `"you@example.com"` | Recipient address used when `sendEmail` is `true`. |
| `keepLocalBackups` | `true` | Keep generated `.backup` and `.rsc` files on the router after emailing. Set `false` to delete newly emailed files from local storage once delivery succeeds. |
| `minFreeSpaceBytes` | `1572864` | Minimum free storage in bytes (`1.5 MiB`) required before creating a backup; triggers cleanup of older backups created by this script. |

## Optional Email Setup

By default, `sendEmail` is `false` and backups remain on the router (`keepLocalBackups=true`). To enable email notifications and backup attachments:

1. Configure your SMTP server in `Tools -> Email` (or via CLI):
   ```routeros
   /tool e-mail set server="smtp.example.com" port=587 tls=starttls \
     user="smtp-user" password="smtp-password" from="router@example.com"
   ```
2. Verify SMTP delivery from the RouterOS terminal:
   ```routeros
   /tool e-mail send to="you@example.com" subject="RouterOS Email Test" body="It works!"
   ```
3. In `System -> Scripts -> BackupAndUpdate`, set `:local sendEmail true;` and `:local emailAddress "you@example.com";` (and optionally `:local keepLocalBackups false;` if you only want backups stored in email).

## How the 3-Step Upgrade Process Works

Because RouterOS updates and RouterBOOT firmware upgrades each require a reboot, `BackupAndUpdate` coordinates across reboots using a transient global variable (`buGlobalVarUpdateStep`, cleared immediately when read) and self-removing startup schedulers:

1. **Step 1 (Check, Pre-Backup & OS Install):** Checks `/system package update` on `updateChannel`. When an upgrade is ready to install, saves `backup_before_update_<device>.{backup,rsc}`, optionally emails them, creates a one-shot startup scheduler `BKPUPD-UPGRADE-ON-NEXT-BOOT`, and runs `/system package update install`.
2. **Step 2 (RouterBOOT Check, after first reboot):** `BKPUPD-UPGRADE-ON-NEXT-BOOT` removes itself and invokes `BackupAndUpdate` with `buGlobalVarUpdateStep=2`. On RouterBOARD devices where `upgrade-firmware != current-firmware`, it runs `/system routerboard upgrade`, creates a one-shot startup scheduler `BKPUPD-FINAL-REPORT-ON-NEXT-BOOT`, and reboots. Otherwise, it falls straight through to Step 3.
3. **Step 3 (Post-Backup & Report):** After waiting 1 minute for network interfaces and WAN connectivity to settle, creates `backup_after_update_<device>.{backup,rsc}` and sends the final report email (if `sendEmail=true`).

## Credits & License

Licensed under the [MIT License](LICENSE).

- Original RouterOS v6 script by Alexander Tebiev ([beeyev/Mikrotik-RouterOS-automatic-backup-and-update](https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update)).
- RouterOS v7 modernization, simplification, installer wrapper, and documentation by Jacob McDonald ([yottabit42](https://github.com/yottabit42)).
