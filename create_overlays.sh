#! /bin/bash

set -euo pipefail

MACHINE_CONFIG="
cutman      3   00:00:00:00:00:00
gutsman     4   00:00:00:00:00:00
iceman      5   00:00:00:00:00:00
bombman     6   00:00:00:00:00:00
fireman     7   00:00:00:00:00:00
elecman     8   00:00:00:00:00:00
metalman    9   00:00:00:00:00:00
airman     10   00:00:00:00:00:00
bubbleman  11   00:00:00:00:00:00
quickman   12   00:00:00:00:00:00
crashman   13   00:00:00:00:00:00
flashman   14   00:00:00:00:00:00"

DOMAIN=kentonshouse.com
VGROUP=bigdisks
BASE_IMAGE=gamestation-win7
EXPORT_DEVS=/dev/gamestations
OVERLAY_DEVICE=/dev/sdb
CACHE_LOOP_DEVICE=/dev/loop7
# Use /dev/loop7 to avoid interfering with any loop devices LVM may have auto-created.
LOCAL_MOUNT_POINT=/mnt/gamestation
LOCAL_MOUNT_OPTIONS=offset=1048576
NETWORK_INTERFACE=eno1
SHUTDOWN_COMMAND="shutdown /p /f"
SHUTDOWN_USERNAME="LAN Party Guest"

# Parse machine configuration
declare -a HOSTNAMES           # Array of hostnames, in order of declaration.
declare -A HOST_TO_NUMBER      # Maps hostnames to ID numbers.
declare -A HOST_TO_MACADDR     # Maps hostnames to MAC addresses.

while read HOSTNAME NUMBER MACADDR JUNK; do
  if [ "$HOSTNAME" != "" ]; then
    HOSTNAMES+=("$HOSTNAME")
    HOST_TO_NUMBER[$HOSTNAME]=$NUMBER
    HOST_TO_MACADDR[$HOSTNAME]=$MACADDR
  fi
done <<< "$MACHINE_CONFIG"

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

validate-hostnames() {
  for MACHINE in "$@"; do
    if [ "${HOST_TO_NUMBER[$MACHINE]:-none}" == "none" ]; then
      echo "ERROR: No such host configured: $MACHINE" >&2
      exit 1
    fi
    if [ "$MACHINE" == "updates" ]; then
      echo "ERROR: You cannot name a machine 'updates'." >&2
      exit 1
    fi
  done
}

compute-extents() {
  # Compute how many extents to assign to each machine, if there are $1 machines.

  if [ "$OVERLAY_DEVICE" != "" ]; then
    FREE_EXTENTS=$(pvdisplay $OVERLAY_DEVICE -c | cut -d: -f10)
  else
    FREE_EXTENTS=$(vgdisplay $VGROUP -c | cut -d: -f16)
  fi
  MACHINE_COUNT=${1:-1}

  echo "$(( FREE_EXTENTS / MACHINE_COUNT ))"
}

NEEDS_QUOTING_PATTERN='[$&|"\#!<>;()*?~`'"'"']'

echo-command() {
  # Echo a shell command to standard output, making sure to quote it appropriately so that it can
  # be copied and pasted.

  local -a EXPANSION
  local -a OUTPUT
  for ARG in "$@"; do
    EXPANSION=( $ARG )
    if [ "${EXPANSION[0]}" != "$ARG" ] ||
       [[ "$ARG" =~ $NEEDS_QUOTING_PATTERN ]]; then
      # Hack: Don't escape trailing &, we probably intended to print it like that.
      if [ "$ARG" != "&" ]; then
        ARG="'$(sed -e "s/'/'\"'\"'/g" <<< "$ARG")'"
      fi
    fi
    OUTPUT+=( "$ARG" )
  done

  if [ $DRY_RUN == no ]; then
    # Make it bold.
    echo -ne '\033[1m'
    echo -n "${OUTPUT[*]}"
    echo -e '\033[0m'
  else
    echo "${OUTPUT[*]}"
  fi
}

doit() {
  echo-command "$@"
  if [ $DRY_RUN == no ]; then
    "$@"
  fi
}

unmount-master-locally() {
  # If the master image is mounted locally, unmount it. This is invoked before making any change
  # that can't be done while the local mount is up, such as merging updates or switching between
  # cached and uncached modes.
  if is-local-mount-point-configured; then
    if is-master-mounted-locally; then
      doit umount "$LOCAL_MOUNT_POINT"
    fi
  fi
}

mount-master-locally() {
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

stop-iscsi() {
  bold "================ stop iscsi ================"

  # If tgtd is running, remove the specific targets.
  if pidof tgtd > /dev/null; then
    NEED_SLEEP=no
    for MACHINE in "$@"; do
      TID=${HOST_TO_NUMBER[$MACHINE]}
      if tgtadm -C 0 --lld iscsi --op show --mode target --tid $TID > /dev/null 2>&1; then
        doit tgtadm -C 0 --lld iscsi --op delete --force --mode target --tid $TID
        NEED_SLEEP=yes
      fi
    done

    if [ $NEED_SLEEP == yes ]; then
      # Give tgtd time to close resources.
      doit sleep 1
    fi
  fi
}

delete-overlays() {
  bold "================ delete overlays ================"
  # Destroy all listed hosts that are currently up. (We do this for "init" as well because "init"
  # will replace them with fresh versions, and for "start-updates" we always destroy all machines
  # first.)
  for MACHINE in "$@"; do
    if [ -e $EXPORT_DEVS/$MACHINE ]; then
      doit rm $EXPORT_DEVS/$MACHINE
    fi
    if [ -e /dev/mapper/cached-$MACHINE ]; then
      doit dmsetup remove /dev/mapper/cached-$MACHINE
    fi
    if [ -e /dev/$VGROUP/$MACHINE-cow ]; then
      doit lvremove -f /dev/$VGROUP/$MACHINE-cow
    fi
  done

  # Also delete the updates image, if present.
  if [ -e /dev/$VGROUP/updates ]; then
    doit lvremove -f /dev/$VGROUP/updates
  fi
}

create-overlays() {
  bold "================ create overlays ================"

  MASTER_SIZE=$(blockdev --getsz /dev/$VGROUP/$BASE_IMAGE)
  EXTENTS=$(compute-extents $#)

  # Create the loopback layer -- for page caching -- over the master image, if it doesn't exist
  # already.
  if ! is-caching-enabled; then
    unmount-master-locally
    doit losetup-new --direct-io=off --read-only $CACHE_LOOP_DEVICE /dev/$VGROUP/$BASE_IMAGE
    mount-master-locally
  elif is-local-mount-point-configured && ! is-master-mounted-locally; then
    mount-master-locally
  fi

  if [ ! -e $EXPORT_DEVS ]; then
    doit mkdir -p $EXPORT_DEVS
  fi

  for MACHINE in "$@"; do
    # Create a regular volume with LVM.
    doit lvcreate -n "$MACHINE-cow" -l $EXTENTS $VGROUP $OVERLAY_DEVICE

    # Use it as a raw devicemapper COW device.
    doit dmsetup create cached-$MACHINE --table "0 $MASTER_SIZE snapshot $CACHE_LOOP_DEVICE /dev/$VGROUP/$MACHINE-cow N 128"

    doit ln -s /dev/mapper/cached-$MACHINE $EXPORT_DEVS/$MACHINE
  done
}

merge-updates() {
  bold "================ merge overlay ================"

  for MACHINE in "$@"; do
    if [ -e $EXPORT_DEVS/$MACHINE ]; then
      doit rm $EXPORT_DEVS/$MACHINE
    fi
  done

  unmount-master-locally
  doit lvconvert --merge /dev/$VGROUP/updates
  mount-master-locally
}

start-updates() {
  bold "================ create overlay ================"

  EXTENTS=$(compute-extents 1)

  # Remove the loopback layer, if it currently exists.
  if is-caching-enabled; then
    unmount-master-locally
    doit losetup -d $CACHE_LOOP_DEVICE
    mount-master-locally
  fi

  if [ ! -e $EXPORT_DEVS ]; then
    doit mkdir -p $EXPORT_DEVS
  fi

  # Creating the updates machine. Use a regular LVM snapshot so that we can easily merge it back
  # later.
  doit lvcreate -c 64k -n updates -l $EXTENTS -s /dev/$VGROUP/$BASE_IMAGE $OVERLAY_DEVICE
  doit ln -s /dev/$VGROUP/updates $EXPORT_DEVS/$UPDATE_MACHINE
}

start-iscsi() {
  bold "================ start iscsi ================"

  # Start tgtd if not running.
  if ! pidof tgtd > /dev/null; then
    doit tgtd

    doit tgtadm --op update --mode sys --name State -v offline

    doit tgtadm --lld iscsi --op delete --mode portal --param portal=0.0.0.0:3260
    doit tgtadm --lld iscsi --op delete --mode portal --param portal=[::]:3260
    doit tgtadm --lld iscsi --op new --mode portal --param portal=10.0.1.0:3260

    doit tgtadm --op update --mode sys --name State -v ready
  fi

  for MACHINE in "$@"; do
    TID=${HOST_TO_NUMBER[$MACHINE]}
    doit tgtadm -C 0 --lld iscsi --op new --mode target --tid $TID -T iqn.2001-04.com.kentonshouse.protoman:$MACHINE
    doit tgtadm -C 0 --lld iscsi --op new --mode logicalunit --tid $TID --lun 1 -b $EXPORT_DEVS/$MACHINE
    doit tgtadm -C 0 --lld iscsi --op bind --mode target --tid $TID -I ALL
  done
}

boot-hosts() {
  bold "================ boot hosts ================"

  for MACHINE in "$@"; do
    doit etherwake -i $NETWORK_INTERFACE ${HOST_TO_MACADDR[$MACHINE]}
  done
}

shutdown-hosts() {
  bold "================ shutdown hosts ================"

  for MACHINE in "$@"; do
    # We inline doit() here so that we can let the SSH commands run in the background with &.
    # This is important because if a machine is already shut down, `ssh` will hang for a while
    # before failing. We disable "StrictHostKeyChecking" because it won't work when ssh is running
    # in the background.
    #
    # While we're at it, we take the opportunity to properly quote the arguments in the console
    # output.
    COMMAND=( ssh -o "StrictHostKeyChecking no" "$SHUTDOWN_USERNAME@$MACHINE.kentonshouse.com" -- 'shutdown /p /f' )
    echo-command "${COMMAND[@]}" "&"
    if [ $DRY_RUN == no ]; then
      "${COMMAND[@]}" &
    fi
  done

  if [ $DRY_RUN == no ]; then
    bold wait
    wait
  else
    echo wait
  fi
}

# ========================================================================================

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

case "$COMMAND" in
  init )
    if is-updating; then
      echo "ERROR: You must either merge or destroy updates first." >&2
      exit 1
    fi
    if [ "$#" -gt 0 ]; then
      validate-hostnames "$@"
      HOSTNAMES=("$@")
    fi

    stop-iscsi "${HOSTNAMES[@]}"
    delete-overlays "${HOSTNAMES[@]}"
    create-overlays "${HOSTNAMES[@]}"
    start-iscsi "${HOSTNAMES[@]}"
    ;;

  destroy )
    if is-updating; then
      yesno "There are unmerged updates. Really destroy them?" || exit 1
    fi
    if [ "$#" -gt 0 ]; then
      validate-hostnames "$@"
      HOSTNAMES=("$@")
    fi

    stop-iscsi "${HOSTNAMES[@]}"
    delete-overlays "${HOSTNAMES[@]}"
    ;;

  boot )
    if [ "$#" -gt 0 ]; then
      validate-hostnames "$@"
      HOSTNAMES=("$@")
    fi

    boot-hosts "${HOSTNAMES[@]}"
    ;;

  shutdown )
    if [ "$#" -gt 0 ]; then
      validate-hostnames "$@"
      HOSTNAMES=("$@")
    fi

    shutdown-hosts "${HOSTNAMES[@]}"
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
    if [ "${HOST_TO_NUMBER[$UPDATE_MACHINE]:-none}" == "none" ]; then
      echo "ERROR: No such host configured: $UPDATE_MACHINE" >&2
      exit 1
    fi

    stop-iscsi "${HOSTNAMES[@]}"
    delete-overlays "${HOSTNAMES[@]}"
    start-updates
    start-iscsi "$UPDATE_MACHINE"
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

    stop-iscsi "${HOSTNAMES[@]}"
    merge-updates
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
    echo "ERROR: Unknown command: $1" >&2
    usage >&2
    exit 1
    ;;
esac
