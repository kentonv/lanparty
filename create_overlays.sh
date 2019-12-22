#! /bin/bash

set -euo pipefail

MACHINES="cutman gutsman iceman bombman fireman elecman metalman airman bubbleman quickman crashman flashman"
VGROUP=bigdisks
BASE_IMAGE=gamestation-win7
EXPORT_DEVS=/dev/gamestations
OVERLAY_DEVICE=/dev/sdb
CACHE_LOOP_DEVICE=/dev/loop7
# Use /dev/loop7 to avoid interfering with any loop devices LVM may have auto-created.
LOCAL_MOUNT_POINT=/mnt/gamestation
LOCAL_MOUNT_OPTIONS=offset=1048576

# TODO:
# - Revamp CLI
# - Allow dynamic specification of update machine

COMMAND_NAME=$(basename $0)

bold() {
  echo -ne '\033[1m'
  echo -n "$@"
  echo -e '\033[0m'
}

usage() {
  bold 'Usage:'
  echo "  $COMMAND_NAME [-n] COMMAND"
  echo
  echo 'If -n is specified, no actions will be taken; the script will only print out'
  echo 'the commands it would normally execute.'
  echo
  echo 'COMMAND may be:'
  bold '  init [HOSTS...]'
  echo '    Initialize the given hosts (default: all hosts), splitting all unallocated'
  echo '    disk space in the volume group evenly among their copy-on-write overlays.'
  echo '    If any specified hosts are already initialized, they are destroyed first.'
  echo
  bold '  destroy [HOSTS...]'
  echo '    Wipe all machines and discard any unmerged updates. If HOSTS is specified,'
  echo '    only destroy those specific hosts.'
  echo
  bold '  boot [HOSTS...]'
  echo '    Sends ethernet wake-on-LAN magic packet to the given hosts (default: all'
  echo '    hosts), hopefully causing them to power up.'
  echo
  bold '  shutdown [HOSTS...]'
  echo '    Shuts down the given hosts (default: all running hosts) by connecting to'
  echo '    each via SSH and issuing the configured shutdown command.'
  echo
  bold '  start-updates HOST'
  echo '    Initialize the given host for installing updates, using all unallocated'
  echo '    disk space in the volume group for a copy-on-write overlay. Once the'
  echo '    machine is updated and powered down, use "merge" to merge changes back'
  echo '    into the master image, or "destroy" to discard all changes.'
  echo
  bold '  merge'
  echo '    Merges updates (started with start-updates) into the master image.'
  echo
  bold '  status'
  echo '    Shows the current state of all machines'
  echo
  bold '  configure [dhcp|dns]'
  echo '    Generates configuration snippets, written to standard output. The argument'
  echo '    specifies what to configure:'
  bold '      (no argument)'
  echo '        Generates a template config file for this script itself. This should'
  echo '        typically be saved to /etc/lanparty.conf and then edited to enter your'
  echo '        specific configuration.'
  bold '      dhcp'
  echo '        Generates configuration for ISC DHCP server, derived from'
  echo '        lanparty.conf. Typically you would add this to:'
  echo '          /etc/dhcp/dhcp.conf'
  bold '      dns'
  echo '        Generates configuration for BIND 9 DNS server, derived from'
  echo '        lanparty.conf. Typically you would add this to:'
  echo '          /etc/bind/zones/YOUR-DOMAIN.db'
}

DRY_RUN=no
if [ "${1:-}" == "-n" ]; then
  DRY_RUN=yes
  shift
fi

if [ $# -eq 0 ]; then
  echo "ERROR: missing command" >&2
  usage >&2
  exit 1
fi

COMMAND=$1
shift

yesno() {
  echo -n "$@ (y/n) " >&2

  while read ANSWER; do
    case $ANSWER in
      y | Y | yes | Yes | YES )
        return 0
        ;;
      n | N | no | No | NO )
        return 1
        ;;
      * )
        # try again
        echo -n "$@ (y/n) " >&2
        ;;
    esac
  done

  # EOF?
  echo "ERROR: Can't continue without user input."
  exit 1
}

is-updating() {
  # Check if we're currently in update mode.
  test -e "/dev/$VGROUP/updates"
}

is-local-mount-point-configured() {
  # Check if we're configured to mount the master image read-only at a local mount point.
  test "$LOCAL_MOUNT_POINT" != ""
}

is-master-mounted-locally() {
  # Check if the master image is currently mounted locally at the configured local mount point.
  findmnt "$LOCAL_MOUNT_POINT" > /dev/null
}

is-caching-enabled() {
  # Check if the page caching layer is currently configured.
  losetup "$CACHE_LOOP_DEVICE" > /dev/null 2>&1
}

case "$COMMAND" in
  init )
    if is-updating; then
      echo "ERROR: You must either merge or destroy updates first." >&2
      exit 1
    fi
    if [ "$#" -gt 0 ]; then
      MACHINES="$*"
    fi
    ;;
  destroy )
    if is-updating; then
      yesno "There are unmerged updates. Really destroy them?" || exit 1
    fi
    if [ "$#" -gt 0 ]; then
      MACHINES="$*"
    fi
    ;;
  boot )
    if [ "$#" -gt 0 ]; then
      MACHINES="$*"
    fi
    echo 'ERROR: not yet implemented' >&2
    exit 1
    ;;
  shutdown )
    if [ "$#" -gt 0 ]; then
      MACHINES="$*"
    fi
    echo 'ERROR: not yet implemented' >&2
    exit 1
    ;;
  start-updates )
    if [ "$#" -ne 1 ]; then
      echo 'ERROR: "start-updates" takes exactly one argument.' >&2
      usage >&2
      exit 1
    fi
    if is-updating; then
      echo "ERROR: Updates are already in progress." >&2
      exit 1
    fi
    UPDATE_MACHINE="$1"
    ;;
  merge )
    if [ "$#" -gt 0 ]; then
      echo 'ERROR: "merge" does not take an argument.' >&2
      usage >&2
      exit 1
    fi
    if ! is-updating; then
      echo 'ERROR: No updates to merge.' >&2
      exit 1
    fi
    ;;
  status )
    if [ "$#" -gt 0 ]; then
      echo 'ERROR: "status" does not take an argument.' >&2
      usage >&2
      exit 1
    fi
    echo 'ERROR: not yet implemented' >&2
    exit 1
    ;;
  configure )
    echo 'ERROR: not yet implemented' >&2
    exit 1
    ;;
  * )
    echo "ERROR: unknown option: $1" >&2
    usage >&2
    exit 1
    ;;
esac

function doit {
  if [ $DRY_RUN == no ]; then
    bold "$@"
    "$@"
  else
    echo "$@"
  fi
}

function unmount-master-locally {
  # If the master image is mounted locally, unmount it. This is invoked before making any change
  # that can't be done while the local mount is up, such as merging updates or switching between
  # cached and uncached modes.
  if is-local-mount-point-configured; then
    if is-master-mounted-locally; then
      doit umount "$LOCAL_MOUNT_POINT"
    fi
  fi
}

function mount-master-locally {
  # If we're configured to mount the master image locally (read-only), mount it.
  if is-local-mount-point-configured; then
    if is-caching-enabled; then
      # Mount from the loop device, because apparently we can't directly mount the base image
      # when a loop device is using it (and anyway sharing the cache is good).
      doit mount -o "ro,$LOCAL_MOUNT_OPTIONS" "$CACHE_LOOP_DEVICE" "$LOCAL_MOUNT_POINT"
    else
      doit mount -o "ro,$LOCAL_MOUNT_OPTIONS" /dev/$VGROUP/$BASE_IMAGE "$LOCAL_MOUNT_POINT"
    fi
  fi
}

if [ $COMMAND == merge -o $COMMAND == destroy ]; then
  bold "================ stop iscsi ================"

  # Shutting down.
  # TODO: Only disable specific machines.
  if pidof tgtd > /dev/null; then
    doit tgtadm --op update --mode sys --name State -v offline
    doit tgt-admin --offline ALL
    doit tgt-admin --update ALL -c /dev/null -f
    doit tgtadm --op delete --mode system
  fi

  doit sleep 2
fi

if [ $COMMAND == init -o $COMMAND == destroy -o $COMMAND == start-updates ]; then
  bold "================ delete overlays ================"
  # Destroy all listed hosts that are currently up. (We do this for "init" as well because "init"
  # will replace them with fresh versions, and for "start-updates" we always destroy all machines
  # first.)
  for MACHINE in $MACHINES; do
    if [ -e /dev/mapper/cached-$MACHINE ]; then
      doit dmsetup remove /dev/mapper/cached-$MACHINE
    fi
    if [ -e /dev/$VGROUP/$MACHINE-cow ]; then
      doit lvremove -f /dev/$VGROUP/$MACHINE-cow
    fi
  done
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
doit mkdir -p $EXPORT_DEVS

if [ $COMMAND == init ]; then
  bold "================ create overlays ================"

  # Create the loopback layer -- for page caching -- over the master image, if it doesn't exist
  # already.
  if ! is-caching-enabled; then
    unmount-master-locally
    doit losetup-new --direct-io=off --read-only $CACHE_LOOP_DEVICE /dev/$VGROUP/$BASE_IMAGE
    mount-master-locally
  elif is-local-mount-point-configured && ! is-master-mounted-locally; then
    mount-master-locally
  fi

  for MACHINE in $MACHINES; do
    # Create a regular volume with LVM.
    doit lvcreate -n $MACHINE-cow -l $EXTENTS $VGROUP $OVERLAY_DEVICE

    # Use it as a raw devicemapper COW device.
    doit dmsetup create cached-$MACHINE --table "0 $MASTER_SIZE snapshot $CACHE_LOOP_DEVICE /dev/$VGROUP/$MACHINE-cow N 128"

    doit ln -s /dev/mapper/cached-$MACHINE $EXPORT_DEVS/$MACHINE
  done
fi

if [ $COMMAND == merge ]; then
  bold "================ merge overlay ================"

  unmount-master-locally
  doit lvconvert --merge /dev/$VGROUP/updates
  mount-master-locally
fi

if [ $COMMAND == destroy ]; then
  # Also delete the updates image, if present.
  if [ -e /dev/$VGROUP/updates ]; then
    doit lvremove -f /dev/$VGROUP/updates
  fi
fi

if [ $COMMAND == start-updates ]; then
  bold "================ create overlay ================"

  # Remove the loopback layer, if it currently exists.
  if is-caching-enabled; then
    unmount-master-locally
    doit losetup -d $CACHE_LOOP_DEVICE
    mount-master-locally
  fi

  # Creating the updates machine. Use a regular LVM snapshot so that we can easily merge it back
  # later.
  doit lvcreate -c 64k -n updates -l $EXTENTS -s /dev/$VGROUP/$BASE_IMAGE $OVERLAY_DEVICE
  doit ln -s /dev/$VGROUP/updates $EXPORT_DEVS/$UPDATE_MACHINE

  # HACK: Set MACHINES so that the update machine will have iSCSI enabled.
  # TODO: Make this cleaner.
  MACHINES=$UPDATE_MACHINE
fi

if [ $COMMAND == init -o $COMMAND == start-updates ]; then
  bold "================ start iscsi ================"

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
