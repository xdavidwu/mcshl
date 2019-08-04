#!/bin/sh

BASEDIR=~/.mctest
VLEVEL=1
VLEVEL=999

WGET_LIM=128
WGET_COUNT=0

mkdir -p "$BASEDIR"

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
	wget --compression=auto $@ &
}

sha1_chkrm(){
	SUM=$(sha1sum "$1" | cut -f 1 -d ' ')
	[ "$SUM" != "$2" ] && log 1 "sha1 $1 mismatch, deleting" && rm "$1"
}

rls(){
	if [ "$1" == "snapshot" ];then
		curl https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[].id'
	else
		curl https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[]|select(.type=="release").id'
	fi
}

dl(){
	VURL=$(curl https://launchermeta.mojang.com/mc/game/version_manifest.json | jq -r '.versions[]|select(.id=="'"$1"'").url')
	[ ! -n "$VURL" ] && log 1 "cannot find version $1" && exit 1
	mkdir -p "$BASEDIR/versions/$1"
	wget -nc -P "$BASEDIR/versions/$1" "$VURL"
	VJSONF="$BASEDIR/versions/$1/$1.json"

	# main jar
	wget_wrapper -nc "$(jq -r '.downloads.client.url' $VJSONF)" -O "$BASEDIR/versions/$1/$1.jar"

	# libraries
	mkdir -p "$BASEDIR/libraries"
	mkdir -p "$BASEDIR/versions/$1/natives"
	for LJSON in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LJSON"
		F=$(echo $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		log 1 "downloading $F"
		mkdir -p "$BASEDIR/libraries/""$(basepath $F)"
		wget_wrapper -O "$BASEDIR/libraries/$F" -nc "$(echo $LJSON | jq -r '.downloads.artifact.url')"

		NAVKEY="$(echo $LJSON | jq '.natives.linux')"

		if [ "$NAVKEY" != "null" ];then
			log 1 "downloading natives for $F"
			TMPF=$(mktemp)
			wget "$(echo $LJSON | jq -r '.downloads.classifiers.'$NAVKEY'.url')" -O "$TMPF"
			unzip -o "$TMPF" -d "$BASEDIR/versions/$1/natives"
			rm "$TMPF"
		fi
	done

	# assets
	mkdir -p "$BASEDIR/assets/objects"
	mkdir -p "$BASEDIR/assets/indexes"
	AID=$(jq -r '.assetIndex.id' "$VJSONF")
	AF="$BASEDIR/assets/indexes/$AID.json"
	wget -nc -P "$BASEDIR/assets/indexes" "$(jq -r '.assetIndex.url' "$VJSONF")"

	log 1 "downloading assets $AID"
	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo $HASH | head -c 2)
		mkdir -p "$BASEDIR/assets/objects/$HASHHEAD"
		wget_wrapper -nc -P "$BASEDIR/assets/objects/$HASHHEAD" https://resources.download.minecraft.net/$HASHHEAD/$HASH
	done

	wait
}

launch(){
	VJSONF="$BASEDIR/versions/$1/$1.json"
	[ ! -f "$VJSONF" ] && log 1 "version $1 not found" && exit 1

	OIFS=$IFS
	IFS=$'\n'
	CCONF=$VJSONF
	while NVER=$(jq -r '.inheritsFrom' "$CCONF") && [ "$NVER" != "null" ];do
		CCONF=$BASEDIR/versions/$NVER/$NVER.json
		VJSONF=$VJSONF$'\n'$CCONF
	done

	natives_directory=$BASEDIR/versions/$1/natives
	launcher_name=minecraft-launcher
	launcher_version=2.0.1003

	for LIB in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LIB"
		[ "$(echo $LIB | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LIB | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		LPATH=$(echo "$LIB" | jq -r '.downloads.artifact.path')
		if [ "$LPATH" != "null" ];then
			classpath=$classpath:$BASEDIR/libraries/$LPATH
		else
			# guess path
			NAME=$(echo "$LIB" | jq -r '.name')
			ORG=$(echo "$NAME" | cut -f 1 -d ':')
			PKG=$(echo "$NAME" | cut -f 2 -d ':')
			VER=$(echo "$NAME" | cut -f 3 -d ':')
			GPATH=$(echo "$ORG" | tr '.' '/')/$PKG/$VER/$PKG-$VER.jar
			log 2 "classpath: no path for $NAME, guess $GPATH"
			classpath=$classpath:$BASEDIR/libraries/$GPATH
		fi
	done
	classpath=$(echo "$classpath" | tail -c +2):$BASEDIR/versions/$1/$1.jar
	
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

	auth_player_name=xdavidwu
	version_name=$1
	game_directory=$BASEDIR
	assets_root=$BASEDIR/assets
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
	OIFS=$IFS
	IFS=$'\n'
	for VER in $(ls -1 "$BASEDIR/versions/");do
		[ -f "$BASEDIR/versions/$VER/$VER.json" ] && echo $VER
	done
	IFS=$OIFS
}

cksum(){
	VJSONF="$BASEDIR/versions/$1/$1.json"
	[ ! -f "$VJSONF" ] && log 1 "cannot find version $1" && exit 1

	# main jar
	sha1_chkrm "$BASEDIR/versions/$1/$1.jar" $(jq -r '.downloads.client.sha1' "$VJSONF")

	# libraries
	for LJSON in $(jq -c '.libraries[]' $VJSONF);do
		log 2 "found library $LJSON"
		F=$(echo $LJSON | jq -r '.downloads.artifact.path')
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="allow").os.name|.!=null and .!="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule allow not linux" && continue
		[ "$(echo $LJSON | jq '.rules[]|select(.action=="disallow").os.name|.!=null and .=="linux"' 2>/dev/null)" == "true" ] && log 2 "block: rule disallow linux" && continue

		sha1_chkrm "$BASEDIR/libraries/$F" "$(echo $LJSON | jq -r '.downloads.artifact.sha1')"
		# TODO find a way to cover natives?
	done

	# assets
	AID=$(jq -r '.assetIndex.id' "$VJSONF")
	AF="$BASEDIR/assets/indexes/$AID.json"
	sha1_chkrm "$AF" $(jq -r '.assetIndex.sha1' "$VJSONF")

	for HASH in $(jq -r '.objects[].hash' "$AF");do
		HASHHEAD=$(echo $HASH | head -c 2)
		sha1_chkrm "$BASEDIR/assets/objects/$HASHHEAD/$HASH" "$HASH"
	done
}

$@