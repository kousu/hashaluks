#!/bin/bash

# LUKS and hashapass based almost-one-click crypto disk solution.
# The advantage this provides over plain LUKS (much like LUKS's
# advantages over plain dm-crypt) is that every disk image has a unique
# decryption key via hashapass---so that if someone gets your password
# file they have no better chance of cracking your disks than before
# (so long as you never ever ever write down your root hashapass password)

# requires
#  cryptsetup from the Linux kernel community and
#  hashapass.sh from http://github.com/kousu/hashapass installed to your PATH
#  xclip
#  coreutils
#  bash(?)

# TODO:
# [ ] better error checking / recovery (: we should delete things when we break!)
#  [ ] what happens if the image has unmounted but not cryptsetup closed?
#  [ ] if we ask cryptsetup what it has mounted before the attempt, we can skip hashapass'ing on double-mounts
#  [/] what happens if we format a mounted drive? (cryptsetup lets us do this :S :S. it even appears to sort of be working with two separate filesystems. but i'm sure this is just the kernel cache hiding the massive corruption underneath)
#    [ ] instead of closing a previous mount, we should probably detect and bail
# [ ] arrange so that the sudo password is only given once (privsep??)
#   [ ] this script *could* use sudo in its shebang (or equivalently sudo itself as a first step)
#       but I'm loath to do this because on my particular hashapass is only installed to my local
# [ ] pass args instead of globals to mount() and unmount()
# [ ] test that partition targets actually work
# [ ] for compat with regular mount, make sure you can do
#   [ ] "hashaluks mount disk.img /path/to/mountpoint" #<-- this one is easy; but the second is harder
#   [ ] "hashaluks umount disk.img.mnt/"
# [ ] remove the dependency on xclip, by fixing the bug in hashapass
# [ ] test against non-bash shells
# [ ] pull the baskets.img assumption out to wrapper scripts.
# [ ] allow size-suffixes
# [ ] the various initialization parameters are hardcoded. is this a bug or a feature?
# [ ] is there a TOCTOU between the time we set the password once and then again?
# [ ] factor the common bits; format and mount share a *lot* of code

## Argument parsing

usage() {
  echo "Usage: hashaluks [mount|umount|format] [disk.img]"
  #echo "If disk.img is not given, 'baskets.img' in the same directory as this script is assumed."
  echo
  echo "disk.img can either be a raw disk device, a partition, or any (hopefully empty) file of the desired filesystem size (e.g. created with dd or even vi)"
  exit 1
}

if [ -z $1 ]; then
  usage
else
  CMD=$1; shift;
fi

if [ -z $1 ]; then
  HERE=$(cd $(dirname $0); pwd)
  DISKIMG="${HERE}/baskets.img"
else
  DISKIMG=$1; shift
fi


## Common globals

MNT="${DISKIMG}.mnt"


## Subroutines
# warning: these are supppper side-effecty 


diskid() {
	# read the LUKS UUID off of DISKIMG 
	# TODO: memoize this because it's a nuisance it has to be run twice
	#DISKIMG=$1; shift
	echo "diskid($DISKIMG)" >/dev/stderr #DEBUG
	cryptsetup luksUUID "${DISKIMG}" 2>/dev/null
}


## Subcommands

create() {
  #DISKIMG=$1; shift
	echo "create($DISKIMG)" >/dev/stderr #DEBUG
	
	read -p "$DISKIMG not found. To create, enter a non-zero size (in KiB): [0] " SIZE
	if [ -z $SIZE ]; then
		SIZE=0
	fi

	if [ $SIZE -gt 0 ]; then
	
	  # warn users about tiny disks
	  if [ $SIZE -lt 2400 ]; then
	    read -p "Sizes less than 2400KiB tend to run into glitches in loop(8), cryptsetup, and ext4. Continue? [y/N] " C
	    if [ -z $C ]; then C=N; fi #we have to do this or else the if on the next line *parses wrong* because bash is made of evals ugh
	    if [ $C == "y" -o $C == "Y" ]; then
	      #pass
	      echo -n
	    else
	      exit 0
	    fi
	  fi
	  
	  # actually create the file 
		echo "creating ${SIZE}KiB disk image $DISKIMG" >/dev/stderr #DEBUG
		if ! dd if=/dev/zero of=${DISKIMG} bs=1K count="${SIZE}"; then
			echo "Unable to create ${DISKIMG}"
			exit 1
		fi
	else
		echo "No size entered; not creating disk image" >/dev/stderr #DEBUG
		exit 0   #XXX I'm not sure about this. This exit might bite me later on.
	fi
}

format() {
	#DISKIMG=$1; shift
	echo "format($DISKIMG)" >/dev/stderr #DEBUG
	
	# create the image, if needed
	if [ ! -e $DISKIMG ]; then
	  create
	fi
	
	# try to close a previous
	(umount 2>&1 >/dev/null)
	
	# set the disk image password
	#  (actually, the password for the LUKS master password, but in
	#  daily use this is the one you think of as your "disk password")
	# we use the LUKS UUID as the hashapass parameter, so we need to
	# set the key *after* the luks container has been made, which means
	# setting a dummy password and then changing it.
	if ! echo "password" | cryptsetup luksFormat --cipher twofish "${DISKIMG}"; then
		echo "Unable to LUKS-format ${DISKIMG}" >/dev/stderr
		exit 1
	fi
	
	DISKID=$(diskid) #NOTE: no error checking here; assuming that a successful `cryptsetup lukesFormat` always writes a DISKID
	KEY=$(hashapass -s ${DISKID}) &&
	echo "KEY="$KEY >/dev/stderr &&
	(echo password; echo $KEY) | cryptsetup luksChangeKey ${DISKIMG} &&  #subtley: the subshell "(..)" effectively lets us pipe two lines into cryptsetup instead of just one
	echo "successfully changed luks key" #DEBUG
	
	echo sudo cryptsetup open --type luks "${DISKIMG}" "${DISKID}" >/dev/stderr #DEBUG
	if ! echo ${KEY} | sudo cryptsetup open --type luks "${DISKIMG}" "${DISKID}"; then
	  echo "Unable to cryptsetup open ${DISKIMG}"
	  exit 1
	fi
	
	# mkfs
	read -p "Enter new filesystem label: " LABEL &&
	echo "successfully read LABEL: $LABEL" && #DEBUG 
	if ! sudo mkfs.ext4 -L ${LABEL} /dev/mapper/$DISKID; then
		echo "Unable to create filesystem." 
		exit 1
	fi  #<--note that we mkfs on the mapped device, not the file. the kernel lets you but gets confused if you try the other way.  
	echo "successfully formatted" #DEBUG
	
	# set up default permissions
	if [ ! -d ${MNT} ]; then
		mkdir ${MNT};
	fi &&
	sudo mount /dev/mapper/$DISKID ${MNT} &&
	sudo chgrp -R users ${MNT} &&
	sudo chmod -R g+w ${MNT} &&
	(echo "Successfully initialized new drive's permissions:" && ls -ld ${MNT}) >/dev/stderr && #DEBUG
	sudo umount ${MNT} &&
	sudo cryptsetup close "${DISKID}"
	
	rmdir ${MNT} # it is alright if this one fails
}

mount() {
	#DISKIMG=$1; shift
	echo "mount($DISKIMG)" >/dev/stderr #DEBUG

	DISKID=$(diskid)
	if [ -z $DISKID ]; then
		echo "${DISKIMG} does not appear to be a LUKS disk. You need to 'hashaluks format ${DISKIMG}' to use this file as an encrypted disk."
		exit 1
	fi
	
	KEY=$(hashapass -s ${DISKID})
	if ! echo ${KEY} | sudo cryptsetup open --type luks "${DISKIMG}" "${DISKID}"; then
	  echo "Unable to cryptsetup open ${DISKIMG}"
	  exit 1
	fi
  
  if [ ! -d ${MNT} ]; then
		mkdir ${MNT};
	fi
	sudo mount /dev/mapper/$DISKID ${MNT}
}

umount() {
	#DISKIMG=$1; shift
	echo "umount($DISKIMG)" >/dev/stderr #DEBUG
	
	DISKID=$(diskid)
	if [ -z $DISKID ]; then
		echo "${DISKIMG} does not appear to be a LUKS disk. You need to 'hashaluks format ${DISKIMG}' to use this file as an encrypted disk."
		exit 1
	fi
	
	sudo umount "${MNT}" &&
	if ! sudo cryptsetup close $DISKID; then
	  echo "Unable to cryptsetup close ${DISKIMG}"
	  exit 1
	fi &&
	rmdir "${MNT}"
}

if [ $CMD == "mount" ]; then
  mount
elif [ $CMD == "umount" ]; then
  umount
elif [ $CMD == "format" ]; then
  format
else
  usage
fi