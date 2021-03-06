#!/bin/sh

create_default_config()
{
	local _HOSTNAME;
	local _EMAIL_DOMAIN;

	echo "editing prefs"
	_HOSTNAME=$(dialog --stdout --nocancel --backtitle "mail-toaster.sh" --title TOASTER_HOSTNAME --inputbox "the hostname of this [virtual] machine" 8 70 "mail.example.com")
	_EMAIL_DOMAIN=$(dialog --stdout --nocancel --backtitle "mail-toaster.sh" --title TOASTER_MAIL_DOMAIN --inputbox "the primary email domain" 8 70 "example.com")

	# for Travis CI (Linux) where dialog doesn't exist
	if [ -z "$_HOSTNAME"     ]; then _HOSTNAME=$(hostname); fi
	if [ -z "$_EMAIL_DOMAIN" ]; then _EMAIL_DOMAIN=$(hostname); fi

	echo "creating mail-toaster.conf with defaults"
	tee mail-toaster.conf <<EO_MT_CONF
export TOASTER_HOSTNAME="$_HOSTNAME"
export TOASTER_MAIL_DOMAIN="$_EMAIL_DOMAIN"
export TOASTER_ADMIN_EMAIL="postmaster@${_EMAIL_DOMAIN}"
export TOASTER_SRC_URL="https://raw.githubusercontent.com/msimerson/Mail-Toaster-6/master"

export JAIL_NET_PREFIX="172.16.15"
export JAIL_NET_MASK="/12"
export JAIL_NET_INTERFACE="lo1"
export JAIL_STARTUP_LIST="dns mysql vpopmail dovecot webmail haproxy clamav avg redis rspamd geoip spamassassin haraka monitor"
export ZFS_VOL="zroot"
export ZFS_JAIL_MNT="/jails"
export ZFS_DATA_MNT="/data"
export TOASTER_MYSQL="1"
export TOASTER_MARIADB="0"
export TOASTER_PKG_AUDIT="0"
export SQUIRREL_SQL="1"

EO_MT_CONF
}

config()
{
	if [ ! -f "mail-toaster.conf" ]; then
		create_default_config
	fi

	echo "loading mail-toaster.conf"
	# shellcheck disable=SC1091,SC2039
	. mail-toaster.conf
}

# load the local config file
config

# Required settings
export TOASTER_HOSTNAME=${TOASTER_HOSTNAME:="mail.example.com"} || exit
export TOASTER_MAIL_DOMAIN=${TOASTER_MAIL_DOMAIN:="example.com"}
export TOASTER_ADMIN_EMAIL=${TOASTER_ADMIN_EMAIL:="postmaster@$TOASTER_MAIL_DOMAIN"}
export TOASTER_SRC_URL=${TOASTER_SRC_URL:="https://raw.githubusercontent.com/msimerson/Mail-Toaster-6/master"}

# export these in your environment to customize
export BOURNE_SHELL=${BOURNE_SHELL:="bash"}
export JAIL_NET_PREFIX=${JAIL_NET_PREFIX:="172.16.15"}
export JAIL_NET_MASK=${JAIL_NET_MASK:="/12"}
export JAIL_NET_INTERFACE=${JAIL_NET_INTERFACE:="lo1"}
export JAIL_STARTUP_LIST=${JAIL_STARTUP_LIST:="dns mysql vpopmail dovecot webmail roundcube haproxy clamav avg redis rspamd geoip spamassassin haraka monitor"}
export JAIL_ORDERED_LIST="syslog base dns mysql clamav spamassassin dspam vpopmail haraka webmail monitor haproxy rspamd avg dovecot redis geoip nginx lighttpd apache postgres minecraft joomla php7 memcached sphinxsearch elasticsearch nictool sqwebmail dhcp letsencrypt tinydns roundcube squirrelmail rainloop rsnapshot mediawiki smf wordpress whmcs squirrelcart horde grafana unifi mongodb"

export ZFS_VOL=${ZFS_VOL:="zroot"}
export ZFS_JAIL_MNT=${ZFS_JAIL_MNT:="/jails"}
export ZFS_DATA_MNT=${ZFS_DATA_MNT:="/data"}
export FBSD_MIRROR=${FBSD_MIRROR:="ftp://ftp.freebsd.org"}

# See https://github.com/msimerson/Mail-Toaster-6/wiki/MySQL
export TOASTER_MYSQL=${TOASTER_MYSQL:="1"}
export TOASTER_MARIADB=${TOASTER_MARIADB:="0"}
export SQUIRREL_SQL=${SQUIRREL_SQL:="1"}
export TOASTER_NTP=${TOASTER_NTP:="ntp"}

if [ "$TOASTER_MYSQL" = "1" ]; then
	echo "mysql enabled"
fi

usage() {
	echo; echo "Next step, edit mail-toaster.conf!"; echo
	echo "See: https://github.com/msimerson/Mail-Toaster-6/wiki/FreeBSD"; echo
	exit
}
if [ "$TOASTER_HOSTNAME" = "mail.example.com" ]; then usage; fi
echo "toaster host: $TOASTER_HOSTNAME"

if [ "$TOASTER_MAIL_DOMAIN" = "example.com" ]; then usage; fi
echo "email domain: $TOASTER_MAIL_DOMAIN"

# shellcheck disable=2009
if ps -o args= -p "$$" | grep csh; then usage; fi
echo "shell: $SHELL"

# little below here should need customizing. If so, consider opening
# an issue or PR at https://github.com/msimerson/Mail-Toaster-6
export ZFS_JAIL_VOL="${ZFS_VOL}${ZFS_JAIL_MNT}"
export ZFS_DATA_VOL="${ZFS_VOL}${ZFS_DATA_MNT}"

export FBSD_REL_VER FBSD_PATCH_VER
FBSD_REL_VER=$(/bin/freebsd-version | /usr/bin/cut -f1-2 -d'-')
FBSD_PATCH_VER=$(/bin/freebsd-version | /usr/bin/cut -f3 -d'-')
FBSD_PATCH_VER=${FBSD_PATCH_VER:="p0"}

# the 'base' jail that other jails are cloned from. This will be named as the
# host OS version, ex: base-11.0-RELEASE and the snapshot name will be the OS
# patch level, ex: base-11.0-RELEASE@p3
export BASE_NAME="base-$FBSD_REL_VER"
export BASE_VOL="$ZFS_JAIL_VOL/$BASE_NAME"
export BASE_SNAP="${BASE_VOL}@${FBSD_PATCH_VER}"
export BASE_MNT="$ZFS_JAIL_MNT/$BASE_NAME"

export STAGE_MNT="$ZFS_JAIL_MNT/stage"

fatal_err() {
	echo; echo "FATAL: $1"; echo; exit
}

safe_jailname()
{
	# constrain jail name chars to alpha-numeric and _
	echo "$1" | sed -e 's/[^a-zA-Z0-9]/_/g'
}

export SAFE_NAME; SAFE_NAME=$(safe_jailname stage)
if [ -z "$SAFE_NAME" ]; then echo "unset SAFE_NAME"; exit; fi
echo "safe name: $SAFE_NAME"

zfs_filesystem_exists()
{
	if zfs list -t filesystem "$1" 2>/dev/null | grep -q "^$1"; then
		tell_status "$1 filesystem exists"
		return 0
	fi

	return 1
}

zfs_snapshot_exists()
{
	if zfs list -t snapshot "$1" 2>/dev/null | grep -q "$1"; then
		echo "$1 snapshot exists"
		return 0
	else
		return 1
	fi
}

zfs_mountpoint_exists()
{
	if zfs list -t filesystem "$1" 2>/dev/null | grep -q "$1\$"; then
		echo "$1 mountpoint exists"
		return 0
	fi

	return 1
}

zfs_create_fs() {

	if zfs_filesystem_exists "$1"; then return; fi
	if zfs_mountpoint_exists "$2"; then return; fi

	tell_status "creating data volume"
	if echo "$1" | grep "$ZFS_DATA_VOL"; then
		if ! zfs_filesystem_exists "$ZFS_DATA_VOL"; then
			tell_status "zfs create -o mountpoint=$ZFS_DATA_MNT $ZFS_DATA_VOL"
			zfs create -o mountpoint="$ZFS_DATA_MNT" "$ZFS_DATA_VOL"  || exit
		fi
	fi

	if echo "$1" | grep "$ZFS_JAIL_VOL"; then
		if ! zfs_filesystem_exists "$ZFS_JAIL_VOL"; then
			tell_status "zfs create -o mountpoint=$ZFS_JAIL_MNT $ZFS_JAIL_VOL"
			zfs create -o mountpoint="$ZFS_JAIL_MNT" "$ZFS_JAIL_VOL"  || exit
		fi
	fi

	if [ -z "$2" ]; then
		tell_status "zfs create $1"
		zfs create "$1" || exit
		echo "done"
		return
	fi

	tell_status "zfs create -o mountpoint=$2 $1"
	zfs create -o mountpoint="$2" "$1"  || exit
	echo "done"
}

zfs_destroy_fs()
{
	if ! zfs_filesystem_exists "$1"; then return; fi
	if [ -n "$2" ]; then
		echo "zfs destroy $2 $1"
		zfs destroy "$2" "$1" || exit
	else
		echo "zfs destroy $1"
		zfs destroy "$1" || exit
	fi
}

base_snapshot_exists()
{
	if zfs_snapshot_exists "$BASE_SNAP"; then
		return 0
	fi

	echo "$BASE_SNAP does not exist, use 'provision base' to create it"
	return 1
}

jail_conf_header()
{
	if [ -e /etc/jail.conf ]; then return; fi

	tell_status "adding /etc/jail.conf header"
	tee -a /etc/jail.conf <<EO_JAIL_CONF_HEAD

exec.start = "/bin/sh /etc/rc";
exec.stop = "/bin/sh /etc/rc.shutdown";
exec.clean;
mount.devfs;
path = "$ZFS_JAIL_MNT/\$name";
interface = $JAIL_NET_INTERFACE;
host.hostname = \$name;

EO_JAIL_CONF_HEAD
}

get_jail_ip()
{
	local _start=${JAIL_NET_START:=1}

	case "$1" in
		syslog) echo "$JAIL_NET_PREFIX.$_start";   return;;
		base)   echo "$JAIL_NET_PREFIX.$((_start + 1))";   return;;
		stage)  echo "$JAIL_NET_PREFIX.254"; return;;
	esac

	if echo "$1" | grep -q ^base; then
		echo "$JAIL_NET_PREFIX.$((_start + 1))"
		return
	fi

	local _octet="$_start"

	for j in $JAIL_ORDERED_LIST
	do
		if [ "$1" = "$j" ]; then
			echo "$JAIL_NET_PREFIX.$_octet"
			return
		fi
		_octet=$((_octet + 1))
	done

	# return error code if _incr unset
	return 2
}

get_reverse_ip()
{
	local _jail_ip; _jail_ip=$(get_jail_ip "$1")
	if [ -z "$_jail_ip" ]; then
		echo "unknown jail: $1"
		exit
	fi

	local _rev_ip
	_rev_ip=$(echo "$_jail_ip" | awk '{split($1,a,".");printf("%s.%s.%s.%s",a[4],a[3],a[2],a[1])}')
	echo "$_rev_ip.in-addr.arpa"
}

add_jail_conf()
{
	local _jail_ip; _jail_ip=$(get_jail_ip "$1");
	if [ -z "$_jail_ip" ]; then
		fatal_err "can't determine IP for $1"
	fi

	jail_conf_header

	if grep -q "^$1" /etc/jail.conf; then
		tell_status "$1 already in /etc/jail.conf"
		return;
	fi

	local _path=""
	local _safe; _safe=$(safe_jailname "$1")
	if [ "$1" != "$_safe" ]; then
		_path="
		path = $ZFS_JAIL_MNT/${1};"
	fi

	if [ -z "$JAIL_CONF_EXTRA" ]; then
		JAIL_CONF_EXTRA="mount += \"$ZFS_DATA_MNT/$1 \$path/data nullfs rw 0 0\";"
	fi

	tell_status "adding $1 to /etc/jail.conf"
	tee -a /etc/jail.conf <<EO_JAIL_CONF

$1	{
		ip4.addr = $JAIL_NET_INTERFACE|${_jail_ip};${_path}
		${JAIL_CONF_EXTRA}
	}
EO_JAIL_CONF
}

stop_jail()
{
	local _safe; _safe=$(safe_jailname "$1")
	echo "service jail stop $_safe"
	service jail stop "$_safe"

	echo "jail -r $_safe"
	jail -r "$_safe" 2>/dev/null
}

stage_unmount()
{
	stage_unmount_dev
	unmount_ports "$STAGE_MNT"
	unmount_pkg_cache
	unmount_data "$1"
	stage_unmount_aux_data "$1"
}

cleanup_staged_fs()
{
	tell_status "stage cleanup"
	stop_jail stage
	stage_unmount "$1"
	zfs_destroy_fs "$ZFS_JAIL_VOL/stage" -f
}

assure_data_volume_mount_is_declared()
{
	if ! grep -qs "^$1" /etc/jail.conf; then
		# config for this jail hasn't been created. It's created
		# when the data FS is provisioned.
		return
	fi

	if grep -qs "data/$1" /etc/jail.conf; then
		# data fs mountpoint already declared
		return
	fi

	local _mp; _mp=$(data_mountpoint "$1" "\$path")
	tell_status "roadblock: UPGRADE action required"
	echo
	echo "You MUST add this line to the $1 section in /etc/jail.conf to continue:"
	echo
	echo "	mount += \"/data/$1 $_mp nullfs rw 0 0\";"
	echo
	exit
}

create_staged_fs()
{
	cleanup_staged_fs "$1"

	tell_status "stage jail filesystem setup"
	echo "zfs clone $BASE_SNAP $ZFS_JAIL_VOL/stage"
	zfs clone "$BASE_SNAP" "$ZFS_JAIL_VOL/stage" || exit

	stage_sysrc hostname="$1"
	sed -i -e "/^hostname=/ s/_HOSTNAME_/$1/" \
		"$STAGE_MNT/usr/local/etc/ssmtp/ssmtp.conf" || exit

	assure_data_volume_mount_is_declared "$1"

	zfs_create_fs "$ZFS_DATA_VOL/$1" "$ZFS_DATA_MNT/$1"
	mount_data "$1" "$STAGE_MNT"

	stage_mount_ports
	stage_mount_pkg_cache
	echo
}

stage_unmount_aux_data()
{
	case $1 in
		spamassassin)  unmount_data geoip ;;
		haraka)        unmount_data geoip ;;
		whmcs )        unmount_data geoip ;;
	esac
}

stage_mount_aux_data() {
	case $1 in
		spamassassin )  mount_data geoip ;;
		haraka )        mount_data geoip ;;
		whmcs )         mount_data geoip ;;
	esac
}

start_staged_jail()
{
	local _name="$1"
	local _path="$2"

	if [ -z "$_name" ]; then _name="$SAFE_NAME"; fi
	if [ -z "$_path" ]; then _path="$STAGE_MNT"; fi

	tell_status "stage jail $_name startup"

	# shellcheck disable=2086
	jail -c \
		name=stage \
		host.hostname="$_name" \
		path="$_path" \
		interface="$JAIL_NET_INTERFACE" \
		ip4.addr="$(get_jail_ip stage)" \
		exec.start="/bin/sh /etc/rc" \
		exec.stop="/bin/sh /etc/rc.shutdown" \
		mount.devfs \
		$JAIL_START_EXTRA \
		|| exit

	stage_mount_aux_data "$_name"

	pkg -j stage update
}

rename_staged_to_ready()
{
	local _new_vol="$ZFS_JAIL_VOL/${1}.ready"

	# remove stages that failed promotion
	zfs_destroy_fs "$_new_vol"

	# get the wait over with before shutting down production jail
	local _tries=0
	local _zfs_rename="zfs rename $ZFS_JAIL_VOL/stage $_new_vol"
	echo "$_zfs_rename"
	until $_zfs_rename; do
		if [ "$_tries" -gt 25 ]; then
			echo "trying to force rename"
			_zfs_rename="zfs rename -f $ZFS_JAIL_VOL/stage $_new_vol"
		fi
		echo "waiting for ZFS filesystem to quiet ($_tries)"
		_tries=$((_tries + 1))
		sleep 5
	done
}

rename_active_to_last()
{
	local ACTIVE="$ZFS_JAIL_VOL/$1"
	local LAST="$ACTIVE.last"

	zfs_destroy_fs "$LAST"

	if ! zfs_filesystem_exists "$ACTIVE"; then return; fi

	local _tries=0
	local _zfs_rename="zfs rename $ACTIVE $LAST"
	echo "$_zfs_rename"
	until $_zfs_rename; do
		if [ $_tries -gt 5 ]; then
			echo "trying to force rename ($_tries)"
			_zfs_rename="zfs rename -f $ACTIVE $LAST"
		fi
		echo "waiting for ZFS filesystem to quiet ($_tries)"
		_tries=$((_tries + 1))
		sleep 5
	done
}

rename_ready_to_active()
{
	echo "zfs rename $ZFS_JAIL_VOL/${1}.ready $ZFS_JAIL_VOL/$1"
	zfs rename "$ZFS_JAIL_VOL/${1}.ready" "$ZFS_JAIL_VOL/$1" || exit
}

tell_status()
{
	echo; echo "   ***   $1   ***"; echo
	sleep 1
}

proclaim_success()
{
	echo; echo "Success! A new '$1' jail is provisioned"; echo
}

stage_clear_caches()
{
	echo "clearing pkg cache"
	rm -rf "$STAGE_MNT/var/cache/pkg/*"
}

stage_resolv_conf()
{
	local _nsip; _nsip=$(get_jail_ip dns)
	echo "nameserver $_nsip" | tee "$STAGE_MNT/etc/resolv.conf"
}

seed_pkg_audit()
{
	if [ "$TOASTER_PKG_AUDIT" = "1" ]; then
		tell_status "installing FreeBSD package audit database"
		stage_exec /usr/sbin/pkg audit -F
	fi
}

promote_staged_jail()
{
	seed_pkg_audit
	tell_status "promoting jail $1"
	stop_jail stage
	stage_resolv_conf
	stage_unmount "$1"
	ipcrm -W
	#stage_clear_caches

	rename_staged_to_ready "$1"

	stop_jail "$1"
	unmount_data "$1" "$ZFS_JAIL_MNT/$1"
	unmount_ports "$ZFS_JAIL_MNT/$1"

	rename_active_to_last "$1"
	rename_ready_to_active "$1"
	add_jail_conf "$1"

	tell_status "service jail start $1"
	service jail start "$1" || exit
	proclaim_success "$1"
}

stage_pkg_install()
{
	echo "pkg -j $SAFE_NAME install -y $*"
	pkg -j "$SAFE_NAME" install -y "$@"
}

stage_sysrc()
{
	# don't use -j as this is oft called when jail is not running
	echo "sysrc -R $STAGE_MNT $*"
	sysrc -R "$STAGE_MNT" "$@"
}

stage_make_conf()
{
	if grep -s "$1" "$STAGE_MNT/etc/make.conf"; then
		echo "preserving make.conf settings"
		return
	fi

	tell_status "setting $1 make.conf options"
	echo "$2" | tee -a "$STAGE_MNT/etc/make.conf" || exit
}

stage_exec()
{
	echo "jexec $SAFE_NAME $*"
	jexec "$SAFE_NAME" "$@"
}

stage_listening()
{
	echo "checking for port $1 listener in staged jail"
	sockstat -l -4 -6 -p "$1" -j "$(jls -j stage jid)" | grep -v PROTO || exit
}

stage_test_running()
{
	echo "checking for process $1 in staged jail"
	pgrep -j stage "$1" || exit
}

stage_mount_ports()
{
	echo "mount $STAGE_MNT/usr/ports"
	mount_nullfs /usr/ports "$STAGE_MNT/usr/ports" || exit
}

stage_mount_pkg_cache()
{
	echo "mount $STAGE_MNT/var/cache/pkg"
	mount_nullfs /var/cache/pkg "$STAGE_MNT/var/cache/pkg" || exit
}

unmount_ports()
{
	if [ ! -d "$1/usr/ports/mail" ]; then
		return
	fi

	if ! mount -t nullfs | grep -q "$1"; then
		return
	fi

	echo "unmount $1/usr/ports"
	umount "$1/usr/ports" || exit
}

unmount_pkg_cache()
{
	if ! mount -t nullfs | grep -q "$STAGE_MNT/var/cache/pkg"; then
		return
	fi

	echo "unmount $STAGE_MNT/var/cache/pkg"
	umount "$STAGE_MNT/var/cache/pkg" || exit
}

freebsd_release_url_base()
{
	echo "$FBSD_MIRROR/pub/FreeBSD/releases/$(uname -m)/$FBSD_REL_VER"
}

stage_fbsd_package()
{
	local _dest="$2"
	if [ -z "$_dest" ]; then _dest="$STAGE_MNT"; fi

	tell_status "downloading FreeBSD package $1"
	fetch -m "$(freebsd_release_url_base)/$1.txz" || exit
	echo "done"

	tell_status "extracting FreeBSD package $1.tgz to $_dest"
	tar -C "$_dest" -xpJf "$1.txz" || exit
	echo "done"
}

mount_data()
{
	local _data_vol; _data_vol="$ZFS_DATA_VOL/$1"

	if ! zfs_filesystem_exists "$_data_vol"; then
		echo "no $_data_vol to mount"
		return
	fi

	local _data_mnt; _data_mnt="$ZFS_DATA_MNT/$1"
	local _data_mp;  _data_mp=$(data_mountpoint "$1" "$2")

	if [ ! -d "$_data_mp" ]; then
		echo "mkdir -p $_data_mp"
		mkdir -p "$_data_mp" || exit
	fi

	if mount -t nullfs | grep "$_data_mp"; then
		echo "$_data_mp already mounted!"
		return
	fi

	echo "mount_nullfs $_data_mnt $_data_mp"
	mount_nullfs "$_data_mnt" "$_data_mp" || exit
}

unmount_data()
{
	local _data_vol; _data_vol="$ZFS_DATA_VOL/$1"

	if ! zfs_filesystem_exists "$_data_vol"; then return; fi

	local _data_mp=; _data_mp=$(data_mountpoint "$1" "$2")

	if mount -t nullfs | grep "$_data_mp"; then
		echo "unmount data fs $_data_mp"
		umount -t nullfs "$_data_mp"
	fi
}

data_mountpoint()
{
	local _base_dir="$2"
	if [ -z "$_base_dir" ]; then
		_base_dir="$STAGE_MNT"  # default to stage
	fi

	case $1 in
		avg )       echo "$_base_dir/data/avg"; return ;;
		clamav )	echo "$_base_dir/var/db/clamav"; return ;;
		geoip )     echo "$_base_dir/usr/local/share/GeoIP"; return ;;
		mysql )     echo "$_base_dir/var/db/mysql"; return ;;
		vpopmail )  echo "$_base_dir/usr/local/vpopmail"; return ;;
	esac

	echo "$_base_dir/data"
}

stage_unmount_dev()
{
	if ! mount -t devfs | grep -q "$STAGE_MNT/dev"; then
		return
	fi
	echo "umount $STAGE_MNT/dev"
	umount "$STAGE_MNT/dev" || exit
}

get_public_facing_nic()
{
	export PUBLIC_NIC

	if [ "$1" = 'ipv6' ]; then
		PUBLIC_NIC=$(netstat -rn | grep default | awk '{ print $4 }' | tail -n1)
	else
		PUBLIC_NIC=$(netstat -rn | grep default | awk '{ print $4 }' | head -n1)
	fi

	if [ -z "$PUBLIC_NIC" ];
	then
		echo "public NIC detection failed"
		exit 1
	fi
}

get_public_ip()
{
	get_public_facing_nic "$1"

	export PUBLIC_IP6
	export PUBLIC_IP4

	if [ "$1" = 'ipv6' ]; then
		PUBLIC_IP6=$(ifconfig "$PUBLIC_NIC" | grep 'inet6' | grep -v fe80 | awk '{print $2}' | head -n1)
	else
		PUBLIC_IP4=$(ifconfig "$PUBLIC_NIC" | grep 'inet ' | awk '{print $2}' | head -n1)
	fi
}

mysql_db_exists()
{
	local _query="SELECT SCHEMA_NAME FROM INFORMATION_SCHEMA.SCHEMATA WHERE SCHEMA_NAME='$1';"
	result=$(echo "$_query" | jexec mysql mysql -s -N)

	if [ -z "$result" ]; then
		echo "$1 db does not exist"
		return 1
	fi

	echo "$1 db exists"
	return 0
}

fetch_and_exec()
{
	fetch -m "$TOASTER_SRC_URL/provision-$1.sh"
	sh "provision-$1.sh"
}

provision()
{
	case "$1" in
		host)   fetch_and_exec "$1"; return;;
	esac

	if ! get_jail_ip "$1"; then
		echo "unknown jail $1"
		return;
	fi

	fetch_and_exec "$1"
}

reverse_list()
{
	# shellcheck disable=2068
	for _j in $@; do
		_rev_list="${_j} ${_rev_list}"
	done
	echo "$_rev_list"
}

unprovision_last()
{
	for _j in $JAIL_ORDERED_LIST; do
		if zfs_filesystem_exists "$ZFS_JAIL_VOL/$_j.last"; then
			tell_status "destroying $ZFS_JAIL_VOL/$_j.last"
			zfs destroy "$ZFS_JAIL_VOL/$_j.last"
		fi
	done
}

unprovision_filesystems()
{
	for _j in $JAIL_ORDERED_LIST; do
		if zfs_filesystem_exists "$ZFS_JAIL_VOL/$_j.ready"; then
			tell_status "destroying $ZFS_JAIL_VOL/$_j.ready"
			zfs destroy "$ZFS_JAIL_VOL/$_j.ready"
		fi

		if zfs_filesystem_exists "$ZFS_JAIL_VOL/$_j.last"; then
			tell_status "destroying $ZFS_JAIL_VOL/$_j.last"
			zfs destroy "$ZFS_JAIL_VOL/$_j.last"
		fi

		if [ -e "$ZFS_JAIL_VOL/$_j/dev/null" ]; then
			umount -t devfs "$ZFS_JAIL_VOL/$_j/dev"
		fi

		if zfs_filesystem_exists "$ZFS_DATA_VOL/$_j"; then
			tell_status "destroying $ZFS_DATA_MNT/$_j"
			zfs destroy "$ZFS_DATA_VOL/$_j"
		fi

		if zfs_filesystem_exists "$ZFS_JAIL_VOL/$_j"; then
			tell_status "destroying $ZFS_JAIL_VOL/$_j"
			zfs destroy "$ZFS_JAIL_VOL/$_j"
		fi
	done

	if zfs_filesystem_exists "$ZFS_JAIL_VOL"; then
		tell_status "destroying $ZFS_JAIL_VOL"
		zfs destroy "$ZFS_JAIL_VOL"
	fi

	if zfs_filesystem_exists "$ZFS_DATA_VOL"; then
		tell_status "destroying $ZFS_DATA_VOL"
		zfs destroy "$ZFS_DATA_VOL"
	fi

	if zfs_filesystem_exists "$BASE_VOL"; then
		tell_status "destroying $BASE_VOL"
		zfs destroy -r "$BASE_VOL"
	fi
}

unprovision_files()
{
	for _f in /etc/jail.conf /etc/pf.conf /usr/local/sbin/jailmanage; do
		if [ -f "$_f" ]; then
			tell_status "rm $_f"
			rm "$_f"
		fi
	done

	if grep -q "^$JAIL_NET_PREFIX" /etc/hosts; then
		sed -i .bak -e "/^$JAIL_NET_PREFIX.*/d" /etc/hosts
	fi
}

unprovision()
{
	if [ "$1" = "last" ]; then
		unprovision_last
		return
	fi

	local _reversed; _reversed=$(reverse_list "$JAIL_ORDERED_LIST")

	if [ -f /etc/jail.conf ]; then
		for _j in $_reversed; do
			echo "$_j"
			service jail stop "$_j"
			sleep 1
		done
	fi

	ipcrm -W
	unprovision_filesystems
	unprovision_files
}

add_pf_portmap()
{
	sed -i .bak -e "/^block / a\
# map port $1 traffic to $2
rdr proto tcp from any to <ext_ips> port { $1 } -> $(get_jail_ip "$2") \
" /etc/pf.conf
}

mt6-update()
{
	fetch "$TOASTER_SRC_URL/mail-toaster.sh"
	# shellcheck disable=SC1091
	. mail-toaster.sh
}

mt6-include()
{
	if [ ! -d include ]; then
		mkdir include || exit
	fi

	fetch -m -o "include/$1.sh" "$TOASTER_SRC_URL/include/$1.sh"

	if [ ! -f "include/$1.sh" ]; then
		echo "unable to download include/$1.sh"
		exit
	fi

	# shellcheck source=include/$.sh disable=SC1091
	. "include/$1.sh"
}

jail_rename()
{
    if [ -z "$1" ] || [ -z "$2" ]; then
        echo "$0 <existing jail name> <new jail name>"
        exit
    fi

    echo "renaming $1 to $2"
    service jail stop "$1"  || exit

    for _f in data jails
    do
        zfs unmount "$ZFS_VOL/$_f/$1"
        zfs rename "$ZFS_VOL/$_f/$1" "$ZFS_VOL/$_f/$2"  || exit
        zfs set mountpoint="/$_f/$2" "$ZFS_VOL/$_f/$2"  || exit
        zfs mount "$ZFS_VOL/$_f/$2"
    done

    sed -i .bak \
        -e "/^$1\s/ s/$1/$2/" \
        /etc/jail.conf || exit

    service jail start "$2"

    echo "Don't forget to update your PF and/or Haproxy rules"
}
