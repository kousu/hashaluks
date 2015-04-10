#!/bin/bash

DISKIMG=baskets.img
DISKID=$(cryptsetup luksUUID $DISKIMG)   
MNT="${DISKIMG}.mnt"

sudo umount "${MNT}" &&
sudo cryptsetup close $DISKID
rmdir "${MNT}"
