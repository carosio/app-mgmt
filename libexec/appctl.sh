#!/bin/zsh
#
# $0 start app_source
# $0 stop|ping|remote_console appinstance
#
# at the moment only one kind of application is supported: distillery based elixir-release.
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
# unimux@1.2.3:inst1
app_name="${app_instance%%@*}" # APPNAME
unit_name_suffix="${app_instance##*@}" # VERSION,INSTANCE
app_version="${unit_name_suffix%%:*}" # VERSION
instance_name="${unit_name_suffix##*:}" # INSTANCE
if [ "$instance_name" = "$unit_name_suffix" ]
then
	instance_name=default
	app_instance="${app_instance}-${instance_name}"
fi

if [ "$command" = start ]
then
	if [ ! -e "$app_source/$app_version/bin/rc" ] ; then
		echo "invalid app_source [$app_source/$app_version]: no bin/rc found."
		exit 1
	fi
fi

export APPINSTANCE_HOME="/run/$app_instance"
export RELEASE_CONFIG_DIR="$APPINSTANCE_HOME"
export RELEASE_MUTABLE_DIR="$APPINSTANCE_HOME/mutable/${command}"
export HOME="$APPINSTANCE_HOME" # for automatic cookie generation by erlang vm
export ERL_EPMD_ADDRESS=127.0.0.1   # currently we don't use distributed erlang and don't need the epmd
echo "appinstance home is [$APPINSTANCE_HOME]."

[ "$command" != start ] && [ -s "${APPINSTANCE_HOME}/APPSOURCE" ] && app_source=$(cat "${APPINSTANCE_HOME}/APPSOURCE")

# evaluate CONFPATH
# for now CONFPATH is just a file which holds the path
# to the conf-file to be used.
# later it can be a list of files, contain directories,
# names of environment variables and other configuration locations.
# this mechanism allows app-management without explicit knowledge
# about the location of configuration data. the decision about
# the configuration source is made during app-packaging/distribution.
if [ -s "${app_source}/${app_version}/CONFPATH" ]
then
	# read the first non-comment line
	CONFPATH=$( grep -v '^#' "${app_source}/${app_version}/CONFPATH" | head -n 1 )
	if [ -r "$CONFPATH" ] ; then
                echo "using config file [$CONFPATH]."
	else
		echo "CONFPATH [$CONFPATH] not readable."
		exit 1
	fi
else
	echo "no ${app_source}/${app_version}/CONFPATH present"
fi

case $command in
	start)
                if [ -z "$CONFPATH" ] ; then
                        echo "failed to determine CONFPATH."
			exit 1
		fi
		echo "starting [$app_instance] from [$app_source/$app_version]"
		mkdir -pv "$APPINSTANCE_HOME"
                basename=$(basename $CONFPATH)

                # The config is read from $APPINSTANCE_HOME
                # and it may occur that the config name has
                # hyphens instead of underscores. The latter
                # is used for our app names and considered by
                # distillery for config files.
                cp $CONFPATH "$APPINSTANCE_HOME/${basename/-/_}"

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
	reload)
		if [ ! -d "$APPINSTANCE_HOME" ] ; then
			echo "appinstance [$APPINSTANCE_HOME] not found or invalid."
			exit 1
		fi

		exec "${app_source}/${app_version}/bin/rc" rpc Elixir.ReleaseManager.Reload run
	;;
esac

