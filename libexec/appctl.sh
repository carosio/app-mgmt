#!/bin/sh
#
# $0 start app_source
# $0 stop|ping|remote_console appinstance
#
# at the moment only one kind of application is supported: exrm based elixir-release.
#
# also: at the moment the only use-case is being called by a systemd-unit.
#

set -e

err_trap() {
	echo "fail: (line $*)"
}
trap 'err_trap ${LINENO}' ERR

# systemd may start ourselves with --from-systemd=%p@%i
# this is our source for name and version -> appinstance
if [ "${1:0:14}" = "--from-systemd" ]
then
	app_instance="${1:15}" ; shift
	echo "systemd provided appinstance: [$app_instance]"
else
	echo "$0 must be called throught systemd unit."
	exit 1
fi

command="$1" ; shift
if [ "$command" = start ]
then
	app_source="$1" ; shift
	[ "${app_source:0:1}" = "/" ] # app_source path must be absolute

	# remove trailing '/' if necessary
	if [ "${app_source:(-1)}" = "/"  ] ; then
		app_source="${app_source:0:-2}"	
	fi

	if [ ! -d ${app_source} ]
	then
		echo "app_source [$app_source]: no such file or directory."
		exit 1
	fi
fi

# split app_instance to app_name, app_version and instance_name 
# (systemd-case)

# APPNAME@VERSION,INSTANCE
# unimux@1.2.3,inst1
app_name="${app_instance%%@*}" # APPNAME
unit_name_suffix="${app_instance##*@}" # VERSION,INSTANCE
app_version="${unit_name_suffix%%:*}" # VERSION
instance_name="${unit_name_suffix##*:}" # INSTANCE

if [ "$command" = start ]
then
	if [ ! -e "$app_source/$app_version/bin/rc" ] ; then
		echo "invalid app_source [$app_source/$app_version]: no bin/rc found."
		exit 1
	fi
fi

export APPINSTANCE_HOME="/run/$app_instance"
export RELEASE_MUTABLE_DIR="$APPINSTANCE_HOME"
export HOME="$APPINSTANCE_HOME" # for automatic cookie generation by erlag vm
echo "appinstance home is [$APPINSTANCE_HOME]."

[ "$command" != start ] && app_source=$(cat "${APPINSTANCE_HOME}/APPSOURCE")

# some defaults
export COOKIE_MODE=ignore 			# do not set -cookie; let erlang use $HOME/.erlang.cookie
underscored_app_version="${app_version//./_}" 	# erlang does not like dots in node_name 
export NODE_NAME="$app_name-$underscored_app_version-$instance_name@127.0.0.1"

# set the RELEASE_CONFIG_FILE variable for exrm
if [ -n "$BASE_RELEASE_CONFIG_FILE" -a -e "$BASE_RELEASE_CONFIG_FILE" ]
then
    BASE_RELEASE_CONFIG_FILE_DIR=$(dirname "${BASE_RELEASE_CONFIG_FILE}")
    if [ ! -e "${BASE_RELEASE_CONFIG_FILE_DIR}/${app_instance}.conf" ]
    then
        cp "${BASE_RELEASE_CONFIG_FILE}" "${BASE_RELEASE_CONFIG_FILE_DIR}/${app_instance}.conf"
    fi
    export RELEASE_CONFIG_FILE="${BASE_RELEASE_CONFIG_FILE_DIR}/${app_instance}.conf"
elif [ -e "/etc/${app_instance}.conf" ]
then
    # by default we expect a config from /etc
    export RELEASE_CONFIG_FILE="/etc/${app_instance}.conf"
else
    echo "no valid config file found for appinstance [${app_instance}]"
    exit 1
fi
echo "using config file [$RELEASE_CONFIG_FILE]."

case $command in
	start)
		echo "starting [$app_instance] from [$app_source/$app_version]"
		mkdir -pv "$APPINSTANCE_HOME"
		cd "$APPINSTANCE_HOME"
		echo "$app_source" > APPSOURCE
		echo $$ > MAINPID
		env > ENV
		if [ -e /etc/erlang-cluster-cookie ] ; then
			cp -v /etc/erlang-cluster-cookie "$APPINSTANCE_HOME/.erlang.cookie"
			chmod 400 "$APPINSTANCE_HOME/.erlang.cookie"
		else
			echo "WARNING: no /etc/erlang-cluster-cookie set. erlang will generate a cookie."
			echo "WARNING: for a cluster-wide shared cookie you can distribute"
		       	echo "WARNING: $APPINSTANCE_HOME/.erlang.cookie from this node to"
		       	echo "WARNING: /etc/erlang-cluster-cookie on all cluster hosts."
			rm -f "$APPINSTANCE_HOME/.erlang.cookie"
		fi

		exec "${app_source}/${app_version}/bin/rc" foreground
	;;
	ping|stop|remote_console)
		if [ ! -d "$APPINSTANCE_HOME" ] ; then
			echo "appinstance [$APPINSTANCE_HOME] not found or invalid."
			exit 1
		fi

		exec "${app_source}/${app_version}/bin/rc" $command
	;;
esac
