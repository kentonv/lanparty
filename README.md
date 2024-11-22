# Kenton's LAN Party House Management Script

<!-- TOC -->

- [Introduction](#introduction)
- [The Magic Sauce](#the-magic-sauce)
- [How to do it yourself](#how-to-do-it-yourself)

<!-- /TOC -->

## Introduction

[My house](https://lanparty.house) features 22 identical machines used for LAN parties. This repository contains the script I use to manage them, and a guide to creating a similar setup. I use this for gaming, but the setup could be just as useful for office machines, internet cafes, school computer labs, and the like.

## The Magic Sauce

Normally, maintaining twelve machines used by random guests would have two huge problems:

* Every machine would need to be updated before each party. With games regularly pushing multi-GB updates these days, this would take forever.
* Guests could easily mess up a machine at a party, requiring me to wipe it and start over, taking even more time.

But, I have solved these problems!

* I only install updates once, and they become immediately available to all machines -- no need even to "clone" the disk image.
* Any changes made by guests at a party are trivially wiped at the end of the party.

How?

* All game machines netboot over iSCSI, from a single server that manages all storage. The game machines don't even use their own disks at all.
* The server maintains a single master image, along with a copy-on-write overlay for each game machine. Any writes originating from one machine are written only to its private overlay. Any reads check the overlay first, and if the data hasn't been modified, read directly from the master image.
* When installing updates, I still use an overlay, but I then merge the overlay back into the master image once updates are complete.

Results:

* Since the overlays start empty, they can be created instantaneously at the start of the party. There is no need to copy the complete contents of the disk for each machine (which would take forever!).
* At the end of a party, the overlays are simply deleted, wiping out any changes any guest may have made. This, again, takes no time.
* Each overlay need only be big enough to store the *changes* made during a party, which are typically minimal. 20GB per overlay is plenty, even if the master image is terabytes in size.

## How to do it yourself

This repository contains the script I use to manage the computers, as well as a guide to help you replicate my setup. This repo will help you:

* Create a master volume and space for overlays using LVM.
* Configure DHCP, tftp, iPXE, and iSCSI for netboot.
* Configure a private DNS server so your machines can name each other (optional).
* Set up and tear down overlays for parties, as well as arrange to install updates, using a convenient script.
* Install Windows 10 directly to an iSCSI device.

[To get started, see the guide »](guide.md)
