#!/bin/bash

HERE=$(cd $(dirname $0); pwd)

DISKIMG="${HERE}/baskets.img"
MNT="${DISKIMG}.mnt"

if [ ! -e $DISKIMG ]; then
  read -p "No $DISKIMG found. To create, enter a non-zero size (in KiB): [0]" SIZE
  if [ -z $SIZE ]; then
    SIZE=0
  fi
  if [ $SIZE -gt 0 ]; then
    dd if=/dev/zero of=${DISKIMG} bs=1K count="${SIZE}"
  else
    exit 0
  fi
fi 

if ! cryptsetup luksUUID "${DISKIMG}"; then
  echo "Initializing LUKS-encrypted disk ${DISKIMG}" &&
  #XXX this is dangerous: this step stomps on whatever file you pass without warning
  # initialize the device
  # XXX hardcoded format parameters
  echo "password" | cryptsetup luksFormat --cipher twofish "${DISKIMG}" &&
  INIT="Yes"
fi &&

DISKID=$(cryptsetup luksUUID "${DISKIMG}")
echo "DISKID=" $DISKID  #DEBUG
echo -n "Enter your Hashapass "
hashapass ${DISKID}     #  I would like to be able to pipe directly from hashapass, but it has a mysterious hanging bug;
                      #  so instead I fall back on xclip, which means X has to be running for this to work :(
KEY=$(xclip -selection clipboard -o)
echo -n | xclip -i -selection clipboard && #clear the clipboard

if [ ! -z ${INIT} ]; then
  # change the key *after* the luks device has been made; this is because we use  
  # this is awkardly split from the rest of initialization so that I don't have to copypaste the DISKID+password (in a better language, I'd use a subroutine with multiple returns)
  (echo password; echo $KEY) | cryptsetup luksChangeKey ${DISKIMG} &&
  echo "successfully changed luks key" #DEBUG
fi &&

echo ${KEY} | sudo cryptsetup open --type luks $DISKIMG $DISKID &&

if [ ! -z ${INIT} ]; then
  read -p "Enter new filesystem label: " LABEL &&
  echo "successfully read LABEL: $LABEL" && #DEBUG 
  echo sudo mkfs.ext4 -L ${LABEL} /dev/mapper/$DISKID &&
  sudo mkfs.ext4 -L ${LABEL} /dev/mapper/$DISKID  #<--note that we mkfs on the mapped device, not the file. the kernel lets you but gets confused if you try the other way.  
 echo "successfully formatted" #DEBUG
fi &&

(mkdir ${MNT};
sudo mount /dev/mapper/$DISKID ${MNT}) &&

if [ ! -z ${INIT} ]; then
  
  #XXX hardcoded defaults
  sudo chgrp -R users ${MNT} &&
  sudo chmod -R g+w ${MNT} &&
  echo "Successfully initialized new drive's permissions:" && ls -ld ${MNT}
fi
