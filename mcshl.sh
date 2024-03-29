#!/bin/sh

BASEDIR=~/.minecraft
[ ! -d "$BASEDIR" ] && BASEDIR="${XDG_DATA_HOME:-$HOME/.local/share}/minecraft"


TOS=linux
[ "$OS" = 'Windows_NT' ] && TOS=windows

# jobs is needed for parallel wget count limiting
command -v jobs >/dev/null 2>&1 || DISABLE_PARALLEL=1

VLEVEL=1
#VLEVEL=999

WGET=wget

WGET_LIM=128

WGET_QUIET=0

set -e

[ ! -n "$1" ] && set -- help

while true;do
	case $1 in
		-b|--basedir)
			BASEDIR=$2
			shift 2
			;;
		-v|--verbose)
			VLEVEL=$((VLEVEL + 1))
			shift
			;;
		-q|--wget-quiet)
			WGET_QUIET=1
			shift
			;;
		*)
			break
			;;
	esac
done

echo_safe() {
	printf "%s\n" "$*"
}

log(){
	if [ "$1" -le "$VLEVEL" ];then
		shift
		echo_safe $@
	fi
}

# Busybox wget built-in does not have options we need and may lack HTTPS support
if [ "$(command -v wget)" = 'wget' ];then
	log 2 "wget built-in detected"
	OIFS=$IFS
	IFS=':'
	[ "$TOS" = 'windows' ] && IFS=';'
	for P in $PATH;do
		F=$P/wget
		[ "$TOS" = 'windows' ] && F=$F.exe
		[ -x "$F" ] && log 2 "found $F" && WGET="$F" && break
	done
	IFS=$OIFS
fi

if [ "$WGET_QUIET" -gt "0" ];then
	alias wget="$WGET -q"
fi

basepath(){
	echo_safe "$1" | rev | cut -f 2- -d '/' | rev
}

wget_wrapper(){
	if [ -z "$DISABLE_PARALLEL" ];then
		while [ "$(jobs | wc -l)" -gt "$WGET_LIM" ];do
			sleep 1
		done
		wget -nc $@ &
	else
		wget -nc $@ || true
	fi
}

sha1_chkrm(){
	SUM=$(sha1sum "$1" | cut -f 1 -d ' ')
	[ "$SUM" != "$2" ] && log 1 "sha1 $1 mismatch, deleting" && rm "$1"
}

rls(){
	if [ "$1" = "--snapshot" ] || [ "$1" = "-s" ];then
		wget -O - https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[].id'
	else
		wget -O - https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[]|select(.type=="release").id'
	fi
}

dl(){
	VURL=$(wget -O - https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[]|select(.id=="'"$1"'").url')
	[ ! -n "$VURL" ] && log 1 "cannot find version $1" && exit 1
	mkdir -p "versions/$1"
	wget -nc -P "versions/$1" "$VURL"
	VJSONF="versions/$1/$1.json"

	# main jar
	wget_wrapper "$(jq -r '.downloads.client.url' $VJSONF)" -O "versions/$1/$1.jar"

	# libraries
	mkdir -p "libraries"
	mkdir -p "versions/$1/natives"
	for LJSON in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LJSON"
		F=$(echo_safe $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo_safe $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule allow not $TOS" && continue
		[ "$(echo_safe $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule disallow $TOS" && continue

		log 1 "downloading $F"
		mkdir -p "libraries/""$(basepath $F)"
		wget_wrapper -O "libraries/$F" "$(echo_safe $LJSON | jq -r '.downloads.artifact.url')"

		NAVKEY="$(echo_safe $LJSON | jq '.natives.'$TOS)"

		if [ "$NAVKEY" != "null" ];then
			log 1 "downloading natives for $F"
			TMPF=$(mktemp)
			wget "$(echo_safe $LJSON | jq -r '.downloads.classifiers.'$NAVKEY'.url')" -O "$TMPF"
			unzip -o "$TMPF" -d "versions/$1/natives"
			rm "$TMPF"
		fi
	done

	# assets
	mkdir -p "assets/objects"
	mkdir -p "assets/indexes"
	AID=$(jq -r '.assetIndex.id' "$VJSONF")
	AF="assets/indexes/$AID.json"
	wget -nc -P "assets/indexes" "$(jq -r '.assetIndex.url' "$VJSONF")"

	log 1 "downloading assets $AID"
	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo_safe $HASH | head -c 2)
		mkdir -p "assets/objects/$HASHHEAD"
		wget_wrapper -P "assets/objects/$HASHHEAD" https://resources.download.minecraft.net/$HASHHEAD/$HASH
	done

	wait
}

launch(){
	VJSONF="versions/$1/$1.json"
	[ ! -f "$VJSONF" ] && log 1 "version $1 not found" && exit 1

	[ ! -n "$2" ] && log 1 "username not provided" && exit 1

	OIFS=$IFS
	IFS='
'
	CCONF=$VJSONF
	while NVER=$(jq -r '.inheritsFrom' "$CCONF") && [ "$NVER" != "null" ];do
		CCONF=versions/$NVER/$NVER.json
		VJSONF=$VJSONF'
'$CCONF
	done

	natives_directory=versions/$1/natives
	NVER=$1
	while [ ! -d "$natives_directory" ];do
		NVER=$(jq -r '.inheritsFrom' "versions/$NVER/$NVER.json")
		[ "$NVER" = "null" ] && log 1 "natives for $1 not found" && exit 1
		natives_directory=versions/$NVER/natives
	done
	STRSUB='s/${natives_directory}/'"$(echo "$natives_directory" | sed 's/\//\\\//g;')"'/g;'\
's/${launcher_name}/minecraft-launcher/g;'\
's/${launcher_version}/2.0.1003/g;'

	for LIB in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LIB"
		[ "$(echo_safe $LIB | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule allow not $TOS" && continue
		[ "$(echo_safe $LIB | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule disallow $TOS" && continue

		LPATH=$(echo_safe "$LIB" | jq -r '.downloads.artifact.path')
		if [ "$LPATH" != "null" ];then
			classpath=$classpath:libraries/$LPATH
		else
			# guess path
			NAME=$(echo_safe "$LIB" | jq -r '.name')
			ORG=$(echo_safe "$NAME" | cut -f 1 -d ':')
			PKG=$(echo_safe "$NAME" | cut -f 2 -d ':')
			VER=$(echo_safe "$NAME" | cut -f 3 -d ':')
			GPATH=$(echo_safe "$ORG" | tr '.' '/')/$PKG/$VER/$PKG-$VER.jar
			log 2 "classpath: no path for $NAME, guess $GPATH"
			classpath=$classpath:libraries/$GPATH
			if [ ! -f "libraries/$GPATH" ];then
				log 1 "library $GPATH missing"
				URL=$(echo_safe "$LIB" | jq -r '.url')
				if [ "$URL" != "null" ];then
					log 2 "library: download path with .url found"
					log 1 "downloading missing $GPATH from $URL"
					mkdir -p "$(dirname libraries/$GPATH)"
					wget_wrapper "$URL/$GPATH" -O "libraries/$GPATH"
				fi
			fi
		fi
	done
	wait
	classpath=$(echo_safe "$classpath" | tail -c +2)
	for VERF in $VJSONF;do
		VER=$(basename "$VERF" ".json")
		classpath=$classpath:versions/$VER/$VER.jar
	done

	# Windows java classpath format adjustment
	[ "$TOS" = 'windows' ] && classpath=$(echo_safe $classpath | sed 's|:|\;|g;s|/|\\|g')

	STRSUB="$STRSUB"'s/${classpath}/'"$(echo "$classpath" | sed 's/\//\\\//g;')"'/g;'
	
	for ARGJSON in $(jq -c '.arguments.jvm[]' $VJSONF);do
		log 2 "found jvm arg $ARGJSON"
		if [ "$(echo_safe $ARGJSON | head -c 1)" = '"' ];then
			JVMARGS=$JVMARGS'
'$(echo_safe "$ARGJSON" | jq -r '.' | sed "$STRSUB")
		else
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule allow not $TOS" && continue
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule disallow $TOS" && continue
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="allow").os.arch|.!=null and .=="x86"' 2>/dev/null)" = "true" ] && [ -n "$(file -L $(which java) | grep x86-64)" ] && log 2 "block: rule allow x86" && continue

			VALJSON=$(echo_safe ${ARGJSON} | jq '.value')
			if [ "$(echo_safe $VALJSON | head -c 1)" = '"' ];then
				JVMARGS=$JVMARGS'
'$(echo_safe "$VALJSON" | jq -r '.' | sed "$STRSUB")
			else
				for VAL in $(echo_safe "$VALJSON" | jq -r '.[]');do
					JVMARGS=$JVMARGS'
'$(echo_safe "$VAL" | sed "$STRSUB")
				done
			fi
		fi
	done

	STRSUB="$STRSUB"'s/${auth_player_name}/'"$(echo "$2" | sed 's/\//\\\//g;')"'/g;'\
's/${version_name}/'"$(echo "$1" | sed 's/\//\\\//g;')"'/g;'\
's/${game_directory}/./g;'\
's/${assets_root}/assets/g;'\
's/${assets_index_name}/'"$(jq -r 'select(.assetIndex.id)|.assetIndex.id' $VJSONF | head -n 1 | sed 's/\//\\\//g;')"'/g;'\
's/${auth_uuid}/00000000-0000-0000-0000-000000000000/g;'\
's/${auth_access_token}/null/g;'\
's/${user_type}/legacy/g;'\
's/${version_type}/'"$(jq -r 'select(.type)|.type' $VJSONF | head -n 1 | sed 's/\//\\\//g;')"'/g;'
	for ARGJSON in $(jq -c '.arguments.game[]' $VJSONF);do
		log 2 "found game arg $ARGJSON"
		if [ "$(echo_safe $ARGJSON | head -c 1)" = '"' ];then
			GAMEARGS=$GAMEARGS'
'$(echo_safe "$ARGJSON" | jq -r '.' | sed "$STRSUB")
		else
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule allow not $TOS" && continue
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule disallow $TOS" && continue
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="allow").os.arch|.!=null and .=="x86"' 2>/dev/null)" = "true" ] && [ -n "$(file -L $(which java) | grep x86-64)" ] && log 2 "block: rule allow x86" && continue
			[ "$(echo_safe $ARGJSON | jq '.rules[]|select(.action=="allow").features!=null' 2>/dev/null)" = "true" ] && log 2 "block: skip demo and resolution" && continue

			VALJSON=$(echo_safe "$ARGJSON" | jq '.value')
			if [ "$(echo_safe $VALJSON | head -c 1)" = '"' ];then
				GAMEARGS=$GAMEARGS'
'$(echo_safe "$VALJSON" | jq -r '.' | sed "$STRSUB")
			else
				for VAL in $(echo_safe "$VALJSON" | jq -r '.[]');do
					GAMEARGS=$GAMEARGS'
'$(echo_safe "$VAL" | sed "$STRSUB")
				done
			fi
		fi
	done

	log 2 "cmd: $JVMARGS $(jq -r 'select(.mainClass)|.mainClass' $VJSONF | head -n 1) $GAMEARGS"
	java $JVMARGS $(jq -r 'select(.mainClass)|.mainClass' $VJSONF | head -n 1) $GAMEARGS
	IFS=$OIFS
}

lls(){
	[ ! -d "versions" ] && return
	OIFS=$IFS
	IFS='
'
	for VER in $(ls -1 "versions/");do
		VJSONF="versions/$VER/$VER.json"
		if [ -f "$VJSONF" ];then
			if [ "$1" = "-a" ] || [ "$1" = "--asset" ];then
				AVER=$(jq -r '.assetIndex.id' "$VJSONF")
				INH=$(jq -r '.inheritsFrom' "$VJSONF")
				while [ "$AVER" = "null" ] && [ "$INH" != "null" ];do
					VJSONF="versions/$INH/$INH.json"
					AVER=$(jq -r '.assetIndex.id' "$VJSONF")
					INH=$(jq -r '.inheritsFrom' "$VJSONF")
				done
				echo_safe "$VER" "$AVER"
			else
				echo_safe "$VER"
			fi
		fi
	done
	IFS=$OIFS
}

cksum(){
	VJSONF="versions/$1/$1.json"
	[ ! -f "$VJSONF" ] && log 1 "cannot find version $1" && exit 1

	INH=$(jq -r '.inheritsFrom' "$VJSONF")
	if [ "$INH" != "null" ];then
		log 1 "version $1 uses inheritance, maybe a mod, checking $INH instead"
		cksum "$INH"
		return
	fi

	# main jar
	sha1_chkrm "versions/$1/$1.jar" $(jq -r '.downloads.client.sha1' "$VJSONF")

	# libraries
	for LJSON in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LJSON"
		F=$(echo_safe $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo_safe $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule allow not $TOS" && continue
		[ "$(echo_safe $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="'$TOS'"' 2>/dev/null)" = "true" ] && log 2 "block: rule disallow $TOS" && continue

		sha1_chkrm "libraries/$F" "$(echo_safe $LJSON | jq -r '.downloads.artifact.sha1')"
		# TODO find a way to cover natives?
	done

	# assets
	AID=$(jq -r '.assetIndex.id' "$VJSONF")
	AF="assets/indexes/$AID.json"
	sha1_chkrm "$AF" $(jq -r '.assetIndex.sha1' "$VJSONF")

	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo_safe $HASH | head -c 2)
		sha1_chkrm "assets/objects/$HASHHEAD/$HASH" "$HASH"
	done
}

rm_main(){
	[ ! -d "versions/$1" ] && log 1 "cannot find version $1" && exit 1
	rm -r "versions/$1"
}

lls_asset(){
	[ ! -d "assets/indexes" ] && return
	ls -1 "assets/indexes" | rev | cut -f 2- -d '.' | rev
}

rm_asset(){
	AF="assets/indexes/$1.json"
	[ ! -f "$AF" ] && log 1 "cannot find asset $1" && exit 1

	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo_safe $HASH | head -c 2)
		rm "assets/objects/$HASHHEAD/$HASH"
		rmdir "assets/objects/$HASHHEAD" 2>/dev/null
	done

	rm "$AF"
}

help(){
	echo_safe "Usage: $0 [-b BASEDIR | --basedir BASEDIR]"
	echo_safe "                [-v | --verbose] [-q | --wget-quiet] SUBCOMMAND"
	echo_safe
	echo_safe "  -b, --basedir BASEDIR   Use BASEDIR instead of ~/.minecraft"
	echo_safe "  -v, --verbose           Increase verbosity"
	echo_safe "  -q, --wget-quiet        Make wget quiet"
	echo_safe
	echo_safe "Subcommands:"
	echo_safe "  rls [-s | --snapshot]"
	echo_safe "  List Minecraft versions available for download"
	echo_safe "    -s, --snapshot        Enable snapshots"
	echo_safe
	echo_safe "  lls [-a | --asset]"
	echo_safe "  List installed Minecraft versions"
	echo_safe "    -a, --asset           Also list asset used"
	echo_safe "  alias: ls"
	echo_safe
	echo_safe "  dl VERSION"
	echo_safe "  Download Minecraft VERSION"
	echo_safe "  alias: download"
	echo_safe
	echo_safe "  launch VERSION USERNAME"
	echo_safe "  Launch Minecraft VERSION with USERNAME"
	echo_safe
	echo_safe "  cksum VERSION"
	echo_safe "  Check VERSION files with sha1sum, remove if bad"
	echo_safe "  alias: check, checksum"
	echo_safe
	echo_safe "  rm_main VERSION"
	echo_safe "  Remove main jar, json and natives for VERSION"
	echo_safe "  alias: rm"
	echo_safe
	echo_safe "  lls_asset"
	echo_safe "  List installed asset versions"
	echo_safe "  alias: lsasset"
	echo_safe
	echo_safe "  rm_asset VERSION"
	echo_safe "  Remove asset VERSION, this may break other versions that share"
	echo_safe "  the same files and need to download with dl again"
	echo_safe "  alias: rmasset"
}

mkdir -p "$BASEDIR"
cd "$BASEDIR"

case $1 in
	rls|lls|dl|launch|cksum|rm_main|lls_asset|rm_asset|help)
		$@
		;;
	--help|-h)
		help
		;;
	ls)
		shift
		lls $@
		;;
	download)
		shift
		dl $@
		;;
	check|checksum)
		shift
		cksum $@
		;;
	rm)
		shift
		rm_main $@
		;;
	lsasset)
		shift
		lls_asset $@
		;;
	rmasset)
		shift
		rm_asset $@
		;;
	*)
		log 1 "unknown subcommand $1"
		exit 1
		;;
esac
