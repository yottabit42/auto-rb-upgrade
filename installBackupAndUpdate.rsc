###
# Run the following commands in a RouterOS v7.10+ terminal to install or update BackupAndUpdate:
# {
#   :local dl [/tool fetch url="https://raw.githubusercontent.com/yottabit42/auto-rb-upgrade/master/installBackupAndUpdate.rsc" output=user as-value]
#   :if (($dl->"status") = "finished") do={ [[:parse ($dl->"data")]] }
# }
###

:if ([:len [/system script find where name="BackupAndUpdate"]] = 0) do={
  /system script add name="BackupAndUpdate"
}
/system script set [find where name="BackupAndUpdate"] dont-require-permissions=no \
  policy=ftp,reboot,read,write,policy,test,sensitive \
  source="# Script name: BackupAndUpdate\r\
    \n# Repository: https://github.com/yottabit42/auto-rb-upgrade\r\
    \n# Originally forked from https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update (v20.04.17).\r\
    \n# Minimum supported RouterOS version: v7.10\r\
    \n# Required policies: ftp, reboot, read, write, policy, test, sensitive\r\
    \n\r\
    \n#----------MODIFY THIS SECTION AS NEEDED----------------------------------------\r\
    \n# Script operating mode:\r\
    \n#   \"osupdate\" - Create backups and install new RouterOS and RouterBOOT updates when available.\r\
    \n#   \"osnotify\" - Check for new RouterOS updates and send an email notification without installing.\r\
    \n#   \"backup\"   - Create backups only (no update check or installation).\r\
    \n:local scriptMode \"osupdate\";\r\
    \n\r\
    \n# Set to true to create backups on every run, even in \"osupdate\" or \"osnotify\" mode when no update is pending.\r\
    \n:local forceBackup false;\r\
    \n\r\
    \n# RouterOS update channel: \"stable\", \"long-term\", \"testing\", or \"development\".\r\
    \n:local updateChannel \"stable\";\r\
    \n\r\
    \n# When true in \"osupdate\" mode, automatically install only patch updates within the same major.minor\r\
    \n# release train (for example, 7.25 -> 7.25.1 or 7.24.2 -> 7.24.3).\r\
    \n# Minor or major releases are reported instead so you can install them manually.\r\
    \n:local installOnlyPatchUpdates false;\r\
    \n\r\
    \n# Password to encrypt binary .backup files; leave empty (\"\") for unencrypted backups.\r\
    \n:local backupPassword \"\";\r\
    \n\r\
    \n# When true, include passwords and secrets in exported .rsc configurations (show-sensitive).\r\
    \n# When false, omit secrets from exported .rsc files (hide-sensitive).\r\
    \n:local includeSensitiveData true;\r\
    \n\r\
    \n# Set to true to send email notifications and backup attachments via /tool e-mail.\r\
    \n# Make sure SMTP settings are configured in Tools -> Email before enabling.\r\
    \n:local sendEmail false;\r\
    \n\r\
    \n# Recipient email address used when sendEmail is true.\r\
    \n:local emailAddress \"you@example.com\";\r\
    \n\r\
    \n# When true, keep generated .backup and .rsc files on the router even after emailing them.\r\
    \n# When false, remove the newly created files from the router once email delivery succeeds.\r\
    \n:local keepLocalBackups true;\r\
    \n\r\
    \n# Minimum free storage (in bytes) required before creating a new backup (default: 1572864 = 1.5 MiB).\r\
    \n# If free space is below this threshold, older backups created by this script are deleted first.\r\
    \n:local minFreeSpaceBytes 1572864;\r\
    \n\r\
    \n##----------------------------------------------------------------------------##\r\
    \n#  Do not modify anything below this line unless you know what you are doing.  #\r\
    \n##----------------------------------------------------------------------------##\r\
    \n\r\
    \n:local logPrefix \"Bkp&Upd:\";\r\
    \n\r\
    \n:log info \"\$logPrefix Script \\\"MikroTik RouterOS Automatic Backup & Update\\\" started.\";\r\
    \n:log info \"\$logPrefix Mode: \$scriptMode, forceBackup: \$forceBackup\";\r\
    \n\r\
    \n# Validate SMTP settings when email notifications are enabled.\r\
    \n:if (\$sendEmail = true) do={\r\
    \n  :local mailSrv [:tostr [/tool e-mail get server]];\r\
    \n  :local mailFrom [:tostr [/tool e-mail get from]];\r\
    \n  :if ([:len \$emailAddress] = 0 or [:len \$mailSrv] = 0 or \$mailSrv = \"0.0.0.0\" or [:len \$mailFrom] = 0 or \$mailFrom = \"<>\") do={\r\
    \n    :log error \"\$logPrefix Email configuration is incomplete. Please check Tools -> Email.\";\r\
    \n  }\r\
    \n}\r\
    \n\r\
    \n# Warn if the device still uses the default identity.\r\
    \n:local deviceIdentityName [/system identity get name];\r\
    \n:if ([:len \$deviceIdentityName] = 0 or \$deviceIdentityName = \"MikroTik\") do={\r\
    \n  :log warning \"\$logPrefix Please configure a unique device name under System -> Identity.\";\r\
    \n}\r\
    \n\r\
    \n# Extract the major.minor portion of a RouterOS version string (stripping alpha/beta/rc tags).\r\
    \n:local getMajorMinor do={\r\
    \n  :local v [:tostr \$ver];\r\
    \n  :foreach tag in={\"alpha\"; \"beta\"; \"rc\"; \" \"} do={\r\
    \n    :local pos [:find \$v \$tag];\r\
    \n    :if ([:typeof \$pos] = \"num\") do={\r\
    \n      :set v [:pick \$v 0 \$pos];\r\
    \n    }\r\
    \n  }\r\
    \n  :local dot1 [:find \$v \".\"];\r\
    \n  :if ([:typeof \$dot1] != \"num\") do={ :return \$v; }\r\
    \n  :local dot2 [:find \$v \".\" (\$dot1 + 1)];\r\
    \n  :if ([:typeof \$dot2] = \"num\") do={ :return [:pick \$v 0 \$dot2]; }\r\
    \n  :return \$v;\r\
    \n}\r\
    \n\r\
    \n# Create binary (.backup) and plain-text (.rsc) backups and return their file paths as an array.\r\
    \n:local createBackups do={\r\
    \n  :local logPrefix \"Bkp&Upd:\";\r\
    \n  :local filePrefix \"\";\r\
    \n  :if ([:len [/file find where name=\"flash\"]] > 0) do={\r\
    \n    :set filePrefix \"flash/\";\r\
    \n  }\r\
    \n\r\
    \n  :local backupFileSys (\$filePrefix . \$backupName . \".backup\");\r\
    \n  :local backupFileConfig (\$filePrefix . \$backupName . \".rsc\");\r\
    \n  :local backupNames {\$backupFileSys; \$backupFileConfig};\r\
    \n\r\
    \n  # Prune older backups created by this script if free storage is below minFreeSpaceBytes.\r\
    \n  :local ownBackupPattern \"\\\\.v[0-9]+\\\\.[0-9]+.*\\\\.(backup|rsc)\\\$\";\r\
    \n  :if ([/system resource get free-hdd-space] < \$minFreeSpaceBytes) do={\r\
    \n    :if (\$preserveBeforeBackup = true) do={\r\
    \n      :log info \"\$logPrefix Free storage is low; pruning old script backups while keeping pre-upgrade backups.\";\r\
    \n      :local nonBeforeFiles [/file find where name~\$ownBackupPattern and !(name~\"backup_before_update_\")];\r\
    \n      :if ([:len \$nonBeforeFiles] > 0) do={\r\
    \n        /file remove \$nonBeforeFiles;\r\
    \n      }\r\
    \n      :if ([/system resource get free-hdd-space] < 524288) do={\r\
    \n        :log warning \"\$logPrefix Free storage is critically low (< 512 KiB); pruning remaining script backups.\";\r\
    \n        :local allOwnFiles [/file find where name~\$ownBackupPattern];\r\
    \n        :if ([:len \$allOwnFiles] > 0) do={\r\
    \n          /file remove \$allOwnFiles;\r\
    \n        }\r\
    \n      }\r\
    \n    } else={\r\
    \n      :log info \"\$logPrefix Free storage is low; pruning old script backups.\";\r\
    \n      :local oldFiles [/file find where name~\$ownBackupPattern];\r\
    \n      :if ([:len \$oldFiles] > 0) do={\r\
    \n        /file remove \$oldFiles;\r\
    \n      }\r\
    \n    }\r\
    \n  }\r\
    \n\r\
    \n  # Save binary system backup.\r\
    \n  :if ([:len \$backupPassword] = 0) do={\r\
    \n    /system backup save dont-encrypt=yes name=(\$filePrefix . \$backupName);\r\
    \n  } else={\r\
    \n    /system backup save password=\$backupPassword name=(\$filePrefix . \$backupName);\r\
    \n  }\r\
    \n  :log info \"\$logPrefix Created system backup: \$backupFileSys\";\r\
    \n\r\
    \n  # Export plain-text configuration (RouterOS v7 requires show-sensitive to include secrets).\r\
    \n  :if (\$includeSensitiveData = true) do={\r\
    \n    /export compact show-sensitive file=(\$filePrefix . \$backupName);\r\
    \n  } else={\r\
    \n    /export compact hide-sensitive file=(\$filePrefix . \$backupName);\r\
    \n  }\r\
    \n  :log info \"\$logPrefix Exported configuration: \$backupFileConfig\";\r\
    \n\r\
    \n  :delay 5s;\r\
    \n  :return \$backupNames;\r\
    \n}\r\
    \n\r\
    \n# Build ISO-based timestamp (YYYYMMDD-HHMMSS) from RouterOS v7.10+ clock format.\r\
    \n:local rawDate [/system clock get date];\r\
    \n:local rawTime [/system clock get time];\r\
    \n:local dateTime ([:pick \$rawDate 0 4] . [:pick \$rawDate 5 7] . [:pick \$rawDate 8 10] . \"-\" . [:pick \$rawTime 0 2] . [:pick \$rawTime 3 5] . [:pick \$rawTime 6 8]);\r\
    \n\r\
    \n# Gather device and firmware details (guarded for CHR/x86 devices without RouterBOARD hardware).\r\
    \n:local deviceOsVerInst [:tostr [/system package update get installed-version]];\r\
    \n:local deviceOsVerAvail \"\";\r\
    \n:local deviceUpdateChannel [:tostr [/system package update get channel]];\r\
    \n:local deviceIdentityNameShort [:pick \$deviceIdentityName 0 18];\r\
    \n\r\
    \n:local isRouterBoard false;\r\
    \n:local deviceModel [:tostr [/system resource get board-name]];\r\
    \n:local deviceSerialNumber \"noserial\";\r\
    \n:local deviceCurrentFw \"N/A\";\r\
    \n:local deviceUpgradeFw \"N/A\";\r\
    \n:do {\r\
    \n  :if ([/system routerboard get routerboard] = true) do={\r\
    \n    :set isRouterBoard true;\r\
    \n    :set deviceModel [:tostr [/system routerboard get model]];\r\
    \n    :set deviceSerialNumber [:tostr [/system routerboard get serial-number]];\r\
    \n    :set deviceCurrentFw [:tostr [/system routerboard get current-firmware]];\r\
    \n    :set deviceUpgradeFw [:tostr [/system routerboard get upgrade-firmware]];\r\
    \n  }\r\
    \n} on-error={}\r\
    \n\r\
    \n:local isOsUpdateAvailable false;\r\
    \n:local isOsNeedsToBeUpdated false;\r\
    \n:local isSendEmailRequired true;\r\
    \n\r\
    \n:local mailSubject \"\$logPrefix Device - \$deviceIdentityNameShort.\";\r\
    \n:local mailBody \"\";\r\
    \n:local mailBodyDeviceInfo (\"\\r\\n\\r\\nDevice information:\\r\\nIdentity: \$deviceIdentityName\\r\\nModel: \$deviceModel\\r\\nSerial number: \$deviceSerialNumber\\r\\nRouterOS version: \$deviceOsVerInst (\$deviceUpdateChannel) \$[/system resource get build-time]\\r\\nRouterBOOT firmware: \$deviceCurrentFw\\r\\nUptime: \$[/system resource get uptime]\");\r\
    \n:local mailBodyFooter \"\\r\\n\\r\\nMikroTik RouterOS Automatic Backup & Update\\r\\nhttps://github.com/yottabit42/auto-rb-upgrade\";\r\
    \n:local changelogUrl \"Check the RouterOS changelog: https://mikrotik.com/download/changelogs/\$updateChannel-release-tree\";\r\
    \n\r\
    \n:local backupName \"\$deviceIdentityName.\$deviceModel.\$deviceSerialNumber.v\$deviceOsVerInst.\$deviceUpdateChannel.\$dateTime\";\r\
    \n:local backupNameBeforeUpd \"backup_before_update_\$backupName\";\r\
    \n:local backupNameAfterUpd \"backup_after_update_\$backupName\";\r\
    \n:local backupNameFinal \$backupName;\r\
    \n:local mailAttachments [:toarray \"\"];\r\
    \n\r\
    \n# Read and clear the multi-reboot step marker from the global environment.\r\
    \n:global buGlobalVarUpdateStep;\r\
    \n:local updateStep \$buGlobalVarUpdateStep;\r\
    \n:do { /system script environment remove buGlobalVarUpdateStep; } on-error={}\r\
    \n:if ([:len \$updateStep] = 0) do={\r\
    \n  :set updateStep 1;\r\
    \n}\r\
    \n\r\
    \n## STEP ONE: Check for RouterOS updates, create backups, and initiate upgrade if needed.\r\
    \n:if (\$updateStep = 1) do={\r\
    \n  :log info \"\$logPrefix Running step 1.\";\r\
    \n\r\
    \n  :if (\$scriptMode = \"osupdate\" or \$scriptMode = \"osnotify\") do={\r\
    \n    :log info \"\$logPrefix Checking for RouterOS updates on the '\$updateChannel' channel (current: v\$deviceOsVerInst).\";\r\
    \n    /system package update set channel=\$updateChannel;\r\
    \n    :local checkFailed false;\r\
    \n    :do { /system package update check-for-updates; } on-error={ :set checkFailed true; }\r\
    \n    :delay 3s;\r\
    \n    :set deviceOsVerAvail [:tostr [/system package update get latest-version]];\r\
    \n    :local updStatus [:tostr [/system package update get status]];\r\
    \n\r\
    \n    :if (\$checkFailed = true or [:len \$deviceOsVerAvail] = 0 or [:typeof [:find \$updStatus \"ERROR\"]] = \"num\") do={\r\
    \n      :log warning \"\$logPrefix Failed to retrieve update information from MikroTik servers (status: \$updStatus).\";\r\
    \n      :set mailSubject \"\$mailSubject Error: Unable to check for RouterOS updates.\";\r\
    \n      :set mailBody \"An error occurred while checking for RouterOS updates.\\r\\nStatus: \$updStatus\\r\\nCheck the device logs for details.\";\r\
    \n    } else={\r\
    \n      :if (\$updStatus = \"New version is available\" and \$deviceOsVerAvail != \$deviceOsVerInst) do={\r\
    \n        :set isOsUpdateAvailable true;\r\
    \n        :log info \"\$logPrefix New RouterOS version available: v\$deviceOsVerAvail\";\r\
    \n      } else={\r\
    \n        :set isSendEmailRequired false;\r\
    \n        :log info \"\$logPrefix System is already up to date (v\$deviceOsVerInst).\";\r\
    \n        :set mailSubject \"\$mailSubject No new RouterOS updates.\";\r\
    \n        :set mailBody \"Your RouterOS system is already up to date (v\$deviceOsVerInst).\";\r\
    \n      }\r\
    \n    }\r\
    \n  } else={\r\
    \n    :set scriptMode \"backup\";\r\
    \n  }\r\
    \n\r\
    \n  :if (\$forceBackup = true) do={\r\
    \n    :set isSendEmailRequired true;\r\
    \n  }\r\
    \n\r\
    \n  :if (\$isOsUpdateAvailable = true and \$isSendEmailRequired = true) do={\r\
    \n    :if (\$scriptMode = \"osnotify\") do={\r\
    \n      :set mailSubject \"\$mailSubject New RouterOS available: v\$deviceOsVerAvail.\";\r\
    \n      :set mailBody \"A new RouterOS version is available to install: v\$deviceOsVerAvail (\$updateChannel).\\r\\n\$changelogUrl\";\r\
    \n    }\r\
    \n\r\
    \n    :if (\$scriptMode = \"osupdate\") do={\r\
    \n      :set isOsNeedsToBeUpdated true;\r\
    \n      :if (\$installOnlyPatchUpdates = true) do={\r\
    \n        :if ([\$getMajorMinor ver=\$deviceOsVerInst] = [\$getMajorMinor ver=\$deviceOsVerAvail]) do={\r\
    \n          :log info \"\$logPrefix New patch release is available within the current major.minor train.\";\r\
    \n        } else={\r\
    \n          :log info \"\$logPrefix New minor or major RouterOS release (v\$deviceOsVerAvail) requires manual upgrade.\";\r\
    \n          :set mailSubject \"\$mailSubject RouterOS v\$deviceOsVerAvail requires manual upgrade.\";\r\
    \n          :set mailBody \"A new minor or major RouterOS version is available: v\$deviceOsVerAvail (\$updateChannel).\\r\\nAutomatic installation is limited to patch releases, so please install this update manually.\\r\\n\$changelogUrl\";\r\
    \n          :set isOsNeedsToBeUpdated false;\r\
    \n        }\r\
    \n      }\r\
    \n\r\
    \n      :if (\$isOsNeedsToBeUpdated = true) do={\r\
    \n        :log info \"\$logPrefix Preparing to upgrade RouterOS from v\$deviceOsVerInst to v\$deviceOsVerAvail.\";\r\
    \n        :set mailSubject \"\$mailSubject Upgrading RouterOS v\$deviceOsVerInst -> v\$deviceOsVerAvail.\";\r\
    \n        :set mailBody \"Your MikroTik router will be upgraded from RouterOS v\$deviceOsVerInst to v\$deviceOsVerAvail (channel: \$updateChannel).\\r\\nA final report will be sent after the upgrade completes.\";\r\
    \n      }\r\
    \n    }\r\
    \n  }\r\
    \n\r\
    \n  :if (\$forceBackup = true or \$scriptMode = \"backup\" or \$isOsNeedsToBeUpdated = true) do={\r\
    \n    :log info \"\$logPrefix Creating system backups.\";\r\
    \n    :if (\$isOsNeedsToBeUpdated = true) do={\r\
    \n      :set backupNameFinal \$backupNameBeforeUpd;\r\
    \n    }\r\
    \n    :if (\$scriptMode != \"backup\") do={\r\
    \n      :set mailBody (\$mailBody . \"\\r\\n\\r\\n\");\r\
    \n    }\r\
    \n    :set mailSubject \"\$mailSubject Backup created.\";\r\
    \n    :set mailBody (\$mailBody . \"System backups were created.\");\r\
    \n    :set mailAttachments [\$createBackups backupName=\$backupNameFinal backupPassword=\$backupPassword includeSensitiveData=\$includeSensitiveData minFreeSpaceBytes=\$minFreeSpaceBytes preserveBeforeBackup=false];\r\
    \n  } else={\r\
    \n    :log info \"\$logPrefix No backup is needed on this run.\";\r\
    \n  }\r\
    \n\r\
    \n  :set mailBody (\$mailBody . \$mailBodyDeviceInfo . \$mailBodyFooter);\r\
    \n}\r\
    \n\r\
    \n## STEP TWO: After the OS upgrade reboot, upgrade RouterBOOT firmware if a newer version is bundled.\r\
    \n:if (\$updateStep = 2) do={\r\
    \n  :log info \"\$logPrefix Running step 2 (RouterBOOT check).\";\r\
    \n  :if (\$isRouterBoard = true and \$deviceCurrentFw != \$deviceUpgradeFw) do={\r\
    \n    :set isSendEmailRequired false;\r\
    \n    :delay 10s;\r\
    \n    :log info \"\$logPrefix Upgrading RouterBOOT firmware from v\$deviceCurrentFw to v\$deviceUpgradeFw.\";\r\
    \n    /system routerboard upgrade;\r\
    \n    :delay 5s;\r\
    \n    :log info \"\$logPrefix RouterBOOT firmware upgraded; scheduling final report and rebooting.\";\r\
    \n    :do { /system scheduler remove [find where name=\"BKPUPD-FINAL-REPORT-ON-NEXT-BOOT\"]; } on-error={}\r\
    \n    /system scheduler add name=\"BKPUPD-FINAL-REPORT-ON-NEXT-BOOT\" start-time=startup interval=0s policy=ftp,reboot,read,write,policy,test,sensitive on-event=\":delay 5s; /system scheduler remove [find where name=\\\"BKPUPD-FINAL-REPORT-ON-NEXT-BOOT\\\"]; :global buGlobalVarUpdateStep 3; :delay 10s; /system script run BackupAndUpdate;\";\r\
    \n    /system reboot;\r\
    \n  } else={\r\
    \n    :log info \"\$logPrefix RouterBOOT firmware is already up to date (or not applicable); proceeding to step 3.\";\r\
    \n    :set updateStep 3;\r\
    \n  }\r\
    \n}\r\
    \n\r\
    \n## STEP THREE: Create post-upgrade backups and prepare the final completion report.\r\
    \n:if (\$updateStep = 3) do={\r\
    \n  :log info \"\$logPrefix Running step 3 (post-upgrade report).\";\r\
    \n  :log info \"\$logPrefix Upgrade complete. RouterOS: v\$deviceOsVerInst, RouterBOOT firmware: v\$deviceCurrentFw.\";\r\
    \n  :log info \"\$logPrefix Waiting 1 minute before creating post-upgrade backups and sending final report.\";\r\
    \n  :delay 1m;\r\
    \n  :set mailSubject \"\$mailSubject RouterOS upgrade complete (v\$deviceOsVerInst).\";\r\
    \n  :set mailBody \"RouterOS and RouterBOOT upgrades are complete.\\r\\nRouterOS version: v\$deviceOsVerInst\\r\\nRouterBOOT firmware: v\$deviceCurrentFw\\r\\n\$changelogUrl\\r\\n\\r\\nPost-upgrade backups have been created.\$mailBodyDeviceInfo\$mailBodyFooter\";\r\
    \n  :set mailAttachments [\$createBackups backupName=\$backupNameAfterUpd backupPassword=\$backupPassword includeSensitiveData=\$includeSensitiveData minFreeSpaceBytes=\$minFreeSpaceBytes preserveBeforeBackup=true];\r\
    \n}\r\
    \n\r\
    \n## Send email notification (when enabled and required) and optionally clean up local backup files.\r\
    \n:if (\$isSendEmailRequired = true and \$sendEmail = true) do={\r\
    \n  :local emailSentOk false;\r\
    \n  :log info \"\$logPrefix Sending email notification...\";\r\
    \n  :do {\r\
    \n    /tool e-mail send to=\$emailAddress subject=\$mailSubject body=\$mailBody file=\$mailAttachments;\r\
    \n    :set emailSentOk true;\r\
    \n  } on-error={\r\
    \n    :delay 5s;\r\
    \n    :log error \"\$logPrefix Failed to send email; retrying in 5 minutes.\";\r\
    \n    :delay 5m;\r\
    \n    :do {\r\
    \n      /tool e-mail send to=\$emailAddress subject=\$mailSubject body=\$mailBody file=\$mailAttachments;\r\
    \n      :set emailSentOk true;\r\
    \n    } on-error={\r\
    \n      :delay 5s;\r\
    \n      :log error \"\$logPrefix Failed to send email on the second attempt.\";\r\
    \n      :if (\$isOsNeedsToBeUpdated = true) do={\r\
    \n        :set isOsNeedsToBeUpdated false;\r\
    \n        :log warning \"\$logPrefix Aborting RouterOS upgrade because pre-upgrade backups could not be emailed.\";\r\
    \n      }\r\
    \n    }\r\
    \n  }\r\
    \n\r\
    \n  :delay 30s;\r\
    \n\r\
    \n  :if (\$keepLocalBackups = false and [:len \$mailAttachments] > 0 and \$emailSentOk = true) do={\r\
    \n    :log info \"\$logPrefix Removing local backup files after successful email delivery.\";\r\
    \n    /file remove \$mailAttachments;\r\
    \n    :delay 2s;\r\
    \n  }\r\
    \n}\r\
    \n\r\
    \n## Trigger RouterOS package download/install and schedule Step 2 for next boot.\r\
    \n:if (\$isOsNeedsToBeUpdated = true) do={\r\
    \n  :do { /system scheduler remove [find where name=\"BKPUPD-UPGRADE-ON-NEXT-BOOT\"]; } on-error={}\r\
    \n  /system scheduler add name=\"BKPUPD-UPGRADE-ON-NEXT-BOOT\" start-time=startup interval=0s policy=ftp,reboot,read,write,policy,test,sensitive on-event=\":delay 5s; /system scheduler remove [find where name=\\\"BKPUPD-UPGRADE-ON-NEXT-BOOT\\\"]; :global buGlobalVarUpdateStep 2; :delay 10s; /system script run BackupAndUpdate;\";\r\
    \n  :log info \"\$logPrefix Installing new RouterOS packages; router will reboot automatically.\";\r\
    \n  /system package update install;\r\
    \n}\r\
    \n\r\
    \n:log info \"\$logPrefix Script \\\"MikroTik RouterOS Automatic Backup & Update\\\" finished.\";\r\
    \n"

:if ([:len [/system scheduler find where name="BackupAndUpdate"]] = 0) do={
  /system scheduler add name="BackupAndUpdate" on-event="/system script run BackupAndUpdate;"
}
/system scheduler set [find where name="BackupAndUpdate"] disabled=no \
  start-date=1970-01-01 start-time=03:00:00 interval=1d \
  on-event="/system script run BackupAndUpdate;" \
  policy=ftp,reboot,read,write,policy,test,sensitive
