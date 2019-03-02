## Set variables.
# Notification e-mail (ensure e-mail sending is already configured).
:local email "you@example.com"
# Update channel: < long-term | stable | development | testing >.
:local updChannel "stable"

## Delay for on-boot run to ensure Internet connectivity is available.
:log info ("On-boot delay started")
:delay 15s;

## Main routine.
# Check for update
:log info ("Starting system package update.")
:do {
  /system package update;
    set channel=$updChannel;
    check-for-updates;
} on-error={ :log info ("System package update failed.") };

# Wait for slow connections.
:log info ("Slow connection delay started")
:delay 15s;

# Check if upgrade is required.
# Important note: "installed-version" was "current-version" on older software.
/system package update
:if ( [get installed-version] != [get latest-version] ) do={
  # Remove backups if free disk space is less than 2 MiB.
  :if ( [/system resource get free-hdd-space] < 2097152) do={
    /file remove [/file find name~".backup"] }
  # Backup config.
  :do { /system backup save } on-error={ :log info ("Backup failed.") }
  # New version available.
  :do {
    /tool e-mail send to="$email" \
      subject="Upgrading software on $[/system identity get name]" \
      body="Upgrading software on router $[/system identity get name] from \
        $[/system package update get installed-version] to \
        $[/system package update get latest-version] \
        (channel:$[/system package update get channel])."
  } on-error={ :log info ("Sending e-mail failed.") }
  :log info ("Upgrading router $[/system identity get name] from \
    $[/system package update get installed-version] to \
    $[/system package update get latest-version] \
      (channel:$[/system package update get channel])")
  # Wait for mail to send.
   :delay 15s;
  # Download the latest software.
  /system package update
   :do { download } on-error={ :log info ("Software download failed.") }
  # Wait for download to complete and for other routers on the network.
   :delay 180s;
  /system reboot

} else={
  # No new version; check for updated firmware.
    :log info ("No software upgrade found; checking for firmware upgrade")
  /system routerboard
  :if ( [get current-firmware] != [get upgrade-firmware] ) do={
     # New firmware available.
     :do { /tool e-mail send to="$email" \
       subject="Upgrading firmware on $[/system identity get name]" \
       body="Upgrading firmware on $[/system identity get name] \
         from $[/system routerboard get current-firmware] to \
         $[/system routerboard get upgrade-firmware]."
     } on-error={ :log info ("Sending e-mail failed.") }
     :log info ("Upgrading firmware on $[/system identity get name] from \
       $[/system routerboard get current-firmware] to \
       $[/system routerboard get upgrade-firmware]")
     # Wait for mail to send.
      :delay 15s;
     upgrade
     # Wait for upgrade; reboot.
      :delay 180s;
     /system reboot
  } else={
  :log info ("No new firmware found")
  }
}
