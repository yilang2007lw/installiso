#!/bin/bash
# Author: long wei

ISOPATH="*.iso"
USERNAME="linux"
PASSWORD="123456"
TIMEZONE="Asia/Shanghai"
LOCALE="zh_CN.UTF-8"
HOST="linux-pc"
ROOTPATH="/dev/sda1"
HOMEPATH=""
GRUBPATH="/dev/sda"
FORMATROOT="false"

MOUNT_ISO="/mnt/iso/$RANDOM"
SQUASHFS_DEST="/mnt/squashfs/$RANDOM"
ROOT_TARGET="/mnt/root/$RANDOM"

ROOT_UUID=""
ROOT_TYPE=""
HOME_UUID=""
HOME_TYPE=""

usage()
{
	echo "
Usage: 
    installiso.sh [OPTION]

Options:
    -i <iso>			specify iso to install
    -u <username>		specify username for target os
    -p <password>		specicy password for target os
    -t <timezone>		specify timezone for target os
    -l <locale>			specify locale for target os
    -n <hostname>		specify hostname for target os
    -r <root>			specify / mount partition
    -m <home>			specify /home mount partition
    -g <grub>			specify grub install location
    -f                  format root partition
    -h 				    show help
	"
}

parse_opt()
{
	while getopts "i:u:p:t:l:n:r:m:g:fh" opt
	do
		case "$opt" in
		i)
			ISOPATH=$OPTARG;;
		u)
			USERNAME=$OPTARG;;
		p)
			PASSWORD=$OPTARG;;
		t)
			TIMEZONE=$OPTARG;;
		l)
			LOCALE=$OPTARG;;
		n)
			HOST=$OPTARG;;
		r)
			ROOTPATH=$OPTARG;;
		m)
			HOMEPATH=$OPTARG;;
		g)
			GRUBPATH=$OPTARG;;
		f)
			FORMATROOT="true";;
		h)
			usage
			exit 0;;
		*)
			usage
			return 1
		esac
	done
}

check_requirements()
{
	if [ $UID -ne 0 ]; then
		echo "Need run as root"
		exit 1
	fi

	if [ ! -f $ISOPATH ]; then
		echo "Invalid isopath:" $ISOPATH
		usage
		exit 1
	fi

	if [ ! -b $ROOTPATH ]; then
		echo "Invalid root path:" $ROOTPATH
		usage
		exit 1
	fi

	if [ ! -z $HOMEPATH ] && [ ! -b $HOMEPATH ] ; then
		echo "Invalid home path:" $HOMEPATH
		usage
		exit 1
	fi

	if [ X`df -h |grep $ROOTPATH | awk '{print $6}'`Y == X/Y ]; then
		echo "$ROOTPATH already mounted on /, please select another partition"
		usage
		exit 1
	fi

	ROOT_UUID=`blkid $ROOTPATH | awk '{print $2}'`
	ROOT_TYPE=`blkid $ROOTPATH | awk '{print $3}' | awk -F'"' '{print $2}'`

	if [ ! -z $HOMEPATH ]; then
		HOME_UUID=`blkid $HOMEPATH | awk '{print $2}'`
		HOME_TYPE=`blkid $HOMEPATH | awk '{print $3}' | awk -F'"' '{print $2}'`
	fi

	echo "Disk requirements satisfied"
	if [ X`which unsquashfs` == X ]; then
		echo "Need install squashfs-tools"
		exit 1
	fi
	if [ $FORMATROOT == "true" ] ; then
		eval "mkfs.$ROOT_TYPE $ROOTPATH"
	fi
}

ensure_directory()
{
	echo "Ensure directory"
	if [ -d $MOUNT_ISO ] ; then
		umount -l $MOUNT_ISO
		rm -rf $MOUNT_ISO
	fi
	mkdir -p $MOUNT_ISO

	if [ -d $ROOT_TARGET ]; then
		rm -rf $ROOT_TARGET
	fi
	mkdir -p $ROOT_TARGET

	if [ -d $SQUASHFS_DEST ]; then
		rm -rf $SQUASHFS_DEST
	fi

	if [ ! -d "/mnt/squashfs" ]; then
		mkdir -p /mnt/squashfs
	fi
}

install_squashfs()
{
	echo "Install squashfs"
	mount -t iso9660 -o loop $ISOPATH $MOUNT_ISO
	if [ ! -f $MOUNT_ISO/casper/filesystem.squashfs ]; then
		echo "Invalid ISO: filesystem.squashfs not found"
		clean_up
		exit
	fi

	echo "mount -t $ROOT_TYPE $ROOTPATH $ROOT_TARGET"
	mount -t $ROOT_TYPE $ROOTPATH $ROOT_TARGET
	if [ ! -z $HOMEPATH ]; then
		mount -t $HOME_TYPE $HOMEPATH $ROOT_TARGET/home	
	fi

	echo "Begin unsquashfs $MOUNT_ISO/casper/filesystem.squashfs to $SQUASHFS_DEST"
	unsquashfs -d $SQUASHFS_DEST $MOUNT_ISO/casper/filesystem.squashfs
	if [ $? -ne 0 ]; then
		echo "Unsquashfs failed"
		clean_up
		exit
	fi

	echo "Copy os to target, please wait......"
	cp -a $SQUASHFS_DEST/* $ROOT_TARGET
	echo "Copy os to target finish."
}

install_kernel()
{
	echo "Install kernel"
	cd_kernel=""
	prefix=""
	for prefix in "vmlinux" "vmlinuz"; do
		for suffix in "" ".efi" ".efi.signed"; do
			if [ -f $MOUNT_ISO/casper/$prefix$suffix ]; then
				cd_kernel=$prefix$suffix	
				break 2
			fi
		done
	done
	cd_kernel_path=$MOUNT_ISO/casper/$cd_kernel
	echo "cd kernel path: $cd_kernel_path"

	release=`ls $ROOT_TARGET/boot/ | grep 'config-' | cut -c 8-`
	target_kernel=$prefix-$release
	target_kernel_path=$ROOT_TARGET/boot/$target_kernel
	echo "target kernel path: $target_kernel_path"
	
	cp $cd_kernel_path $target_kernel_path 
}

write_fstab()
{
	echo "Write fstab"
	if [ -f $ROOT_TARGET/etc/fstab ]; then
		rm -rf $ROOT_TARGET/etc/fstab
	fi
	
	cat > $ROOT_TARGET/etc/fstab <<"EOF"
# /etc/fstab: static file system information.
#
# Use 'blkid' to print the universally unique identifier for a
# device; this may be used with UUID= as a more robust way to name devices
# that works even if disks are added and removed. See fstab(5).
#
# <file system> <mount point>   <type>  <options>       <dump>  <pass>
EOF

	echo "# / was on $ROOTPATH during installation" >> $ROOT_TARGET/etc/fstab
	echo "$ROOT_UUID	/	$ROOT_TYPE	errors=remount-ro	0	1" >> $ROOT_TARGET/etc/fstab
	
	if [ ! -z $HOMEPATH ]; then
		echo "# /home was on $HOMEPATH during installation" >> $ROOT_TARGET/etc/fstab
		echo "$HOME_UUID	/home	$HOME_TYPE	defaults	0	2" >> $ROOT_TARGET/etc/fstab
	fi
	
	if [ `cat /proc/swaps | wc -l` -eq 2 ]; then
		local swap=`cat /proc/swaps | sed -n '2p' | awk '{print $1}'`	
		local swap_uuid=`blkid $swap | awk '{print $2}'`
		echo "# swap was on $swap during installation" >> $ROOT_TARGET/etc/fstab
		echo "$swap_uuid	none	swap	sw	0	0" >> $ROOT_TARGET/etc/fstab
	fi
}

set_hostname()
{
	echo "Set hostname"
	echo "$HOST" > $ROOT_TARGET/etc/hostname
	echo -e "127.0.1.1	$HOST" > $ROOT_TARGET/etc/hosts
	cat >> $ROOT_TARGET/etc/hosts << "EOF"
127.0.0.1	localhost

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF
}

set_timezone()
{
	echo "Set timezone"
	echo $TIMEZONE > $ROOT_TARGET/etc/timezone
}

set_keyboard_layout()
{
	echo "Set keyboard layout"
	cat > $ROOT_TARGET/etc/default/keyboard << "EOF"
# Check /usr/share/doc/keyboard-configuration/README.Debian for
# documentation on what to do after having modified this file.

# The following variables describe your keyboard and can have the same
# values as the XkbModel, XkbLayout, XkbVariant and XkbOptions options
# in /etc/X11/xorg.conf.

XKBMODEL="pc105"
XKBLAYOUT="cn"
XKBVARIANT=""
XKBOPTIONS=""
EOF
}

set_locale()
{
	echo "Set locale"
	echo "LANG=\"$LOCALE\"" > $ROOT_TARGET/etc/default/locale
	local language=`echo $LOCALE | awk -F"." '{print $1}'`
	echo "LANGUAGE=\"$language\"" >> $ROOT_TARGET/etc/default/locale
	#echo "LC_ALL=\"C\"" >> $ROOT_TARGET/etc/default/locale
}

do_chroot_set()
{
	echo "Chroot set locale"
	chroot $ROOT_TARGET /bin/bash -c "locale-gen $LOCALE"
	chroot $ROOT_TARGET /bin/bash -c "update-locale"

	echo "Chroot create user"
	chroot $ROOT_TARGET /bin/bash -c "groupadd $USERNAME"
	chroot $ROOT_TARGET /bin/bash -c "useradd -s /bin/bash -m -k /etc/skel -g $USERNAME $USERNAME"
	chroot $ROOT_TARGET /bin/bash -c "echo \"$USERNAME:$PASSWORD\" | chpasswd"

	allgroups=`cat $ROOT_TARGET/etc/group |awk -F':' '{print $1}'`
	dgroups="adm cdrom sudo dip plugdev lpadmin sambashare"
	groups=""
	for ag in $allgroups; do
		for dg in $dgroups; do
			if [ $dg == $ag ]; then
				groups=$groups" "$ag
			fi
		done
	done
	echo "add user to groups:$groups"
	trimmed=`echo $groups | tr " " ,`
	chroot $ROOT_TARGET /bin/bash -c "usermod -a -G $trimmed $USERNAME"

	echo "Chroot set grub"
	chroot $ROOT_TARGET /bin/bash -c "update-initramfs -u"
	chroot $ROOT_TARGET /bin/bash -c "grub-install $GRUBPATH"
	chroot $ROOT_TARGET /bin/bash -c "update-grub2"
}

clean_up()
{
	echo "Clean up"
	while [ `mount |grep -c $MOUNT_ISO` -ne 0 ]
	do
		umount -l $MOUNT_ISO
	done

	if [ -d $MOUNT_ISO ] ;then
		rm -rf $MOUNT_ISO
	fi

	if [ -d $SQUASHFS_DEST ]; then
		rm -rf $SQUASHFS_DEST	
	fi

	while [ $(mount | grep -c $ROOT_TARGET/proc) != '0' ]
	do
		umount -l $ROOT_TARGET/proc
		sleep 1
	done
	while [ $(mount | grep -c $ROOT_TARGET/sys) != '0' ]
	do
		umount -l $ROOT_TARGET/sys
		sleep 1
	done
	while [ $(mount | grep -c $ROOT_TARGET/dev/pts) != '0' ]
	do
		umount -l $ROOT_TARGET/dev/pts
		sleep 1
	done
	while [ $(mount | grep -c $ROOT_TARGET/dev) != '0' ]
	do
		umount -l $ROOT_TARGET/dev
		sleep 1
	done
	while [ $(mount | grep -c $ROOT_TARGET) != '0' ]
	do
		umount -l $ROOT_TARGET
		sleep 1
	done

	if [ -d $ROOT_TARGET ]; then
		rm -rf $ROOT_TARGET
	fi
}

main()
{
	parse_opt $@
	check_requirements
	ensure_directory
	install_squashfs
	install_kernel
	write_fstab
	set_hostname
	set_timezone
	set_keyboard_layout
	set_locale

	mount --bind /dev $ROOT_TARGET/dev
	mount -t proc none $ROOT_TARGET/proc
	mount -t sysfs none $ROOT_TARGET/sys
	mount -t devpts	none $ROOT_TARGET/dev/pts 

	do_chroot_set

	clean_up
	echo "Install finish, please restart your system"
}

main $@
