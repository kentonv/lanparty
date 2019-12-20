#! /bin/bash

set -euo pipefail

MACHINES="cutman gutsman iceman bombman fireman elecman metalman airman bubbleman quickman crashman flashman"
VGROUP=bigdisks
BASE_IMAGE=gamestation-win7
EXPORT_DEVS=/dev/gamestations
OVERLAY_DEVICE=/dev/sdb
CACHE_LOOP_DEVICE=/dev/loop7
# Use /dev/loop7 to avoid interfering with any loop devices LVM may have auto-created.
UPDATES_MACHINE=flashman
LOCAL_MOUNT_POINT=/mnt/gamestation

DRY_RUN=no
DELETE=no
MERGE=no
ONLYONE=no

# TODO:
# - Revamp CLI
# - Allow dynamic specification of update machine

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
    -m )
      MERGE=yes
      echo -n "WARNING:  Press any key to MERGE..."
      read
      ;;
    -1 )
      ONLYONE=yes
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
  MACHINES=$UPDATES_MACHINE
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
  if (mount | grep -q $LOCAL_MOUNT_POINT); then
    doit umount $LOCAL_MOUNT_POINT
  fi
else
  # Bringing up.

  # Remove old loopback mapping if it exists.
  if (losetup | grep -q "^$CACHE_LOOP_DEVICE"); then
    doit losetup -d $CACHE_LOOP_DEVICE
  fi

  if [ $ONLYONE != yes ]; then
    # Setup loopback device on top of master image in order to get caching.
    doit losetup-new --direct-io=off --read-only $CACHE_LOOP_DEVICE /dev/$VGROUP/$BASE_IMAGE
  fi
fi

MASTER_SIZE=$(blockdev --getsz /dev/$VGROUP/$BASE_IMAGE)

if [ "$OVERLAY_DEVICE" != "" ]; then
  FREE_EXTENTS=$(pvdisplay $OVERLAY_DEVICE -c | cut -d: -f10)
else
  FREE_EXTENTS=$(vgdisplay $VGROUP -c | cut -d: -f16)
fi
MACHINE_COUNT=$(echo "$MACHINES" | wc -w)
EXTENTS=$(( FREE_EXTENTS / MACHINE_COUNT ))

doit rm -rf $EXPORT_DEVS
doit mkdir -p $EXPORT_DEVS/internal

for MACHINE in $MACHINES; do
  echo "================ $MACHINE ================"

  if [ $MERGE == yes -o $DELETE == yes ]; then
    # When deleting, delete everything.
    # When merging, delete everything except $UPDATES_MACHINE.
    if [ $DELETE == yes -o $MACHINE != $UPDATES_MACHINE ]; then
      if [ -e $EXPORT_DEVS/internal/cached-$MACHINE ]; then
        doit dmsetup remove $EXPORT_DEVS/internal/cached-$MACHINE
      fi
      if [ -e /dev/$VGROUP/$MACHINE ]; then
        doit lvremove -f /dev/$VGROUP/$MACHINE
      fi
      if [ -e /dev/$VGROUP/$MACHINE-cow ]; then
        doit lvremove -f /dev/$VGROUP/$MACHINE-cow
      fi
    fi
  elif [ $ONLYONE != yes ]; then
    # Create a regular volume with LVM.
    doit lvcreate -n $MACHINE-cow -l $EXTENTS $VGROUP $OVERLAY_DEVICE

    # Use it as a raw devicemapper COW device.
    doit dmsetup create cached-$MACHINE --table "0 $MASTER_SIZE snapshot $CACHE_LOOP_DEVICE /dev/$VGROUP/$MACHINE-cow N 128"

    doit ln -s $EXPORT_DEVS/internal/cached-$MACHINE $EXPORT_DEVS/$MACHINE
  else
    # Creating the updates machine. Use a regular LVM snapshot so that we can easily merge it back
    # later.
    doit lvcreate -c 64k -n $MACHINE -l $EXTENTS -s /dev/$VGROUP/$BASE_IMAGE $OVERLAY_DEVICE
    doit ln -s /dev/$VGROUP/$MACHINE $EXPORT_DEVS/$MACHINE
  fi
done

if [ $MERGE == yes ]; then
  doit lvconvert --merge /dev/$VGROUP/$UPDATES_MACHINE
fi

if [ $MERGE != yes -a $DELETE != yes ]; then
  echo "================ start iscsi ================"

#  doit mount -o ro,offset=1048576 /dev/$VGROUP/$BASE_IMAGE $LOCAL_MOUNT_POINT/

  doit tgtd

  doit tgtadm --op update --mode sys --name State -v offline

  doit tgtadm --lld iscsi --op delete --mode portal --param portal=0.0.0.0:3260
  doit tgtadm --lld iscsi --op delete --mode portal --param portal=[::]:3260
  doit tgtadm --lld iscsi --op new --mode portal --param portal=10.0.1.0:3260

  TID=1
  for MACHINE in $MACHINES; do
    doit tgtadm -C 0 --lld iscsi --op new --mode target --tid $TID -T iqn.2001-04.com.kentonshouse.protoman:$MACHINE
    doit tgtadm -C 0 --lld iscsi --op new --mode logicalunit --tid $TID --lun 1 -b $EXPORT_DEVS/$MACHINE
    doit tgtadm -C 0 --lld iscsi --op bind --mode target --tid $TID -I ALL
    TID=$(( TID + 1 ))
  done

  doit tgtadm --op update --mode sys --name State -v ready

fi
