# Script name: BackupAndUpdate
# Repository: https://github.com/yottabit42/auto-rb-upgrade
# Originally forked from https://github.com/beeyev/Mikrotik-RouterOS-automatic-backup-and-update (v20.04.17).
# Minimum supported RouterOS version: v7.10
# Required policies: ftp, reboot, read, write, policy, test, sensitive

#----------MODIFY THIS SECTION AS NEEDED----------------------------------------
# Script operating mode:
#   "osupdate" - Create backups and install new RouterOS and RouterBOOT updates when available.
#   "osnotify" - Check for new RouterOS updates and send an email notification without installing.
#   "backup"   - Create backups only (no update check or installation).
:local scriptMode "osupdate";

# Set to true to create backups on every run, even in "osupdate" or "osnotify" mode when no update is pending.
:local forceBackup false;

# RouterOS update channel: "stable", "long-term", "testing", or "development".
:local updateChannel "stable";

# When true in "osupdate" mode, automatically install only patch updates within the same major.minor
# release train (for example, 7.25 -> 7.25.1 or 7.24.2 -> 7.24.3).
# Minor or major releases are reported instead so you can install them manually.
:local installOnlyPatchUpdates false;

# Password to encrypt binary .backup files; leave empty ("") for unencrypted backups.
:local backupPassword "";

# When true, include passwords and secrets in exported .rsc configurations (show-sensitive).
# When false, omit secrets from exported .rsc files (hide-sensitive).
:local includeSensitiveData true;

# Set to true to send email notifications and backup attachments via /tool e-mail.
# Make sure SMTP settings are configured in Tools -> Email before enabling.
:local sendEmail false;

# Recipient email address used when sendEmail is true.
:local emailAddress "you@example.com";

# When true, keep generated .backup and .rsc files on the router even after emailing them.
# When false, remove the newly created files from the router once email delivery succeeds.
:local keepLocalBackups true;

# Minimum free storage (in bytes) required before creating a new backup (default: 1572864 = 1.5 MiB).
# If free space is below this threshold, older backups created by this script are deleted first.
:local minFreeSpaceBytes 1572864;

##----------------------------------------------------------------------------##
#  Do not modify anything below this line unless you know what you are doing.  #
##----------------------------------------------------------------------------##

:local logPrefix "Bkp&Upd:";

:log info "$logPrefix Script \"MikroTik RouterOS Automatic Backup & Update\" started.";
:log info "$logPrefix Mode: $scriptMode, forceBackup: $forceBackup";

# Validate SMTP settings when email notifications are enabled.
:if ($sendEmail = true) do={
  :local mailSrv [:tostr [/tool e-mail get server]];
  :local mailFrom [:tostr [/tool e-mail get from]];
  :if ([:len $emailAddress] = 0 or [:len $mailSrv] = 0 or $mailSrv = "0.0.0.0" or [:len $mailFrom] = 0 or $mailFrom = "<>") do={
    :log error "$logPrefix Email configuration is incomplete. Please check Tools -> Email.";
  }
}

# Warn if the device still uses the default identity.
:local deviceIdentityName [/system identity get name];
:if ([:len $deviceIdentityName] = 0 or $deviceIdentityName = "MikroTik") do={
  :log warning "$logPrefix Please configure a unique device name under System -> Identity.";
}

# Extract the major.minor portion of a RouterOS version string (stripping alpha/beta/rc tags).
:local getMajorMinor do={
  :local v [:tostr $ver];
  :foreach tag in={"alpha"; "beta"; "rc"; " "} do={
    :local pos [:find $v $tag];
    :if ([:typeof $pos] = "num") do={
      :set v [:pick $v 0 $pos];
    }
  }
  :local dot1 [:find $v "."];
  :if ([:typeof $dot1] != "num") do={ :return $v; }
  :local dot2 [:find $v "." ($dot1 + 1)];
  :if ([:typeof $dot2] = "num") do={ :return [:pick $v 0 $dot2]; }
  :return $v;
}

# Create binary (.backup) and plain-text (.rsc) backups and return their file paths as an array.
:local createBackups do={
  :local logPrefix "Bkp&Upd:";
  :local filePrefix "";
  :if ([:len [/file find where name="flash"]] > 0) do={
    :set filePrefix "flash/";
  }

  :local backupFileSys ($filePrefix . $backupName . ".backup");
  :local backupFileConfig ($filePrefix . $backupName . ".rsc");
  :local backupNames {$backupFileSys; $backupFileConfig};

  # Prune older backups created by this script if free storage is below minFreeSpaceBytes.
  :local ownBackupPattern "\\.v[0-9]+\\.[0-9]+.*\\.(backup|rsc)\$";
  :if ([/system resource get free-hdd-space] < $minFreeSpaceBytes) do={
    :if ($preserveBeforeBackup = true) do={
      :log info "$logPrefix Free storage is low; pruning old script backups while keeping pre-upgrade backups.";
      :local nonBeforeFiles [/file find where name~$ownBackupPattern and !(name~"backup_before_update_")];
      :if ([:len $nonBeforeFiles] > 0) do={
        /file remove $nonBeforeFiles;
      }
      :if ([/system resource get free-hdd-space] < 524288) do={
        :log warning "$logPrefix Free storage is critically low (< 512 KiB); pruning remaining script backups.";
        :local allOwnFiles [/file find where name~$ownBackupPattern];
        :if ([:len $allOwnFiles] > 0) do={
          /file remove $allOwnFiles;
        }
      }
    } else={
      :log info "$logPrefix Free storage is low; pruning old script backups.";
      :local oldFiles [/file find where name~$ownBackupPattern];
      :if ([:len $oldFiles] > 0) do={
        /file remove $oldFiles;
      }
    }
  }

  # Save binary system backup.
  :if ([:len $backupPassword] = 0) do={
    /system backup save dont-encrypt=yes name=($filePrefix . $backupName);
  } else={
    /system backup save password=$backupPassword name=($filePrefix . $backupName);
  }
  :log info "$logPrefix Created system backup: $backupFileSys";

  # Export plain-text configuration (RouterOS v7 requires show-sensitive to include secrets).
  :if ($includeSensitiveData = true) do={
    /export compact show-sensitive file=($filePrefix . $backupName);
  } else={
    /export compact hide-sensitive file=($filePrefix . $backupName);
  }
  :log info "$logPrefix Exported configuration: $backupFileConfig";

  :delay 5s;
  :return $backupNames;
}

# Build ISO-based timestamp (YYYYMMDD-HHMMSS) from RouterOS v7.10+ clock format.
:local rawDate [/system clock get date];
:local rawTime [/system clock get time];
:local dateTime ([:pick $rawDate 0 4] . [:pick $rawDate 5 7] . [:pick $rawDate 8 10] . "-" . [:pick $rawTime 0 2] . [:pick $rawTime 3 5] . [:pick $rawTime 6 8]);

# Gather device and firmware details (guarded for CHR/x86 devices without RouterBOARD hardware).
:local deviceOsVerInst [:tostr [/system package update get installed-version]];
:local deviceOsVerAvail "";
:local deviceUpdateChannel [:tostr [/system package update get channel]];
:local deviceIdentityNameShort [:pick $deviceIdentityName 0 18];

:local isRouterBoard false;
:local deviceModel [:tostr [/system resource get board-name]];
:local deviceSerialNumber "noserial";
:local deviceCurrentFw "N/A";
:local deviceUpgradeFw "N/A";
:do {
  :if ([/system routerboard get routerboard] = true) do={
    :set isRouterBoard true;
    :set deviceModel [:tostr [/system routerboard get model]];
    :set deviceSerialNumber [:tostr [/system routerboard get serial-number]];
    :set deviceCurrentFw [:tostr [/system routerboard get current-firmware]];
    :set deviceUpgradeFw [:tostr [/system routerboard get upgrade-firmware]];
  }
} on-error={}

:local isOsUpdateAvailable false;
:local isOsNeedsToBeUpdated false;
:local isSendEmailRequired true;

:local mailSubject "$logPrefix Device - $deviceIdentityNameShort.";
:local mailBody "";
:local mailBodyDeviceInfo ("\r\n\r\nDevice information:\r\nIdentity: $deviceIdentityName\r\nModel: $deviceModel\r\nSerial number: $deviceSerialNumber\r\nRouterOS version: $deviceOsVerInst ($deviceUpdateChannel) $[/system resource get build-time]\r\nRouterBOOT firmware: $deviceCurrentFw\r\nUptime: $[/system resource get uptime]");
:local mailBodyFooter "\r\n\r\nMikroTik RouterOS Automatic Backup & Update\r\nhttps://github.com/yottabit42/auto-rb-upgrade";
:local changelogUrl "Check the RouterOS changelog: https://mikrotik.com/download/changelogs/$updateChannel-release-tree";

:local backupName "$deviceIdentityName.$deviceModel.$deviceSerialNumber.v$deviceOsVerInst.$deviceUpdateChannel.$dateTime";
:local backupNameBeforeUpd "backup_before_update_$backupName";
:local backupNameAfterUpd "backup_after_update_$backupName";
:local backupNameFinal $backupName;
:local mailAttachments [:toarray ""];

# Read and clear the multi-reboot step marker from the global environment.
:global buGlobalVarUpdateStep;
:local updateStep $buGlobalVarUpdateStep;
:do { /system script environment remove buGlobalVarUpdateStep; } on-error={}
:if ([:len $updateStep] = 0) do={
  :set updateStep 1;
}

## STEP ONE: Check for RouterOS updates, create backups, and initiate upgrade if needed.
:if ($updateStep = 1) do={
  :log info "$logPrefix Running step 1.";

  :if ($scriptMode = "osupdate" or $scriptMode = "osnotify") do={
    :log info "$logPrefix Checking for RouterOS updates on the '$updateChannel' channel (current: v$deviceOsVerInst).";
    /system package update set channel=$updateChannel;
    :local checkFailed false;
    :do { /system package update check-for-updates; } on-error={ :set checkFailed true; }
    :delay 3s;
    :set deviceOsVerAvail [:tostr [/system package update get latest-version]];
    :local updStatus [:tostr [/system package update get status]];

    :if ($checkFailed = true or [:len $deviceOsVerAvail] = 0 or [:typeof [:find $updStatus "ERROR"]] = "num") do={
      :log warning "$logPrefix Failed to retrieve update information from MikroTik servers (status: $updStatus).";
      :set mailSubject "$mailSubject Error: Unable to check for RouterOS updates.";
      :set mailBody "An error occurred while checking for RouterOS updates.\r\nStatus: $updStatus\r\nCheck the device logs for details.";
    } else={
      :if ($updStatus = "New version is available" and $deviceOsVerAvail != $deviceOsVerInst) do={
        :set isOsUpdateAvailable true;
        :log info "$logPrefix New RouterOS version available: v$deviceOsVerAvail";
      } else={
        :set isSendEmailRequired false;
        :log info "$logPrefix System is already up to date (v$deviceOsVerInst).";
        :set mailSubject "$mailSubject No new RouterOS updates.";
        :set mailBody "Your RouterOS system is already up to date (v$deviceOsVerInst).";
      }
    }
  } else={
    :set scriptMode "backup";
  }

  :if ($forceBackup = true) do={
    :set isSendEmailRequired true;
  }

  :if ($isOsUpdateAvailable = true and $isSendEmailRequired = true) do={
    :if ($scriptMode = "osnotify") do={
      :set mailSubject "$mailSubject New RouterOS available: v$deviceOsVerAvail.";
      :set mailBody "A new RouterOS version is available to install: v$deviceOsVerAvail ($updateChannel).\r\n$changelogUrl";
    }

    :if ($scriptMode = "osupdate") do={
      :set isOsNeedsToBeUpdated true;
      :if ($installOnlyPatchUpdates = true) do={
        :if ([$getMajorMinor ver=$deviceOsVerInst] = [$getMajorMinor ver=$deviceOsVerAvail]) do={
          :log info "$logPrefix New patch release is available within the current major.minor train.";
        } else={
          :log info "$logPrefix New minor or major RouterOS release (v$deviceOsVerAvail) requires manual upgrade.";
          :set mailSubject "$mailSubject RouterOS v$deviceOsVerAvail requires manual upgrade.";
          :set mailBody "A new minor or major RouterOS version is available: v$deviceOsVerAvail ($updateChannel).\r\nAutomatic installation is limited to patch releases, so please install this update manually.\r\n$changelogUrl";
          :set isOsNeedsToBeUpdated false;
        }
      }

      :if ($isOsNeedsToBeUpdated = true) do={
        :log info "$logPrefix Preparing to upgrade RouterOS from v$deviceOsVerInst to v$deviceOsVerAvail.";
        :set mailSubject "$mailSubject Upgrading RouterOS v$deviceOsVerInst -> v$deviceOsVerAvail.";
        :set mailBody "Your MikroTik router will be upgraded from RouterOS v$deviceOsVerInst to v$deviceOsVerAvail (channel: $updateChannel).\r\nA final report will be sent after the upgrade completes.";
      }
    }
  }

  :if ($forceBackup = true or $scriptMode = "backup" or $isOsNeedsToBeUpdated = true) do={
    :log info "$logPrefix Creating system backups.";
    :if ($isOsNeedsToBeUpdated = true) do={
      :set backupNameFinal $backupNameBeforeUpd;
    }
    :if ($scriptMode != "backup") do={
      :set mailBody ($mailBody . "\r\n\r\n");
    }
    :set mailSubject "$mailSubject Backup created.";
    :set mailBody ($mailBody . "System backups were created.");
    :set mailAttachments [$createBackups backupName=$backupNameFinal backupPassword=$backupPassword includeSensitiveData=$includeSensitiveData minFreeSpaceBytes=$minFreeSpaceBytes preserveBeforeBackup=false];
  } else={
    :log info "$logPrefix No backup is needed on this run.";
  }

  :set mailBody ($mailBody . $mailBodyDeviceInfo . $mailBodyFooter);
}

## STEP TWO: After the OS upgrade reboot, upgrade RouterBOOT firmware if a newer version is bundled.
:if ($updateStep = 2) do={
  :log info "$logPrefix Running step 2 (RouterBOOT check).";
  :if ($isRouterBoard = true and $deviceCurrentFw != $deviceUpgradeFw) do={
    :set isSendEmailRequired false;
    :delay 10s;
    :log info "$logPrefix Upgrading RouterBOOT firmware from v$deviceCurrentFw to v$deviceUpgradeFw.";
    /system routerboard upgrade;
    :delay 5s;
    :log info "$logPrefix RouterBOOT firmware upgraded; scheduling final report and rebooting.";
    :do { /system scheduler remove [find where name="BKPUPD-FINAL-REPORT-ON-NEXT-BOOT"]; } on-error={}
    /system scheduler add name="BKPUPD-FINAL-REPORT-ON-NEXT-BOOT" start-time=startup interval=0s policy=ftp,reboot,read,write,policy,test,sensitive on-event=":delay 5s; /system scheduler remove [find where name=\"BKPUPD-FINAL-REPORT-ON-NEXT-BOOT\"]; :global buGlobalVarUpdateStep 3; :delay 10s; /system script run BackupAndUpdate;";
    /system reboot;
  } else={
    :log info "$logPrefix RouterBOOT firmware is already up to date (or not applicable); proceeding to step 3.";
    :set updateStep 3;
  }
}

## STEP THREE: Create post-upgrade backups and prepare the final completion report.
:if ($updateStep = 3) do={
  :log info "$logPrefix Running step 3 (post-upgrade report).";
  :log info "$logPrefix Upgrade complete. RouterOS: v$deviceOsVerInst, RouterBOOT firmware: v$deviceCurrentFw.";
  :log info "$logPrefix Waiting 1 minute before creating post-upgrade backups and sending final report.";
  :delay 1m;
  :set mailSubject "$mailSubject RouterOS upgrade complete (v$deviceOsVerInst).";
  :set mailBody "RouterOS and RouterBOOT upgrades are complete.\r\nRouterOS version: v$deviceOsVerInst\r\nRouterBOOT firmware: v$deviceCurrentFw\r\n$changelogUrl\r\n\r\nPost-upgrade backups have been created.$mailBodyDeviceInfo$mailBodyFooter";
  :set mailAttachments [$createBackups backupName=$backupNameAfterUpd backupPassword=$backupPassword includeSensitiveData=$includeSensitiveData minFreeSpaceBytes=$minFreeSpaceBytes preserveBeforeBackup=true];
}

## Send email notification (when enabled and required) and optionally clean up local backup files.
:if ($isSendEmailRequired = true and $sendEmail = true) do={
  :local emailSentOk false;
  :log info "$logPrefix Sending email notification...";
  :do {
    /tool e-mail send to=$emailAddress subject=$mailSubject body=$mailBody file=$mailAttachments;
    :set emailSentOk true;
  } on-error={
    :delay 5s;
    :log error "$logPrefix Failed to send email; retrying in 5 minutes.";
    :delay 5m;
    :do {
      /tool e-mail send to=$emailAddress subject=$mailSubject body=$mailBody file=$mailAttachments;
      :set emailSentOk true;
    } on-error={
      :delay 5s;
      :log error "$logPrefix Failed to send email on the second attempt.";
      :if ($isOsNeedsToBeUpdated = true) do={
        :set isOsNeedsToBeUpdated false;
        :log warning "$logPrefix Aborting RouterOS upgrade because pre-upgrade backups could not be emailed.";
      }
    }
  }

  :delay 30s;

  :if ($keepLocalBackups = false and [:len $mailAttachments] > 0 and $emailSentOk = true) do={
    :log info "$logPrefix Removing local backup files after successful email delivery.";
    /file remove $mailAttachments;
    :delay 2s;
  }
}

## Trigger RouterOS package download/install and schedule Step 2 for next boot.
:if ($isOsNeedsToBeUpdated = true) do={
  :do { /system scheduler remove [find where name="BKPUPD-UPGRADE-ON-NEXT-BOOT"]; } on-error={}
  /system scheduler add name="BKPUPD-UPGRADE-ON-NEXT-BOOT" start-time=startup interval=0s policy=ftp,reboot,read,write,policy,test,sensitive on-event=":delay 5s; /system scheduler remove [find where name=\"BKPUPD-UPGRADE-ON-NEXT-BOOT\"]; :global buGlobalVarUpdateStep 2; :delay 10s; /system script run BackupAndUpdate;";
  :log info "$logPrefix Installing new RouterOS packages; router will reboot automatically.";
  /system package update install;
}

:log info "$logPrefix Script \"MikroTik RouterOS Automatic Backup & Update\" finished.";
