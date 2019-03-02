# Assume script is named 'auto-upgrade'.
# Run on every boot.
/system scheduler
  add name=on-boot-upgrade on-event=auto-upgrade policy=ftp,reboot,read,write,policy,test \
    start-time=startup
