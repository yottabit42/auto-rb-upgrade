# Assume script is named 'auto-upgrade'.
# Run every day at 02:00:00.
/system scheduler
  add interval=1d name=interval-upgrade on-event=auto-upgrade policy=\
    ftp,reboot,read,write,policy,test start-date=oct/18/2018 start-time=02:00:00
