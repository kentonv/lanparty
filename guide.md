# Kenton's LAN Party Setup Guide

<!-- TOC -->

- [Introduction](#introduction)
- [How it works](#how-it-works)
  - [Snapshots](#snapshots)
  - [Other Miscellaneous details](#other-miscellaneous-details)
- [Prerequisites](#prerequisites)
- [Setting up the server](#setting-up-the-server)
  - [Basic Linux setup](#basic-linux-setup)
  - [Network interface renaming](#network-interface-renaming)
  - [Router (optional)](#router-optional)
  - [The `lanparty` script](#the-lanparty-script)
  - [Wake-on-LAN](#wake-on-lan)
  - [iSCSI server](#iscsi-server)
  - [DHCP server](#dhcp-server)
  - [tftp and iPXE](#tftp-and-ipxe)
  - [DNS server (optional)](#dns-server-optional)
  - [Samba (optional)](#samba-optional)
- [Installing Windows 10](#installing-windows-10)
  - [Download Windows Installer ISO](#download-windows-installer-iso)
  - [Enter "updates" mode](#enter-updates-mode)
  - [Boot the machine into the Windows installer](#boot-the-machine-into-the-windows-installer)
  - [Install Windows 10](#install-windows-10)
  - [Work around `PAGE_FAULT_IN_NONPAGED_AREA`](#work-around-page_fault_in_nonpaged_area)
  - [Avoiding Microsoft Sign-in](#avoiding-microsoft-sign-in)
  - [Set Up Windows 10](#set-up-windows-10)
  - [Set up SSH](#set-up-ssh)
  - [Merge changes](#merge-changes)
- [LAN party operations](#lan-party-operations)
  - [Installing updates before a party.](#installing-updates-before-a-party)
  - [Starting the party](#starting-the-party)
  - [Checking on status](#checking-on-status)
  - [Ending the party](#ending-the-party)
- [Tips and Tricks](#tips-and-tricks)
  - [Dead overlays](#dead-overlays)
  - [Steam Update Schedule](#steam-update-schedule)
  - [Background defrag](#background-defrag)
  - [Monitoring network usage](#monitoring-network-usage)
  - [Canceled merge](#canceled-merge)
  - [Mismatching hardware](#mismatching-hardware)

<!-- /TOC -->

## Introduction

See [the readme](README.md) for background.

This guide will help you set up and maintain a fleet of identical machines intended for use by random guests, such as at a LAN party -- or, an internet cafe, an office, a computer lab, etc.

Compared to the naive approach of maintaining each machine separately, the approach in this guide has two advantages:

* Any updates need only be installed once, and are instantly cloned to all machines.
* Users can freely make changes to their machine, and those changes can be trivially wiped clean after they leave.

Commercial solutions exist, but this solution is entirely open source.

## How it works

### Snapshots

We configure each individual gamestation to netboot from a server machine. The gamestations do not need their own disks at all; the server manages all storage.

On the server, we maintain a single master image, along with copy-on-write overlays for each game machine. The overlays track changes that each machine has made by writing to its main disk. Any parts of the disk that haven't been changed need not be copied; they are read directly from the master image on-demand. Thus, the overlays can be much smaller than the master image, and can be initialized and deleted instantaneously. Deleting an overlay effectively wipes away any changes a guest has made to their machine.

Overlays are implemented as LVM "snapshots". However, the word "snapshot" is misleading in this use case. Normally, snapshots are used essentially for backups: You take a "snapshot" of your main volume, and then you go on modifying the original volume. The snapshot remembers the *old* state of the disks, and is not meant to be modified. But, a little-known feature of LVM snapshots is that they go both ways. A "snapshot" is actually a *fork* of the volume, and can itself be modified. If you mount and modify the snapshot, then it stores the new data as a diff against the original volume.

In our case, we will *only* modify the snapshots, leaving the original volume unchanged. The original volume is our master image, and we create a "snapshot" for each machine. Thus all the machines' volumes are "forked" from the master image, and can be independently modified, without having to store multiple copies of the master. Because our use of snapshots doesn't really matche the word "snapshot", I will usually use the term "copy-on-write overlay" (or just "overlay") instead.

### Other Miscellaneous details

* **Upgrade mode:** To help manage updates, we take advantage of another feature of snapshots: an any time, the changes represented by a snapshot can be merged back into the original volume. When installing updates, we'll create one big overlay, boot one machine from that overlay, and use it to install updates. When done, we shut down the machine, and then merge the snapshot back into the master image. This has the advantage that if something goes wrong while installing updates, you can throw them away and start over.

* **Shared cache:** Normally, Linux's page caching operates at the filesystem layer, not the block device layer. Since we're directly exporting block devices to the clients, in the obvious setup, there's no opportunity for clients to share a cache. This means that when everyone at a LAN party opens the same game at the same time, the server would end up reading the game all the way from disk for every client! To solve this, we use a hack that causes block device reads to pass through the filesystem layer: We create a loopback device, whose source "file" is actually the master image's block device. (Normally, a "loopback device" is a block device that is backed by a normal file on some other filesystem. But, in this case, the "normal file" is actually itself a raw block device like `/dev/sdb1` or whatever.) Since a block device supports file I/O operations as if it were one big file, this works -- and the page cache kicks in. We then use the loopback device as the backing image for the snapshots, so that all machines end up sharing the page cache.

* **Network boot from iSCSI:** Most network adapter firmwares support "PXE boot" to boot over the network. However, standard PXE firmwares do not typically support iSCSI boot -- that's usually reserved for absurdly expensive "enterprise" NICs. Fortunately, there exists an open source firmware called [iPXE](https://ipxe.org/) that does, in fact, support iSCSI boot. In theory, if you are very brave, you could flash iPXE directly onto your network adapter's firmware ROM. I am not that brave. Instead, what we can do is chain-load. First, the machines will do regular PXE boot, and the server will respond by serving them a copy of iPXE. The machines will then run that, leading to a second PXE boot pass, but this time the server can tell them to boot from the iSCSI volume. Hooray!

* **Windows 10:** Since the original use case was for LAN parties, the client machines run Windows. I did actually try running Linux and WINE for a few months in mid-2011, and it worked better than you'd think, but not well enough. Fortunately, Windows 10 supports installing directly to, and booting directly from, an iSCSI volume -- yes, even Windows 10 Home. However, there are some bugs you'll need to work around, covered later in this guide.

## Prerequisites

You will need:

* Moderate familiarity with Windows and Linux systems administration.
* A server machine with:
    * A large disk dedicated to storing the master image. For modern gaming, at least 2TB is recommended. I use a RAID-1 array (two disks, mirrored) of old-fashion spinning-rust HDDs, but these days SSDs are cheap enough that I'd probably go with them if starting over.
    * A fast SSD dedicated to maintaining overlays. I have had success with as little as 20GB per overlay (250GB drive split 12 ways). However, if a guest decides to install a medium-sized game, they can quickly eat up the whole overlay, at which point it becomes inccessible, the machine BSODs, and you have to reset it from scratch. These days I use 160GB overlays (2TB SSD split 12 ways) which has proven to be much more than enough.
    * A separate disk (small SSD, probably) for the server's own operating system. Mine has a 64GB SSD of which only half is used.
    * A 10 gigabit network interface is recommended. Technically you *can* live with a 1 gigabit interface -- I did for many years -- but modern games will load pretty slowly, especially when everyone is starting the same game at the same time. On the other hand, slow-loading games never bothered us that much, since we used the time to socialize...
    * Ideally, a second network interface, if you want to use it as your router. This interface only needs to be as fast as your internet connection.
    * A lot of RAM. RAM will be used for a shared disk cache. My server has 20GB but I'd probably go with 64GB in a new setup.
* A fleet of client machines, preferably with identical hardware, optimized for whatever workload you're expecting. These machines shouldn't need disks, although I've heard rumors that the Windows installer might spuriously fail if there is no local disk. My machines have small (64GB) local SSDs.
* A network switch with at least one 10 gigabit port (for the server) and enough 1 gigabit ports for the clients.
* Windows 10 licenses for each client machine. Even though you only install Windows 10 once, it will recognize when it's booting on different hardware and will phone home looking for a matching license.

## Setting up the server

### Basic Linux setup

You need to install Linux on your server. This guide cannot cover all the details of how to do that, but there are many resources available on the internet.

This guide works best with Debian or a Debian-derived distro like Ubuntu. The guide was tested using Ubuntu 18.04 (Bionic). With other distros, you may have to tweak the instructions a bit, as files may be located in different places, packages may have different names, etc.

During installation, you should tell the installer to manage your disks with LVM. You should create at least two volume groups: one containing the disk that will hold the server's operating system, and another containing the disks you will use for the client machines' master image and overlays. If you want to use RAID anywhere in here, you should also configure that during installation.

You should NOT configure any kind of encryption on the volumes you plan to use for the master image or overlays; it's better to perform encryption on the client side if desired. I also would recommend against encrypting the boot device, as this will force you to physically enter a password every time you boot your server; we aren't going to store any sensitive secrets on this disk anyway. If you do plan to store secrets on your server, you can create a separate partition for that and encrypt it.

### Network interface renaming

If you have multiple network interfaces (likely the case if you installed a 10 gigabit ethernet adapter), then there's a good chance Linux has assigned ridiculous names to them, like `enp2s0f1`, or worse, `rename2` (and changes every time you boot). What ever happened to the good old days of `eth0`?

You're going to need to sort these out and determine which is which. Start by listing the interfaces:

    ip link show

Unfortunately, the output of this command is not particularly readable. It'll show you the interfaces, but doesn't really tell you which is which. Probably there's some flags you can pass to show more info? I never figured it out. Intsead, I've had more success with a utility called `ethtool`

    apt install ethtool

Now let's take a look at that `rename2` interface by typing `ethtool rename2`. On my machine, I see:

```
Settings for rename2:
	Supported ports: [ FIBRE ]
	Supported link modes:   10000baseT/Full
	Supported pause frame use: Symmetric
	Supports auto-negotiation: No
	Supported FEC modes: Not reported
	Advertised link modes:  10000baseT/Full
	Advertised pause frame use: Symmetric
	Advertised auto-negotiation: No
	Advertised FEC modes: Not reported
	Speed: 10000Mb/s
	Duplex: Full
	Port: Direct Attach Copper
	PHYAD: 0
	Transceiver: internal
	Auto-negotiation: off
	Supports Wake-on: d
	Wake-on: d
	Current message level: 0x00000007 (7)
			       drv probe link
	Link detected: yes
```

Notice the "Supported link modes" line. It says 10000baseT, i.e. 10 gigabit! This is our 10gigE adapter.

Also useful is the last line, "Link detected: yes". If your device has multiple ports, this can help you find the one that's plugged in.

If Linux has unhelpfully named your interface `rename2`, you'll want to fix that by editing:

    /etc/udev/rules.d/70-persistent-net.rules

This file might not exist yet; create it if not. Then you can add a line like so:

    SUBSYSTEM=="net", ACTION=="add", DRIVERS=="?*", ATTR{address}=="00:00:00:00:00:00", ATTR{type}=="1", NAME="eno1"

Replace `00:00:00:00:00:00` with the MAC address of the device. What this rule essentially says is: "When you see a device with this MAC address, give it this name." You'll probably need to reboot for this to take effect.

If you have trouble, a useful debugging tool is to look for log lines about the interface in `dmesg`, e.g. run `dmesg | grep -5 rename2`.

### Router (optional)

While not strictly necessary, I recommend setting up your iSCSI server machine to also act as the gateway/router for your network, with NAT. Most people use the built-in functionality of the modem provided by their ISP for this. However, many modems have buggy firmware. For example, one modem I had could only handle a small number of simultaneous connections, and then would spontaneously reboot. Another modem hijacked the address `1.1.1.1`, effectively blocking access to Cloudflare's public DNS resolver (which rightfully owns this address). In both cases, the problems went away when the modem was switched to "bridge" mode, causing it to pass through packets unmodified. However, this requires you to run your own NAT / firewall behind the modem.

Linux is, obviously, an extremely solid, reliable, and flexible router. I've been very happy pushing all my network traffic through it for the last nine years. In addition to making routing itself more reliable, a Linux-based router will also be able to tell you exactly which devices on the network are using bandwidth, a feature I've found invaluable over and over again (see Tips & Tricks section).

If you don't choose to use your server as a router, then your modem will sit on your internal network. In this case you will need to be very careful to turn off your modem's built-in DHCP so that it doesn't fight with the one on your server.

There are many approaches and tools to configure routing on Linux. My approach is to edit `/etc/network/interfaces` to look something like this:

```
# The loopback network interface
auto lo
iface lo inet loopback

# The external network interface, configured automatically using DHCP.
# This assumes your ISP or modem responds to DHCP queries; if not, see
# below. Note that your network interface may or may not be called "eth0";
# you'll need to figure out what name it has on your system.
# `ip link show` will show all interfaces.
auto eth0
iface eth0 inet dhcp
    # Configure routing at startup.
    pre-up iptables-restore < /etc/iptables.rules

# If your ISP doesn't respond to DHCP, but you have a static IP, use
# this version instead. (Use only one of this or the above; delete the
# other one.)
auto eth0
iface eth0 inet static
    address 128.66.123.55   # your static IP
    gateway 128.66.123.1    # your ISP's upstream gateway IP
    netmask 255.255.255.0   # as specified by your ISP
    # Configure routing at startup.
    pre-up iptables-restore < /etc/iptables.rules

# If you put your modem in bridge mode, your modem's admin interface will
# probably be exposed on some other IP address, like 192.168.0.1. Since
# this is on a totally different subnet from your public address, you won't
# be able to access it directly unless you configure the network interface with
# multiple addresses. Here's how to do that.
auto eth0:0
iface eth0:0 inet static
    address 192.168.0.2     # First three numbers match your modem's IP.
    netmask 255.255.255.0

# Finally, let's configure the internal interface. Hopefully, this is a 10
# gigabit NIC. For some reason, Linux assigns the name "eno1" to my 10G NIC.
# Yours might get a different name. Use `ip link show` to find it.
auto eno1
iface eno1 inet static
    address 10.0.0.1
    netmask 255.255.0.0
```

The important bit to enable routing is this line:

    pre-up iptables-restore < /etc/iptables.rules

We need to create this file, `/etc/iptables.rules`. It can look like this:

```
*nat
:PREROUTING ACCEPT [0:0]
:INPUT ACCEPT [0:0]
:OUTPUT ACCEPT [0:0]
:POSTROUTING ACCEPT [0:0]
-A POSTROUTING -o eth0 -j MASQUERADE
COMMIT
```

Be sure to replace `eth0` with the name of your public interface.

Finally, edit `/etc/sysctl.conf` and add this line:

    net.ipv4.ip_forward=1

Reboot your server. You should now be able to access the internet from a device connected to the internal interface, if the external interface is connected to your modem. Note you'll have to statically configure the IP address of this device for now since there's no DHCP yet; we'll set that up next.

### The `lanparty` script

Download the file `lanparty` from this repository and put it in your `$PATH`, like:

    curl https://raw.githubusercontent.com/kentonv/lanparty/master/lanparty > /usr/local/bin/lanparty
    chmod +x /usr/local/bin/lanparty

We will use this script to assist in later setup, and then to operate the machines during parties.

You will need to configure the script. Get started by generating the default config:

    lanparty configure > /etc/lanparty.conf

Then edit `/etc/lanparty.conf`. Read the comments and edit each setting appropriately. Note in particular that this is where you will configure your list of machines. This list will be used to generate configuration files in the upcoming steps, so it's best that you fully fill this in now, including the full MAC address for every machine.

### Wake-on-LAN

The `lanparty boot` command uses a program called `etherwake`, which you'll want to install:

    apt install etherwake

Also, in order for this to work, you will likely need to enable Wake-on-LAN in the BIOS settings of each of your machines.

### iSCSI server

Let's install the iSCSI server. For some reason iSCSI doesn't like the words "client" and "server" and instead uses "initiator" and "target". And, the server we will use has decided to name itself just `tgt`, not mentioning the iSCSI part at all... ok:

    apt install tgt

Note that the `lanparty` script will take care of starting, configuring, and managing `tgt` entirely on its own, dynamically, with no config files. Therefore, I recommend instructing systemd not to run the server at all:

    systemctl stop tgt
    systemctl disable tgt

However, this is optional. If you'd like to configure `tgt` to export additional iSCSI volumes independently of the `lanparty` script, there should be no problem with doing so. In this case you probably want systemd to manage starting and stopping it.

### DHCP server

Let's install a DHCP server:

    apt install isc-dhcp-server

And then let's configure it. We're going to blow away the existing config, so back it up now if you care about it.

    lanparty configure dhcp > /etc/dhcp/dhcpd.conf

Take a quick look at `/etc/dhcp/dhcpd.conf` and read the comments. If you plan to set up a DNS server later, then you probably don't need to change anything in here. If you don't plan a DNS server, you'll need to edit the `option domain-name-servers` line.

You also need to edit `/etc/defaults/isc-dhcp-server` and edit the `INTERFACESv4=` line to list your internal network interface.

Now restart the server to pick up the new config (it doesn't support `reload`):

    systemctl restart isc-dhcp-server

### tftp and iPXE

When your machines boot using their PXE-boot firmware, they will talk to your DHCP server, which will instruct them to download a file via TFTP. We need a TFTP server to serve that file. And the file we'll serve is iPXE, an advanced PXE bootloader that knows how to boot from iSCSI. Conveniently, we can get the iPXE image from a package, too.

    apt install tftpd-hpa ipxe syslinux-common

You'll want to edit the file `/etc/default/tftpd-hpa`, especially if you have set up routing, to make sure you're not answering TFTP requests from the internet:

```
# /etc/default/tftpd-hpa

TFTP_USERNAME="tftp"
TFTP_DIRECTORY="/var/lib/tftpboot"
TFTP_ADDRESS="10.0.0.1:69"   # Set to your server's INTERNAL address!
TFTP_OPTIONS="--secure"
```

`tftpd` will serve files from `/var/lib/tftpboot`. We need to make iPXE's `undionly.kpxe` show up there, as well as syslinux's `memdisk` utility:

    cp /usr/lib/ipxe/undionly.kpxe /var/lib/tftpboot/undionly.kpxe
    cp /usr/lib/syslinux/memdisk /var/lib/tftpboot/memdisk

(You could also use symlinks here, so that when the packages get updates, you start using them automatically. However, if iPXE and `memdisk` work correctly, there is basically nothing you get out of updating them, and there is always a risk that they break. So, I like to make a copy and only update them explicitly as needed.)

### DNS server (optional)

I recommend setting up an internal DNS server so that your machines can find each other by name. Most games' "connect by IP address" option actually support entering a hostname. I put labels on each of my machines' keyboards showing their name, which makes it easy for people to say "Connect to bubbleman!", etc.

There are many DNS server options, but we'll stick with the classic.

    apt install bind9

The `lanparty` script can generate configuration for you, based on the config you typed into it. Note that different distros may arrange BIND's configuration files differently; we assume a Debian-derived system here.

There are three bits of config we need here. Note that the first step uses `>>` to append, while the others create new files:

    mkdir -p /etc/bind/zones
    lanparty configure dns >> /etc/bind/named.conf.local
    lanparty configure dns-zone > /etc/bind/zones/lanparty.db
    lanparty configure dns-reverse > /etc/bind/zones/lanparty-reverse.db

You must also edit `/etc/bind/named.conf.options` to:

* Specify your upstream nameservers (under `forwarders`). If you aren't sure what they are, check what's written in `/etc/resolv.conf`, or use one of the big public nameservers like Cloudflare's (`1.1.1.1` and `1.0.0.1`) or Google's (`8.8.8.8` and `8.8.4.4`). (Disclosure: I work for Cloudflare.)
* Change `listen-on` to specify only your internal IP and localhost, so that you aren't exposing your DNS server to the public internet, e.g.:

        listen-on { 10.0.0.1; 127.0.0.1; }

And then reload:

    systemctl reload bind9

You'll now want to configure this server itself to use your local DNS server for lookups. It used to be that you could just edit `/etc/resolv.conf` to do this, but these days that file is usually managed by some other service. You may need to figure out how to disable that service or configure it to use `127.0.0.1` as the nameserver. Or, if `/etc/resolv.conf` is a symlink, then you may be able to simply delete the symlink and replace it with a normal file, effectively stealing back control of the file from whatever service is trying to manage it.

    rm /etc/resolv.conf
    touch /etc/resolv.conf

Now edit the file to contain something like:

    nameserver 127.0.0.1
    domain example.com
    search example.com

(Replace `example.com` with whatever you configured for the `DOMAIN` setting in `lanparty.conf` earlier.)

Test your configuration by pinging one of your machine names:

    $ ping cutman
    PING cutman.example.com (10.0.0.3) 56(84) bytes of data.

You can also test reverse lookup with `dig` (may require installing `dnsutils` package):

    $ dig -x 10.0.0.3 +short
    cutman.example.com.

### Samba (optional)

You may want to set up a Samba server for file sharing. In particular:

* Consider sharing a read-only copy of your master image. For LAN parties, I find this helpful for people who decide to bring their own computer, but haven't installed the right games in advance. For Steam games, they can copy the game data directly from the master image's Steam cache into their own. When they then purchase and install the game, Steam will use the existing files without downloading anything.
* Consider sharing a world-writable directory, initially empty, that people can use to save and exchange files. At LAN parties this has been very handy, especially for storing save-game data for use at a future party, since the computers will normally be wiped in between.

This guide won't go into the details of setting up Samba since there's nothing special to it here. Many guides exist around the internet, but also, the file `/etc/samba/smb.conf` contains plenty of comments to get you started.

But, for me, adding the following to the end of `smb.conf` was all it took:

```
# The master image, readable to anyone on the network.
[master]
   comment = Master image files
   read only = yes
   path = /mnt/master
   guest ok = yes

# The share folder, writable to anyone on the network.
[share]
   comment = Shared space
   read only = no
   path = /mnt/share
   guest ok = yes
```

Then reload:

    systemctl reload smbd

## Installing Windows 10

### Download Windows Installer ISO

You need to download a Windows 10 installer ISO image. [You can get this from Microsoft.](https://www.microsoft.com/en-us/software-download/windows10ISO)

Do NOT burn the ISO to a DVD nor create a USB stick. Instead, download the ISO to your server. Place it at:

    /var/lib/tftpboot/win10.iso

### Enter "updates" mode

Whenever you want to make changes to your master image that you intend to keep, you need to use the `lanparty` script to set up your server in "updates" mode.

Run:

    lanparty start-updates HOST

Replace HOST with the hostname of the machine you'll be using for installation.

### Boot the machine into the Windows installer

In order for the Windows 10 installer to show an iSCSI volume as a valid installation target, it needs to find the volume listed in something called the iBFT (iSCSI Boot Firmware Table), a magical chunk of memory that is somehow passed off from the BIOS / early boot stage to the OS bootloader. The idea is supposed to be that if you have an Enterprise iSCSI NIC then it will initialize this table at startup.

Moreover, the BIOS / early boot stage must explicitly tell Windows that "Yes, I am able to boot this device.", otherwise the installer will steadfastly refuse to let you install to the device even if it is visible.

But, we don't have enterprise hardware. Instead, we have iPXE. If we can get iPXE to run _before_ the Windows 10 installer runs, and have iPXE itself pretend to be the BIOS while starting the Windows 10 installer, then iPXE will initialize the iBFT for us, and the Windows 10 installer will find it and let us install to it.

One more catch: iPXE only knows how to netboot. It explicitly doesn't know how to boot from a DVD or USB stick. That's why we didn't create one earlier. Instead, we'll tell `iPXE` to load our ISO file over the network, and then run it using `memdisk`.

First, configure your client machine to boot from the network. In the BIOS, set the network adapter as the first and only boot option.

Now, let it boot, but watch closely, because we have to hit a key at the right moment. Your BIOS will hand off to the network adapter firmware, which will query your DHCP server. It'll then download and run iPXE, and you'll see something like this:

    iPXE initializing devices...ok

    iPXE -- Open Source Network Boot Firmware -- http://ipxe.org
    Features: HTTP iSCSI DNS TFTP AoE FCoE TFTP COMBOOT ELF PXE PXEXT

    Press Ctrl-B for the iPXE command line...

Press Ctrl-B now! You only get a second or two. If you miss it, then iPXE will attempt to boot from iSCSI, which will presumably fail since the master image isn't formatted yet.

If you got it right, you're now at the iPXE prompt:

    iPXE>

You need to type a series of commands:

    dhcp
    set keep-san 1
    sanhook iscsi:10.0.1.0:::1:iqn.2019-12.com.example:cutman
    initrd win10.iso
    kernel memdisk iso raw
    boot

Replace `iscsi:10.0.1.0:::1:iqn.2019-12.com.example` with the value of `ISCSI_TARGET_PREFIX` from your `lanparty.conf`, and replace `cutman` with your client's host name.

Let's break down what this does:

* `dhcp`: Configures the network and obtains an IP address.
* `set keep-san 1`: Tells iPXE to pass off the upcoming iSCSI connection to the Windows 10 installer via iBFT.
* `sanhook iscsi:10.0.1.0:::1:iqn.2019-12.com.example:cutman`: Tells iPXE where to find our iSCSI volume, to place in iBFT.
* `initrd win10.iso`: Loads `win10.iso` into local RAM, so that we can boot it as a ramdisk. (This will take some time. TFTP is a rather inefficient file transfer protocol.) (The command is called `initrd` because when booting Linux, you would use this to load an `initrd` image, which provides an early-stage root filesystem which knows how to boot the real system.)
* `kernel memdisk iso raw`: Loads `memdisk` as our "kernel", passing it boot parameters to tell it that we're going to boot an ISO loaded as a ramdisk.
* `boot`: Run it.

Anyway, the Windows 10 installer should now start.

PROTIP: Any time you want to boot an ISO image in the future, you can use the iPXE command line to load it over the network like above. Never again will you need to dig up a USB stick nor burn a DVD!

### Install Windows 10

Follow the on-screen instructions to install Windows 10 to the iSCSI volume. This part should "just work", up until the first reboot.

### Work around `PAGE_FAULT_IN_NONPAGED_AREA`

Eventually, your machine will reboot, and it will now attempt to boot directly from iSCSI (you should NOT interrupt the process with ctrl+B this time).

Unfortunately, due to a Windows 10 bug, this step will likely fail with a Blue Screen Of Death reporting `PAGE_FAULT_IN_NONPAGED_AREA`, and then go into a boot loop.

This appears to happen when the system page file is located on the iSCSI device. While locating the page file on iSCSI worked fine under Windows 7, it appears to be broken in Windows 10. Unfortunately, Windows defaults to setting up a page file on the primary disk, so when the primary disk is iSCSI, it is broken out-of-the-box.

(Note that the stop code `PAGE_FAULT_IN_NONPAGED_AREA` does not _necessarily_ relate to the system page file in general, despite containing the word "page". This stop code is more like the NT kernel's version of "Segmentation Fault", a general invalid memory access. But, in my specific case, it coincidentally turned out to be related to the page file.)

I was able to solve the problem by disabling the page file entirely. (It also works to locate the page file on a local disk, if one exists, but this is easier to configure after getting the OS up and running with no page file.)

**Disabling page file offline**

Since your machine is not bootable, you cannot disable the page file through the UI. Luckily, it's easy to disable the page file via the registry. To do so, locate the following registry key, and set its value to be empty:

    HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\Session Manager\Memory Management\PagingFiles

If your registry contains `ControlSet002` and/or `CurrentControlSet` in addition to `ControlSet001`, make sure to make the same changes to those.

**Editing registry offline**

But how do we edit the registry without booting? There are multiple approaches. The easiest thing to do is use an existing, working, Windows 10 machine (e.g. a laptop or even a VM) to mount the iSCSI volume and run regedit on it. Note that in order to permit this other machine to mount the iSCSI volume, you will need to run:

    lanparty authorize-addr HOST ADDR

where `HOST` is the hostname that normally boots from this disk, and `ADDR` is the IP address of the machine that needs to access it. Otherwise, normally the iSCSI volumes are only exposed to their respective machines' addresses.

In order to edit a registry offline (i.e., edit a registry other than the one of the system that is running regedit):

1. Run `regedit` ("Registry Editor") normally.
2. Click on `HKEY_LOCAL_MACHINE`.
3. Go to "File > Load Hive...".
4. Browse to the offline Windows installation, and choose the file `Windows\System32\config\SYSTEM`.
5. When prompted, type any arbitrary name, like "OFFLINE_SYSTEM".

The offline registry file will appear in the tree under `HKEY_LOCAL_MACHINE` with the name you chose. Edits you make to keys within it will usually be saved automatically, although it is advised that you explicitly unload the offline hive before closing regedit to be sure. This is a very strange UI, but that's apparently how it is done.

### Avoiding Microsoft Sign-in

When Windows 10 boots for the first time, it'll try to force you to sign in with a Microsoft account. This is NOT what you want. Your machines are intended for use by guests, and you probably don't want to force your guests to log into their own Microsoft account. You could set up Windows using an online account and then create a local account later, but it's much cleaner to avoid signing into an online account at all.

Unfortunately, a recent update makes it so that the Windows 10 setup process won't give you the option to create a local account. However, there's a trick: If the machine cannot reach the internet, then a local account will be allowed.

Of course, your machine needs continuous access to the LAN, since it's booting over iSCSI. So, you can't unplug just the one machine. Instead, you could unplug your internet modem temporarily. Or, if you set up your server as a router, you can temporarily block internet access for the one specific machine like so:

    iptables -A FORWARD -s cutman -j DROP

Replace `cutman` with the particular machine's name. Voilà, no more internet! If you're already at the sign-in prompt in Windows 10 setup, click the back-arrow button in the upper-left. The account creation prompt will come up again, but this time won't prompt you to sign into a Microsoft account. It simply says "Who's going to use this PC?" and lets you set a username.

For what it's worth, I like to use "LAN Party Guest" as the username. I set no password for this account and enable auto-login.

Once you've gotten past account creation, you can unblock the machine like so:

    iptables -D FORWARD -s cutman -j DROP

### Set Up Windows 10

Once your account is created, and you've said "no" to all of Microsoft's myriad requests to surveil you, Windows 10 will finish setting up.

From here it's up to you to install apps and configure your machine however you want.

### Set up SSH

In order to use the `lanparty` script to shut down your machines (really convenient at the end of a party!), you will need to enable SSH access. Believe it or not, Windows 10 now has built-in support for being an SSH server! Even Windows 10 Home edition!

To install the SSH server:

* Open the "Settings" app.
* Go to Apps -> Apps & features -> Optional Features.
* Click "Add a feature".
* From the list, choose "OpenSSH Server" and click "Install".

Next, we should configure the server for public key authentication, so that you can SSH to it without a password, which we need for automation purposes. (If you set your user account's password blank, then OpenSSH won't let you log in at all by default.)

This part is a bit awkward, because our user account has administrator access. By default, administrators cannot just stick `.ssh/authorized_keys` into their home directory like normal. Instead, a special administrators key file needs to be modified. Worse, if you don't get the permissions on this file exactly right, it doesn't work.

* Browse to `C:\ProgramData\ssh\`. Note that `ProgramData` is a hidden folder! (Whyyyy?)
* Copy your id_rsa.pub into this folder, and rename it to, exactly, `administrators_authorized_keys`. (If you aren't familiar with `id_rsa.pub`, look up guides on SSH public key authentication.)
* Change the permissions on this file so that it is owned by the group "Administrators", NO ONE has permission to write to it, and the group "Administrators" has permission only to read. You will have to disable inheritance of permissions from the parent folder.

With that done, now you can start the SSH server:

* Open the "Services" control panel applet (just type "services" in the main Windows search bar).
* Find "OpenSSH SSH Server" in the list.
* Start it.
* Change its "Startup Type" to "Automatic", so that it starts on next boot.

Now try SSHing! If it doesn't work... you probably got one of the steps wrong around `administrators_authorized_keys`. Yes, it really does need to have the very specific permissions described. Why? Who knows! Some sort of bizarre security check? But why does the _owner_ of the file have to be denied _write_ permission? That accomplishes nothing, since the owner can re-enable write permission at any time.

If you're struggling to figure out why SSH login isn't working, try this:

* Under "Services", stop OpenSSH.
* Run a command prompt (cmd) as Administrator.
* In the command prompt, do: `sshd -ddd` This will run the SSH server to accept _one_ connection and then show debug info.
* Try connecting again, and see what the console prints.

Yes, you need three 'd's in `-ddd`. Any fewer, and it won't tell you if the permissions on `administrators_authorized_keys` are wrong; it'll just report that no key matched.

Anyway, now that you set this up, you should be able to use `lanparty shutdown` to shut down machines!

### Merge changes

Shut down the machine. Might as well test using `lanparty` for this:

    lanparty shutdown HOST

(Or, you can shut it down via the Windows UI like a normal person.)

Once the machine has fully powered off, it's time to merge your installation into the master image:

    lanparty merge

This will take a while, but you'll see progress updates on-screen as it goes.

### Register Windows licenses

The first time you boot each machine into Windows 10 (e.g. following the instructions in the next section), it will recognize that the machine is not licensed and complain. Go through the normal process to acquire a Windows 10 license for that machine. Once licensed, the machine is registered in Microsoft's database, so it will never ask you again. Yes, this seems to imply that the machines will phone home to Microsoft for a license check every time you re-initialize their images from the master image, which is sort of disturbing... but it's a whole lot more convenient than what was needed with previous versions!

## LAN party operations

This section describes how I use the `lanparty` script to operate an actual LAN party.

### Installing updates before a party.

The night before a party, I update the master image. To get started, I do:

    lanparty start-updates flashman
    lanparty boot flashman

(I always use `flashman` as my master machine, just because it's closest to my desk.)

I then scoot over to the `flashman` game station and, over the course of several hours and a couple beers, update everything that needs updating:

* Check for updates with Windows Update.
* Open each of Steam, Blizzard Launcher, Epic Launcher, Origin, etc. and let them download any updates.
* Open my stand-alone Factorio installation and tell it to self-update.

In my current setup, my overlay device is larger than my master image, so there is no risk of running out of overlay space when installing updates. However, with a previous setup, I used a 240GB overlay on a 1TB master image. In this setup, installing 100GB or more of games in one sitting (**cough** Ark **cough**) would risk running out of overlay space. If overlay space runs out, the overlay immediately becomes invalid and is lost, and updates have to be started over! So, I'd keep an eye on the current overlay usage using `lanparty status` and, if it got too high, shut down the machine, do a `lanparty merge`, and then start updates again.

Anyway, usually, Steam updates take the longest, so I run that last, and then go to bed while it runs. This also gives Windows time to do any defragmentation that it feels the need to do, while the machine is idle; it's important to get that out of the way before merging!

In the morning, I:

* Close and re-open Steam. It almost always has a self-update queued which installs itself when re-opened.
* Verify that there aren't any more updates that appeared overnight. (Dear game studios: Friday night is not a good time to push updates!)
* Shut down the machine.

Then I do:

    lanparty merge

and wait for it to complete.

### Starting the party

With merge complete, at the start of the party, I do:

    lanparty init
    lanparty boot

All the machines boot up. I go around and check that all the monitors are on and displaying the boot screen.

### Checking on status

Sometimes guests will decide to install additional games. If these games are large compared to the per-machine overlay space, they risk filling up the overlay and taking it offline. Also on occasion, there have been problems where some background process (typically Windows itself, trying to defrag the disk) would do lots of disk writes even when a machine was idle.

In order to monitor such problems, I do:

    lanparty status

This shows the current overlay usage for each machine.

If a particular machine runs out of overlay space, it will blue-screen, reboot, and fail to boot. At this point, it is necessary to wipe its overlay, which can be done as follows:

    lanparty destroy HOST
    lanparty init HOST

Where `HOST` is the name of the particular machine. After this, the machine should be able to boot fresh.

### Ending the party

At the end of the party, I do:

    lanparty shutdown

This issues an SSH command to all machines to make them shut down. No need to go around manually!

Once all machines are off, I wipe all changes made during the party:

    lanparty destroy

## Tips and Tricks

### Dead overlays

Writing to a machine's disk uses space in its overlay. If the overlay is smaller than the master image, then it is possible that the overlay will fill up with changes. Windows has no idea that the overlay exists, so does not know when it is running out of overlay space.

Once an overlay runs out of space, it immediately becomes invalid and all data in the overlay is lost. Windows finds it can no longer write to disk, which is a situation it is not designed to handle, so it promptly blue screens and reboots. On reboot, the iSCSI volume will be inaccessible, so boot will fail.

The `lanparty status` command can be used to monitor the current overlay usage of all machines. If a particular machine runs out of space, you can reset it to an empty image using `lanparty destroy HOST` followed by `lanparty init HOST`.

If your per-machine overlays are small, make sure to remind your guests not to install new stuff to the machines.

When installing updates, all overlay space is dedicated to the update machine rather than split among the fleet, so you have much more headroom. Ideally, your total overlay space is larger than your master image, in which case you have nothing to worry about at all. But, if not, it's a good idea to keep an eye on the overlay usage, which you can do again using `lanparty status`. If usage gets close to 100%, you should shut down the machine, merge what you have so far, and then start updates again. If you accidentally use up the overlay during udpates mode, you will have to start updates over from scratch, which is a pretty horrible thing to discover right before your party is supposed to start!

### Steam Update Schedule

The Steam client can be configured such that it will only automatically download updates at a certain time of day. I recommend setting this to a narrow window around 4AM, with the idea being to prevent Steam from auto-installing updates at all. Otherwise, when guests open Steam and log in with their own accounts, Steam is liable to start automatically downloading any DLC they have (but you don't) for any installed games, wasting bandwidth and overlay space.

When you are actually trying to update, you can go to the "downloads" list and manually tell Steam what to install, regardless of the schedule.

Although less important, you can also do something like this with Windows Update.

### Background defrag

Back in the old days, hard drives would get fragmented over time, and you'd have to run a special "defrag" program to fix it.

In the modern era, people don't do this anymore. Not because fragmentation doesn't happen, but because the operating system deals with it automatically.

When Windows senses the machine is idle, it'll start doing housekeeping tasks, like defragmenting the disk. If there has been a lot of disk churn lately -- e.g., becaues you just installed updates -- then Windows may do a LOT of writing at this time.

It's important that you give Windows time to do this *before* you merge your updates back into the master image. Otherwise, Windows is going to start defragging machines as soon as you start them up for the party. If a bunch of machines all start defragging, all the disk I/O will ruin performance for the remaining machines that are actually in-use. Worse, Windows can blow through the machines' overlay space pretty quickly, forcing them to be reset from scratch... at which point they will start defragging again!

To avoid this situation, it's a good idea to leave the updates machine idle for a few hours after installing most of the updates, but before merging.

### Monitoring network usage

Sometimes, something is using up all your bandwidth, and you can't figure out what. If you set up your Linux server to be your router, tracking down the culprit is easy using `iftop`.

    apt install iftop

Now you can do:

    iftop -i eno1

(Replace `eno1` with the name of your *internal* network interface.)

You'll see a nice display showing the top network users in real time, and what they're connecting to. If you've set up reverse DNS, you'll even see machines listed by name.

Random hints:
* You'll see `1e100.net` a lot. It's Google. Because 'Google" came from "googol" which is 10^100.
* Edit `/root/.iftoprc` to contain `max-bandwith: 100M` (or whatever your internet connection speed is) so that the bar display is scaled nicely.
* If you list every device in your house in `MACHINE_TABLE` in `lanparty.conf` (and generate DHCP and DNS config based on those), this display gets even more useful. You can make phones, laptops, etc. show up by name. Note that the `arp` command can be useful to discover the MAC addresses of devices currently connected to the network, to help fill in `MACHINE_TABLE`.

### Canceled merge

If you do `lanparty merge`, but then cancel the command mid-merge (e.g. by pressing ctrl+C, disconnecting SSH, or suffering a power outage), fear not: LVM will keep merging in the background. However, you'll need to wait for it to finish before doing other `lanparty` commands. Use `lvdisplay` to see the current status.

### Mismatching hardware

I have only tested this technique with client machines that contained identical hardware, meaning that they all needed exactly the same drivers. This probably makes it easier to boot from identical disk images.

However, I suspect that Windows could handle booting non-matching machines from the same image without too much additional trouble. My guess is that you would merely need to cycle through each machine running it in "updates" mode once, let Windows install the necessary drivers for that machine, and then merge them. Once you've done this with every machine, the master image ought to have the union of all necessary drivers, and so should be able to boot any machine... I think.

Note that network drivers could be tricky. If a machine doesn't have the right network drivers, it won't be able to netboot at all. These days, practically all motherboards have a Realtek NIC built-in, so hopefully you'll only need the one driver there. If not, you may need to use the first machine to manually install network drivers for all machines. You may additionally need to edit the registry to tell Windows that the driver needs to be loaded during early boot. I don't have specific instructions on how to do this, so you'll need to do some Googling.
