#! /bin/bash

set -euo pipefail

MACHINES="cutman gutsman iceman bombman fireman elecman metalman airman bubbleman quickman crashman flashman"
EXTENTS=39744

DRY_RUN=no
DELETE=no
MERGE=no
ONLYONE=no
ONLYTWO=no
PAGECACHE=yes
BASE_IMAGE=/dev/bigdisks/gamestation-win7

while [ $# -gt 0 ]; do
  case "$1" in
    -n )
      DRY_RUN=yes
      ;;
    -d )
      DELETE=yes
      echo -n "WARNING:  Press any key to DELETE..."
      read
      ;;
    -l )
      BASE_IMAGE=/dev/bigdisks/devstation-ubuntu
      echo "Configuring for Linux..."
      ;;
    --win10 )
      BASE_IMAGE=/dev/bigdisks/gamestation-win10
      echo "Configuring for Windows 10..."
      ;;
    -m )
      MERGE=yes
      echo -n "WARNING:  Press any key to MERGE..."
      read
      ;;
    -1 )
      ONLYONE=yes
      ;;
    -2 )
      ONLYTWO=yes
      ;;
    -c )
      PAGECACHE=yes
      ;;
    * )
      echo "unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

function doit {
  echo "$@"
  if [ $DRY_RUN == no ]; then
    "$@"
  fi
}

if [ $ONLYONE == yes ]; then
  MACHINES=flashman
  EXTENTS=476932
  PAGECACHE=no
elif [ $ONLYTWO == yes ]; then
  MACHINES='crashman flashman'
  EXTENTS=238466
  PAGECACHE=no
fi

if [ $MERGE == yes -o $DELETE == yes ]; then
  # Shutting down.
  if pidof tgtd; then
    doit tgtadm --op update --mode sys --name State -v offline
    doit tgt-admin --offline ALL
    doit tgt-admin --update ALL -c /dev/null -f
    doit tgtadm --op delete --mode system
  fi

#  doit systemctl stop tgt
#  doit service iscsitarget stop
  doit sleep 2
#  doit service iscsitarget stop
#  doit sleep 2
  if (mount | grep -q /mnt/gamestation); then
    doit umount /mnt/gamestation
  fi
  if (mount | grep -q /mnt/devstation); then
    doit umount /mnt/devstation
  fi
else
  # Bringing up.

  # Remove old loopback mapping if it exists.
  if (losetup | grep -q '^/dev/loop7'); then
    doit losetup -d /dev/loop7
  fi

  if [ $PAGECACHE == yes ]; then
    # Setup loopback device on top of master image in order to get caching.
    # Use /dev/loop7 to avoid interfering with any loop devices LVM may have auto-created.
    doit losetup-new --direct-io=off --read-only /dev/loop7 /dev/bigdisks/gamestation-win7
  fi
fi

MASTER_SIZE=$(blockdev --getsz /dev/bigdisks/gamestation-win7)

doit rm -rf /dev/gamestations
doit mkdir -p /dev/gamestations

for MACHINE in $MACHINES; do
  echo "================ $MACHINE ================"

  if [ $MERGE == yes -o $DELETE == yes ]; then
    # When deleting, delete everything.
    # When merging, delete everything except flashman.
    if [ $DELETE == yes -o $MACHINE != flashman ]; then
      if [ -e /dev/mapper/cached-$MACHINE ]; then
        doit dmsetup remove /dev/mapper/cached-$MACHINE
      fi
      if [ -e /dev/bigdisks/$MACHINE-win7 ]; then
        doit lvremove -f /dev/bigdisks/$MACHINE-win7
      fi
      if [ -e /dev/bigdisks/$MACHINE-cow ]; then
        doit lvremove -f /dev/bigdisks/$MACHINE-cow
      fi
    fi
  elif [ $PAGECACHE == yes ]; then
    # Create a regular volume with LVM.
    doit lvcreate -n $MACHINE-cow -l $EXTENTS bigdisks /dev/sdb

    # Use it as a raw devicemapper COW device.
    doit dmsetup create cached-$MACHINE --table "0 $MASTER_SIZE snapshot /dev/loop7 /dev/bigdisks/$MACHINE-cow N 128"

    doit ln -s /dev/mapper/cached-$MACHINE /dev/gamestations/$MACHINE
  else
    doit lvcreate -c 64k -n $MACHINE-win7 -l $EXTENTS -s $BASE_IMAGE /dev/sdb
    doit ln -s /dev/bigdisks/$MACHINE-win7 /dev/gamestations/$MACHINE
  fi
done

if [ $MERGE == yes ]; then
  doit lvconvert --merge /dev/bigdisks/flashman-win7
fi

if [ $MERGE != yes -a $DELETE != yes ]; then
  echo "================ start iscsi ================"

#  doit mount -o ro,offset=1048576 /dev/bigdisks/gamestation-win7 /mnt/gamestation/
#  TODO: What's the right offset? Is there a partition table?
#  doit mount -o ro,offset=1048576 /dev/bigdisks/devstation-win7 /mnt/devstation/
#  doit service iscsitarget start
#  doit systemctl start tgt

  doit tgtd

  doit tgtadm --op update --mode sys --name State -v offline

  doit tgtadm --lld iscsi --op delete --mode portal --param portal=0.0.0.0:3260
  doit tgtadm --lld iscsi --op delete --mode portal --param portal=[::]:3260
  doit tgtadm --lld iscsi --op new --mode portal --param portal=10.0.1.0:3260

  TID=1
  for MACHINE in $MACHINES; do
    doit tgtadm -C 0 --lld iscsi --op new --mode target --tid $TID -T iqn.2001-04.com.kentonshouse.protoman:$MACHINE-win7
    doit tgtadm -C 0 --lld iscsi --op new --mode logicalunit --tid $TID --lun 1 -b /dev/gamestations/$MACHINE
    doit tgtadm -C 0 --lld iscsi --op bind --mode target --tid $TID -I ALL
    TID=$(( TID + 1 ))
  done

  doit tgtadm --op update --mode sys --name State -v ready

fi
