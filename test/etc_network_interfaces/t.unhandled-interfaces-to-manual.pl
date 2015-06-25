r('', <<'/proc/net/dev'
Inter-|   Receive                                                |  Transmit
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
These eth interfaces show up:
  eth0:
eth1:
       eth2:
  eth3:
    lo:
All other stuff is being ignored eth99:
eth100 is not actually available:
 ethBAD: this one's now allowed either
/proc/net/dev
);

expect load('base') . <<'IFACES';
iface eth1 inet manual

iface eth2 inet manual

iface eth3 inet manual

IFACES

1;
