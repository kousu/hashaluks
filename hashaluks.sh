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
# [/] better error checking / recovery (: we should delete things when we break!)
#  [ ] what happens if the image has unmounted but not cryptsetup closed?
#  [ ] if we ask cryptsetup what it has mounted before the attempt, we can skip hashapass'ing on double-mounts
#  [/] what happens if we format a mounted drive? (cryptsetup lets us do this :S :S. it even appears to sort of be working with two separate filesystems. but i'm sure this is just the kernel cache hiding the massive corruption underneath)
#    [ ] instead of closing a previous mount, we should probably detect and bail
# [ ] arrange so that the sudo password is only given once
#   [ ] fork a privsep'd helper??
#   [-] auto-sudo: use sudo in its shebang (or equivalently sudo itself as a first step)
#     sudo helpfully preserves paths (yay) but it doesn't preserve $USER or umask (obviously, that's the point)
#     so it is a bad idea to do this because it ruins create() in subtle ways
#     maybe it would be okay to auto-sudo iff we do not need to create(), but this is awkward to code, so it's on hold for now 
# [ ] pass args instead of globals to mount() and unmount()
# [ ] test that partition and raw disk targets actually work
# [ ] for compat with regular mount, make sure you can do
#   [ ] "hashaluks mount disk.img /path/to/mountpoint" #<-- this one is easy; but the second is harder
#   [ ] "hashaluks umount disk.img.mnt/"
# [x] remove the dependency on xclip, by fixing the bug in hashapass
# [ ] test against non-bash shells
# [ ] pull the baskets.img assumption out to wrapper scripts.
# [ ] rename to hluks
# [ ] allow size-suffixes
# [ ] is there a TOCTOU between the time we set the password once and then again?
# [ ] factor the common bits; format and mount share a *lot* of code
# [ ] the various initialization parameters are hardcoded. is this a bug or a feature?
# [ ] this was written on ArchLinux. It's probbbbably got some portability issues.
# [ ] use bash's default-value syntax instead of my verbose if's

## auto-sudo:
## make sure all commands below run as root. 
## (this assumes that sudo preserves $PATH, since most people (i.e. me, who else?)
##  aren't going to have hashapass installed to their system PATH)
#if [ ! $EUID -eq 0 ]; then
#  echo "auto-sudo" > /dev/stderr
#  sudo $0 $@
#  exit $?
#fi

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

catch() {
  # run a command and catch all its error codes into fatal errors
  # this makes bash *almost* have proper exceptions
  #
  # You should still write your code with liberal use of &&'s as 'exit'
  # only kills the current (sub)shell, and pipelines implicitly build subshells
  # for example,
  #   `cat hashaluks.sh | catch grep zoot`    will *not* exit (because
  #                                           catch is being run as part
  #                                           of the pipeline's subshell)
  #   `catch "cat hashaluks.sh | grep zoot"`  will
  # So to keep things simple, just always follow this pattern:
  # catch cmd1 &&
  # catch cmd2 &&
  # catch cmd3
  #
  # You could also use '|| exit 1' after the subshell, for example:
  # cmd1 | catch cmd2 || exit 1
  #	VAR=$(catch cmd1) || exit 1
  
  #echo "[catch]: running '$@'" >/dev/stderr #DEBUG
  if ! $@; then
	  #echo "Unable to '$@'" >/dev/stderr #DEBUG
    exit 1
  fi
}


diskid() {
	# read the LUKS UUID off of DISKIMG 
	# TODO: memoize this because it's a nuisance it has to be run twice
	#DISKIMG=$1; shift
	#echo "diskid($DISKIMG)" >/dev/stderr #DEBUG
	DISKID=$(cryptsetup luksUUID "${DISKIMG}" 2>/dev/null)
	if [ -z $DISKID ]; then
		echo "${DISKIMG} does not appear to be a LUKS disk. You need to 'hashaluks format ${DISKIMG}' to use this file as an encrypted disk." >/dev/stderr
		return 1 #signal error
	fi
}


## Subcommands

create() {
  #DISKIMG=$1; shift
	#echo "create($DISKIMG)" >/dev/stderr #DEBUG
	
	read -p "$DISKIMG not found. To create, enter a non-zero size (in KiB): [0] " SIZE
	if [ -z $SIZE ]; then
		SIZE=0 #default value
	fi

  # warn users about tiny disks
	if [ $SIZE -gt 0 -a $SIZE -lt 2400  ]; then
    read -p "Sizes less than 2400KiB tend to run into glitches in loop(8), cryptsetup, and ext4. Continue? [y/N] " C
    if [ -z $C ]; then C=N; fi #we have to do this or else the if on the next line *parses wrong* because bash is made of evals ugh
    if [ $C == "y" -o $C == "Y" ]; then
      #pass
      echo -n
    else
      SIZE=0
    fi
  fi
	  
  # actually create the file 
	if [ $SIZE -gt 0 ]; then
		#echo "creating ${SIZE}KiB disk image $DISKIMG" >/dev/stderr #DEBUG
		catch dd if=/dev/zero of=${DISKIMG} bs=1K count="${SIZE}"
		catch chmod 600 ${DISKIMG}  # give only the owner permissions (secure by default!)
	else
		exit 0 #XXX I'm not sure about this. This exit might bite me later on.
	fi
}

format() {
	#DISKIMG=$1; shift
	#echo "format($DISKIMG)" >/dev/stderr #DEBUG
	
	# create the image, if needed
	if [ ! -e $DISKIMG ]; then
	  catch create
	fi
	
	# try to close a previous
	(umount 2>&1 >/dev/null)
	
	# set the disk image password
	#  (actually, the password for the LUKS master password, but in
	#  daily use this is the one you think of as your "disk password")
	# we use the LUKS UUID as the hashapass parameter, so we need to
	# set the key *after* the luks container has been made, which means
	# setting a dummy password and then changing it.
	echo "password" | catch cryptsetup luksFormat --cipher twofish "${DISKIMG}" || exit 1
	
	DISKID=$(catch diskid) || exit 1
	KEY=$(hashapass -s ${DISKID}) &&
	#echo "KEY="$KEY >/dev/stderr && #DEBUG
	(echo password; echo $KEY) | cryptsetup luksChangeKey ${DISKIMG} &&  #subtley: the subshell "(..)" effectively lets us pipe two lines into cryptsetup instead of just one
	#echo "successfully changed luks key" >/dev/stderr #DEBUG
	
	#echo sudo open --type luks "${DISKIMG}" "${DISKID}" >/dev/stderr #DEBUG
  echo ${KEY} | catch sudo cryptsetup open --type luks "${DISKIMG}" "${DISKID}" || exit 1
	
	# mkfs
	read -p "Enter new filesystem label: " LABEL
	#echo "successfully read LABEL: $LABEL" >/dev/stderr #DEBUG 
	catch sudo mkfs.ext4 -L ${LABEL} /dev/mapper/$DISKID #<--note that we mkfs on the mapped device
	                                                     #   not the file. the kernel lets you do either
	                                                     #   but gets unapologetically confused on the other
	#echo "successfully formatted" >/dev/stderr #DEBUG
	
	# set up default permissions to be usable
	if [ ! -d ${MNT} ]; then
		catch mkdir ${MNT};
	fi
	catch sudo mount /dev/mapper/$DISKID ${MNT}
	catch sudo chown -R $USER ${MNT}
	catch sudo chgrp -R users ${MNT}
	catch sudo chmod -R 700 ${MNT} #again, only the user has access. tho we also tweak the group to the standard one everyone is in to make it 
	#(echo "Successfully initialized new drive's permissions:" && ls -ld ${MNT}) >/dev/stderr && #DEBUG
	catch sudo umount ${MNT}
	catch sudo cryptsetup close "${DISKID}"
	
	rmdir ${MNT} # it is alright if this one fails
}

mount() {
	#DISKIMG=$1; shift
	#echo "mount($DISKIMG)" >/dev/stderr #DEBUG

	DISKID=$(catch diskid) || exit 1
	
	KEY=$(hashapass -s ${DISKID}) &&
	#echo "KEY="$KEY >/dev/stderr && #DEBUG
	echo ${KEY} | catch sudo cryptsetup open --type luks "${DISKIMG}" "${DISKID}" || exit 1
	
  if [ ! -d ${MNT} ]; then
		mkdir ${MNT};
	fi &&
	catch sudo mount /dev/mapper/$DISKID ${MNT}
}


umount() {
	#DISKIMG=$1; shift
	#echo "umount($DISKIMG)" >/dev/stderr #DEBUG
	
	catch sudo umount "${MNT}"
	
	DISKID=$(catch diskid) || exit 1
	catch sudo cryptsetup close $DISKID
	
	rmdir "${MNT}" #again, it's not a disaster if this fails
}


main() {
  if [ $CMD == "mount" ]; then
    mount
  elif [ $CMD == "umount" ]; then
    umount
  elif [ $CMD == "format" ]; then
    format
  else
    usage
  fi
}

main
