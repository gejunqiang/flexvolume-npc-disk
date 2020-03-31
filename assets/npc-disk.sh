#! /bin/bash

export SCRIPT_DIR="$(cd "$(dirname ${BASH_SOURCE[0]})"; pwd)" \
	OPTION_FS_TYPE="kubernetes.io/fsType" \
	OPTION_VOLUME_NAME="kubernetes.io/pvOrVolumeName" \
	NPC_DISK_RESOURCE="${NPC_DISK_RESOURCE:-flexvolume.npc-disk/mount}" \
	NPC_DISK_RESOURCE_CAPACITY="$NPC_DISK_RESOURCE_CAPACITY"

jq() {
	"$SCRIPT_DIR/jq" "$@"
}

npc() {
	"$SCRIPT_DIR/npc-shell.sh" "$@"
}

log() {
	echo "$(date -Is) $*" >&2
}

node_instance(){
	local NODE="$1" PREFIX="npc.instance."
	kubectl get node "$NODE" -o json | jq --arg prefix "$PREFIX" '.metadata.labels//{} 
		| with_entries(select(.key|startswith($prefix))|.key|=.[($prefix|length):])'
}

find_disk(){
	local DISK_NAME="$1" INSTANCE="$2" && [ ! -z "$DISK_NAME" ] || return 2
	local ZONE="$([ ! -z "$INSTANCE" ] && jq -r '.zone//empty' <<<"$INSTANCE")"
	(export LOOKUP_NAME="$DISK_NAME"
		npc api2 'json.DiskCxts[]|select(.DiskName == env.LOOKUP_NAME)|.DiskId//empty' \
			POST "/ncv?Version=2017-12-28&Action=ListDisk${ZONE:+&ZoneId=$ZONE}" \
			"$(jq -n '{ VolumeMatchPattern:{ volumeNameList:[env.LOOKUP_NAME], volumeScopeList:["NVM"] }}')") || return 2
}

find_or_create_disk(){
	local DISK_NAME="$1" OPTIONS="$2" INSTANCE="$3" 
	[ ! -z "$DISK_NAME" ] && [ ! -z "$OPTIONS" ] && [ ! -z "$INSTANCE" ] || return 2
	local DISK_ID="$(jq -r '.["id"]//empty'<<<"$OPTIONS")" && [ ! -z "$DISK_ID" ] || {
		DISK_ID="$(find_disk "$DISK_NAME" "$INSTANCE")" && [ ! -z "$DISK_ID" ] || {
			local DISK_CAPACITY="$(jq '.capacity//empty'<<<"$OPTIONS")"
			[ ! -z "$DISK_CAPACITY" ] || DISK_CAPACITY="$(kubectl get pv "$DISK_NAME" -o json | jq -r '.spec.capacity.storage//empty')"
			[ ! -z "$DISK_CAPACITY" ] || DISK_CAPACITY="10G"
			DISK_ID="$(npc api2 'json | .DiskIds[0]//empty' \
              GET "/ncv?Action=CreateDisk&Version=2017-12-28&$(jq -r --arg name "$DISK_NAME" --arg capacity "$DISK_CAPACITY" --argjson instance "$INSTANCE" '{
                  Name: $name,
                  ZoneId: (.zone//.az//$instance.zone),
                  Scope: "NVM",
                  PricingModel: "PostPaid",
                  Type: (if .type then .type else "CloudSsd" end),
                  Capacity: ($capacity|sub("[Gg]i?$"; "") | tonumber/10 | if . > floor then floor + 1 else . end * 10)
                }|to_entries|map(@uri"\(.key)=\(.value)")|join("&")'<<<"$OPTIONS"
              )"
      )" && [ ! -z "$DISK_ID" ] || return 2
		}
	}
	wait_disk "$DISK_ID" || return 2
}

wait_disk(){
	local DISK_ID="$1" WAIT_STATUS WAIT_RESULT
	while true; do
		read -r WAIT_STATUS WAIT_RESULT < <(npc api2 'json | .DiskCxt | select(.DiskId) | .Status as $status |
      if ["creating","mounting","unmounting"]|index($status) then "wait"
      elif [".create_fail"]|index($status) then "destroy"
      else "ok \(.DiskName) \(.DiskId) \(.VolumeUUID) \(.AttachedInstance//"")"
      end' GET "/ncv?Action=DescribeDisk&Version=2017-12-28&DiskId=$DISK_ID") && case "$WAIT_STATUS" in
			ok)
				log "disk: $WAIT_RESULT"
				echo "$WAIT_RESULT"; return 0
				;;
			wait)
				log "wait disk status"
				sleep 1s; continue
				;;
			destroy)
				log "destroy disk"
				npc api2 GET "/ncv?Action=DeleteDisk&Version=2017-12-28&DiskId=$DISK_ID" >&2
				return 2
				;;
		esac
		log "failed to wait disk"
		return 2
	done
}

do_attach() {
	local OPTIONS="$1" NODE="$2" && [ ! -z "$NODE" ] || return 2
	local DISK_NAME="$(jq -r '.[env.OPTION_VOLUME_NAME]//empty'<<<"$OPTIONS")" NODE_INSTANCE="$(node_instance "$NODE")"
	[ ! -z "$DISK_NAME" ] && [ ! -z "$NODE_INSTANCE" ] || return 2
	local DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(find_or_create_disk "$DISK_NAME" "$OPTIONS" "$NODE_INSTANCE")" && [ ! -z "$DISK_ID" ] || {
		jq -nc '{status:"Failure", message:"Failed to find/create disk"}'
		return 1
	}
	local INSTANCE_ID="$(jq -r '.id//empty'<<<"$NODE_INSTANCE")" && [ ! -z "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"instance id not labeled"}'
		return 1
	}
	[ -z "$ATTACHED_INSTANCE_ID" ] || [ "$ATTACHED_INSTANCE_ID" == "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"Disk already attached"}'
		return 1
	}
	[ -z "$ATTACHED_INSTANCE_ID" ] && {
		npc api2 GET "/nvm?Action=AttachDisk&Version=2017-12-14&InstanceId=$INSTANCE_ID&DiskId=$DISK_ID" >&2 || {
			jq -nc '{status:"Failure", message:"Failed to attach disk"}'
			return 1
		}
		read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID <<<"$(wait_disk "$DISK_ID")" && [ ! -z "$ATTACHED_INSTANCE_ID" ] || return 2
	}
	DEVICE="$DISK_NAME:$DISK_ID:${DISK_UUID,,}:$INSTANCE_ID" jq -nc '{status:"Success", device: env.DEVICE}'
}

do_detach() {
	local DISK_NAME="$1" NODE_INSTANCE="$(node_instance "$2")" && [ ! -z "$DISK_NAME" ] && [ ! -z "$NODE_INSTANCE" ] || return 2
	local INSTANCE_ID="$(jq -r '.id//empty'<<<"$NODE_INSTANCE")" ATTACHED_INSTANCE_ID && [ ! -z "$INSTANCE_ID" ] || {
		jq -nc '{status:"Failure", message:"instance id not labeled"}'
		return 1
	}
	local DISK_ID="$(find_disk "$DISK_NAME" "$NODE_INSTANCE")" && [ ! -z "$DISK_ID" ] && \
		read -r _ _ _ ATTACHED_INSTANCE_ID <<<"$(wait_disk "$DISK_ID")" && [ "$ATTACHED_INSTANCE_ID" == "$INSTANCE_ID" ] && {
			npc api2 GET "/nvm?Action=DetachDisk&Version=2017-12-14&InstanceId=$ATTACHED_INSTANCE_ID&DiskId=$DISK_ID" >&2 || {
				jq -nc '{status:"Failure", message:"Failed to detach disk"}'
				return 1
			}
		}
	jq -nc '{status:"Success"}'
}

do_waitforattach() {
	local DEVICE="$1" OPTIONS="$2"
	DEVICE="$DEVICE" jq -nc '{status:"Success", device: env.DEVICE}'
}

do_isattached() {
	local OPTIONS="$1" NODE="$2"
	jq -nc '{status:"Success", attached: true}'
}

do_mountdevice() {
	local MOUNTPATH="$1" DEVICE="$2" OPTIONS="$3" DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID
	IFS=':' read -r DISK_NAME DISK_ID DISK_UUID ATTACHED_INSTANCE_ID<<<"$DEVICE" && [ ! -z "$DISK_UUID" ] || return 2
	mountpoint -q "$MOUNTPATH" || {
		local NAME UUID FSTYPE MOUNTPOINT SERIAL \
			FOUND_DEVICE FOUND_FSTYPE FOUND_MNT
		while IFS=',' read -r _ NAME UUID FSTYPE MOUNTPOINT; do
			[ ! -z "$MOUNTPOINT" ] && {
				[ "$MOUNTPOINT" == "$MOUNTPATH" ] && FOUND_MNT="$NAME" && break
				continue
			}
			[ ! -z "$FSTYPE" ] && {
				[ "${UUID,,}" == "${DISK_UUID}" ] && FOUND_FSTYPE="$FSTYPE" && break
				continue
			}
			SERIAL="$(udevadm info -q property -n "/dev/$NAME" | sed -n 's/^ID_SERIAL=\(.*\)/\1/p')" && [ ! -z "$SERIAL" ] && {
				[ "${SERIAL,,}" == "${DISK_UUID:0:20}" ] && FOUND_DEVICE="/dev/$NAME" && break
			}
		done < <(lsblk -o 'TYPE,NAME,UUID,FSTYPE,MOUNTPOINT' -bdsrn | tr ' ' ',' | grep '^disk,')
		[ ! -z "$FOUND_MNT" ] || {
			[ ! -z "$FOUND_FSTYPE" ] || {
				[ ! -z "$FOUND_DEVICE" ] || {
					jq -nc '{status:"Failure", message:"device not found"}'
					return 1
				}
				FOUND_FSTYPE="$(jq -r '.[env.OPTION_FS_TYPE]//empty'<<<"$OPTIONS")"
				mkfs -t "${FOUND_FSTYPE:-ext4}" -U "$DISK_UUID" "$FOUND_DEVICE" >&2 || {
					jq -nc '{status:"Failure", message:"failed to mkfs"}'
					return 1
				}
			}
			mkdir -p "$MOUNTPATH" >&2 && mount -t "${FOUND_FSTYPE:-ext4}" "UUID=$DISK_UUID" "$MOUNTPATH" >&2 || {
				jq -nc '{status:"Failure", message:"failed to mount device"}'
				return 1
			}
		}
	}
	jq -nc '{status:"Success"}'
}

do_unmountdevice() {
	local MOUNTPATH="$1"
	! mountpoint -q "$MOUNTPATH" || umount "${MOUNTPATH}" >&2 || {
		jq -nc '{status:"Failure", message:"failed to mount device"}'
		return 1
	}
	rm -fr "${MOUNTPATH}"
	jq -nc '{status:"Success"}'
}

{
	log "$@"
	if ACTION="do_$1" && shift; then
		if declare -F "$ACTION" >/dev/null; then
			ACTION_CMD=("$ACTION" "$@")
		elif [ -x "$SCRIPT_DIR/$ACTION.sh" ]; then
			ACTION_CMD=("$SCRIPT_DIR/dumb-init" "$SCRIPT_DIR/$ACTION.sh" "$@")
		else
			jq -nc '{status:"Not supported"}'
			exit 1	
		fi
		"${ACTION_CMD[@]}" || case "$?" in
		1)
			exit 1
			;;
		*)
			jq -nc '{status:"Failure", message:"Something wrong"}'
			exit 1
			;;
		esac
	else
		jq -nc '{status:"Not supported"}'
		exit 1	
	fi
} 2> >( if [ ! -z "$NPC_DISK_SYSLOG" ]; then
		systemd-cat -t "$NPC_DISK_SYSLOG" &>/dev/null
	else
		cat &>>${NPC_DISK_LOG:-/dev/null}
	fi )
