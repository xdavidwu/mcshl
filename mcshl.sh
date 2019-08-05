#!/bin/sh

BASEDIR=~/.minecraft
VLEVEL=1
#VLEVEL=999

WGET_LIM=128

WGET_QUIET=0

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

if [ "$WGET_QUIET" -gt "0" ];then
	alias wget="wget -q --compression=auto"
else
	alias wget="wget --compression=auto"
fi

log(){
	if [ "$1" -le "$VLEVEL" ];then
		shift
		echo $@
	fi
}

basepath(){
	echo "$1" | rev | cut -f 2- -d '/' | rev
}

wget_wrapper(){
	while [ "$(jobs | wc -l)" -gt "$WGET_LIM" ];do
		sleep 1
	done
	wget $@ &
}

sha1_chkrm(){
	SUM=$(sha1sum "$1" | cut -f 1 -d ' ')
	[ "$SUM" != "$2" ] && log 1 "sha1 $1 mismatch, deleting" && rm "$1"
}

rls(){
	if [ "$1" == "--snapshot" ] || [ "$1" == "-s" ];then
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
	wget_wrapper -nc "$(jq -r '.downloads.client.url' $VJSONF)" -O "versions/$1/$1.jar"

	# libraries
	mkdir -p "libraries"
	mkdir -p "versions/$1/natives"
	for LJSON in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LJSON"
		F=$(echo $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		log 1 "downloading $F"
		mkdir -p "libraries/""$(basepath $F)"
		wget_wrapper -O "libraries/$F" -nc "$(echo $LJSON | jq -r '.downloads.artifact.url')"

		NAVKEY="$(echo $LJSON | jq '.natives.linux')"

		if [ "$NAVKEY" != "null" ];then
			log 1 "downloading natives for $F"
			TMPF=$(mktemp)
			wget "$(echo $LJSON | jq -r '.downloads.classifiers.'$NAVKEY'.url')" -O "$TMPF"
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
		HASHHEAD=$(echo $HASH | head -c 2)
		mkdir -p "assets/objects/$HASHHEAD"
		wget_wrapper -nc -P "assets/objects/$HASHHEAD" https://resources.download.minecraft.net/$HASHHEAD/$HASH
	done

	wait
}

launch(){
	VJSONF="versions/$1/$1.json"
	[ ! -f "$VJSONF" ] && log 1 "version $1 not found" && exit 1

	OIFS=$IFS
	IFS=$'\n'
	CCONF=$VJSONF
	while NVER=$(jq -r '.inheritsFrom' "$CCONF") && [ "$NVER" != "null" ];do
		CCONF=versions/$NVER/$NVER.json
		VJSONF=$VJSONF$'\n'$CCONF
	done

	natives_directory=versions/$1/natives
	launcher_name=minecraft-launcher
	launcher_version=2.0.1003

	for LIB in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LIB"
		[ "$(echo $LIB | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LIB | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		LPATH=$(echo "$LIB" | jq -r '.downloads.artifact.path')
		if [ "$LPATH" != "null" ];then
			classpath=$classpath:libraries/$LPATH
		else
			# guess path
			NAME=$(echo "$LIB" | jq -r '.name')
			ORG=$(echo "$NAME" | cut -f 1 -d ':')
			PKG=$(echo "$NAME" | cut -f 2 -d ':')
			VER=$(echo "$NAME" | cut -f 3 -d ':')
			GPATH=$(echo "$ORG" | tr '.' '/')/$PKG/$VER/$PKG-$VER.jar
			log 2 "classpath: no path for $NAME, guess $GPATH"
			classpath=$classpath:libraries/$GPATH
		fi
	done
	classpath=$(echo "$classpath" | tail -c +2):versions/$1/$1.jar
	
	for ARGJSON in $(jq -c '.arguments.jvm[]' $VJSONF);do
		log 2 "found jvm arg $ARGJSON"
		if [ "$(echo $ARGJSON | head -c 1)" == '"' ];then
			eval JVMARG=$(echo "$ARGJSON" | jq -r '.')
			JVMARGS=$JVMARGS$'\n'$JVMARG
		else
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="allow").os.arch|.!=null and .=="x86"' 2>/dev/null)" == "true" ] && [ -n "$(file -L $(which java) | grep x86-64)" ] && log 2 "block: rule allow x86" && continue

			VALJSON=$(echo "$ARGJSON" | jq '.value')
			if [ "$(echo $VALJSON | head -c 1)" == '"' ];then
				eval JVMARG=$(echo "$VALJSON" | jq -r '.')
				JVMARGS=$JVMARGS$'\n'$JVMARG
			else
				for VAL in $(echo "$VALJSON" | jq -r '.[]');do
					eval JVMARG=$VAL
					JVMARGS=$JVMARGS$'\n'$JVMARG
				done
			fi
		fi
	done

	auth_player_name=$2
	version_name=$1
	game_directory=.
	assets_root=assets
	assets_index_name=$(jq -r 'select(.assetIndex.id)|.assetIndex.id' $VJSONF | head -n 1)
	auth_uuid=00000000-0000-0000-0000-000000000000
	auth_access_token=null
	user_type=legacy
	version_type=$(jq -r 'select(.type)|.type' $VJSONF | head -n 1)

	for ARGJSON in $(jq -c '.arguments.game[]' $VJSONF);do
		log 2 "found game arg $ARGJSON"
		if [ "$(echo $ARGJSON | head -c 1)" == '"' ];then
			eval GAMEARG=$(echo "$ARGJSON" | jq -r '.')
			GAMEARGS=$GAMEARGS$'\n'$GAMEARG
		else
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="allow").os.arch|.!=null and .=="x86"' 2>/dev/null)" == "true" ] && [ -n "$(file -L $(which java) | grep x86-64)" ] && log 2 "block: rule allow x86" && continue
			[ "$(echo $ARGJSON | jq '.rules[]|select(.action=="allow").features!=null' 2>/dev/null)" == "true" ] && log 2 "block: skip demo and resolution" && continue

			VALJSON=$(echo "$ARGJSON" | jq '.value')
			if [ "$(echo $VALJSON | head -c 1)" == '"' ];then
				eval GAMEARG=$(echo "$VALJSON" | jq -r '.')
				GAMEARGS=$GAMEARGS$'\n'$GAMEARG
			else
				for VAL in $(echo "$VALJSON" | jq -r '.[]');do
					eval GAMEARG=$VAL
					GAMEARGS=$GAMEARGS$'\n'$GAMEARG
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
	IFS=$'\n'
	for VER in $(ls -1 "versions/");do
		VJSONF="versions/$VER/$VER.json"
		if [ -f "$VJSONF" ];then
			if [ "$1" == "-a" ] || [ "$1" == "--asset" ];then
				AVER=$(jq -r '.assetIndex.id' "$VJSONF")
				INH=$(jq -r '.inheritsFrom' "$VJSONF")
				while [ "$AVER" == "null" ] && [ "$INH" != "null" ];do
					VJSONF="versions/$INH/$INH.json"
					AVER=$(jq -r '.assetIndex.id' "$VJSONF")
					INH=$(jq -r '.inheritsFrom' "$VJSONF")
				done
				echo "$VER" "$AVER"
			else
				echo "$VER"
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
		F=$(echo $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		sha1_chkrm "libraries/$F" "$(echo $LJSON | jq -r '.downloads.artifact.sha1')"
		# TODO find a way to cover natives?
	done

	# assets
	AID=$(jq -r '.assetIndex.id' "$VJSONF")
	AF="assets/indexes/$AID.json"
	sha1_chkrm "$AF" $(jq -r '.assetIndex.sha1' "$VJSONF")

	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo $HASH | head -c 2)
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
		HASHHEAD=$(echo $HASH | head -c 2)
		rm "assets/objects/$HASHHEAD/$HASH"
		rmdir "assets/objects/$HASHHEAD" 2>/dev/null
	done

	rm "$AF"
}

help(){
	echo "Usage: $0 [-b BASEDIR | --basedir BASEDIR]"
	echo "                [-v | --verbose] [-q | --wget-quiet] SUBCOMMAND"
	echo
	echo "  -b, --basedir BASEDIR   Use BASEDIR instead of ~/.minecraft"
	echo "  -v, --verbose           Increase verbosity"
	echo "  -q, --wget-quiet        Make wget quiet"
	echo
	echo "Subcommands:"
	echo "  rls [-s | --snapshot]"
	echo "  List Minecraft versions available for download"
	echo "    -s, --snapshot        Enable snapshots"
	echo
	echo "  lls [-a | --asset]"
	echo "  List installed Minecraft versions"
	echo "    -a, --asset           Also list asset used"
	echo "  alias: ls"
	echo
	echo "  dl VERSION"
	echo "  Download Minecraft VERSION"
	echo "  alias: download"
	echo
	echo "  launch VERSION USERNAME"
	echo "  Launch Minecraft VERSION with USERNAME"
	echo
	echo "  cksum VERSION"
	echo "  Check VERSION files with sha1sum, remove if bad"
	echo "  alias: check, checksum"
	echo
	echo "  rm_main VERSION"
	echo "  Remove main jar, json and natives for VERSION"
	echo "  alias: rm"
	echo
	echo "  lls_asset"
	echo "  List installed asset versions"
	echo "  alias: lsasset"
	echo
	echo "  rm_asset VERSION"
	echo "  Remove asset VERSION, this may break other versions that share"
	echo "  the same files and need to download with dl again"
	echo "  alias: rmasset"
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
