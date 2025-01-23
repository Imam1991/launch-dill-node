#!/bin/bash

_ROOT="$(pwd)" && cd "$(dirname "$0")" && ROOT="$(pwd)"
PJROOT="$ROOT"
DILL_DIR=""
DILL_BACKUP_DIR=""
DILL_VERSION=""
OS_TYPE=""

tlog() {
    echo "$(date '+%Y-%m-%d %H:%M:%S %Z') > $*"
}

get_latest_version() {
    latest_release_url="https://dill-release.s3.ap-southeast-1.amazonaws.com/version.txt"
    DILL_VERSION=`curl -s $latest_release_url`
    return $?
}

is_dill_folder() {
    dir=$1
    if [ -z "$dir" ]; then
        return 1
    fi

    if [ ! -f "$dir/genesis.ssz" ]; then
        return 1
    fi

    md5cmd=md5sum
    if [ "$OS_TYPE" == "darwin" ]; then
        md5cmd=md5
    fi

    md5=`$md5cmd $dir/genesis.ssz | grep 4d597f491aec977da43d17fd3e6768a9`
    if [ -z "$md5" ]; then
        return 1
    fi

    return 0
}

find_dill_folder() {
    dill_proc=`ps -ef | grep dill | grep -v grep `
    if [ ! -z "$dill_proc" ]; then
        tmp=${dill_proc#*--datadir }
        DILL_DIR=`dirname ${tmp%% *}`
        DILL_DIR=`dirname $DILL_DIR`
        DILL_DIR=`dirname $DILL_DIR`
    fi

    is_dill_folder $DILL_DIR
    if [ $? -eq 0 ]; then
        return 0
    fi

    DILL_DIR=$PJROOT
    is_dill_folder $DILL_DIR
    if [ $? -eq 0 ]; then
        return 0
    fi

    DILL_DIR=$PJROOT/dill
    is_dill_folder $DILL_DIR
    if [ $? -eq 0 ]; then
        return 0
    fi

    return 1
}

check_health() {
    dill_proc=`ps -ef | grep dill | grep -v grep `
    if [ ! -z "$dill_proc" ]; then
        return 0
    else
        return 1
    fi
}

download_assets() {
    BASE_URL="https://dill-release.s3.ap-southeast-1.amazonaws.com/$DILL_VERSION/$OS_TYPE"
    DILL_ASSETS_LIST_URL="$BASE_URL/assets.txt"
    curl -O $DILL_ASSETS_LIST_URL
    while read file; do
        tlog upgrading $file
        [ -f "$file" ] && mv $file $DILL_BACKUP_DIR/$file
        curl -O "$BASE_URL/$file"
        if [ $? -ne 0 ]; then
            tlog upgrade $file failed
            return 1
        fi
        # grant exe perm to shell scripts
        extension="${file##*.}"
        if [ "$extension" == "sh" ]; then
            chmod +x $file
        fi
    done < ./assets.txt
}

is_latest_dill_running() {
    check_health
    if [ $? -ne 0 ]; then
        return 1
    fi
    dill_proc=`ps -ef | grep dill | grep -v grep | grep 0x1a5E568E5b26A95526f469E8d9AC6d1C30432B33`
    grpc_gateway_port=$(echo $dill_proc | awk -F --grpc-gateway-port '{print $2}' | awk -F ' ' '{print $1}')
    curl -s localhost:${grpc_gateway_port}/eth/v1/node/version | grep $DILL_VERSION >> /dev/null
    return $?
}

find_os_type() {
    # Ask for OS type
    os_type=$(uname)   # Darwin or Linux
    chip=$(uname -m)

    if [ "$os_type" == "Darwin" ];then
        if [ "$chip" == "arm64" ];then
            echo "Supported, os_type: $os_type, chip: $chip"
            if [ "$download" != "0" ];then
                OS_TYPE="darwin"
            fi
        else
            echo "Unsupported, os_type: $os_type, chip: $chip"
            return 1
        fi
    else
        if [ "$chip" == "x86_64" ] && [ -f /etc/os-release ];then
            if ! grep -qi "flags.*:.*adx" /proc/cpuinfo; then
                echo "Warn: The cpu lacks the required instruction set extension (adx) and may not run properly."
                echo "But you can also try. Press any key to continue..."
                read -n 1 -s -r
            fi

            source /etc/os-release
            if [ "$ID" == "ubuntu" ];then
                major_version=$(echo $VERSION_ID | cut -d. -f1)
                if [ $major_version -ge 20 ]; then
                    echo "Supported, os: $ID $VERSION_ID, chip: $chip"; echo""
                    if [ "$download" != "0" ];then
                        OS_TYPE="linux"
                    fi
                else
                    echo "Unsupported, os: $ID $VERSION_ID (ubuntu 20.04+ required)"
                    return 1
                fi
            else
                echo "Unsupported, os_type: $os_type, chip: $chip, $ID $VERSION_ID"
                return 1
            fi
        else
            echo "Unsupported, os_type: $os_type, chip: $chip"
            return 1
        fi
    fi
}

function upgrade_dill() {
    cd $DILL_DIR
    now=`date +%s`
    DILL_BACKUP_DIR="$DILL_DIR/backups/$now"
    mkdir -p $DILL_BACKUP_DIR
    tlog upgrading dill node
    tlog current scripts or binary files will be moved to $DILL_BACKUP_DIR

    base_url="https://dill-release.s3.ap-southeast-1.amazonaws.com/$DILL_VERSION"

    # download scripts
    download_assets
    if [ $? -ne 0 ]; then
        tlog download script files failed
        return 1
    fi

    chmod +x ./stop_dill_node.sh
    chmod +x ./start_dill_node.sh

    curl -o dill-node-new $base_url/$OS_TYPE/dill-node
    chmod +x dill-node-new
    ./dill-node-new --version | grep $DILL_VERSION
    if [ $? -ne 0 ]; then
        tlog binary downloaded is not the latest one, please contact dill team
        return 1
    fi

    # update binaries
    [ -f "dill-node" ] && mv dill-node $DILL_BACKUP_DIR/dill-node-back
    mv dill-node-new dill-node
    
    ./stop_dill_node.sh
    if [ $? -ne 0 ]; then
        tlog stop dill node failed
        return 1
    fi
    
    ./start_dill_node.sh
    if [ $? -ne 0 ]; then
        tlog start dill node failed
        return 1
    fi
}

download=1
if [ $# -ge 1 ];then
    download=$1
fi

find_os_type
if [ $? -ne 0 ]; then
    tlog get os type failed
    exit 1
fi

get_latest_version
if [ $? -ne 0 ]; then
    tlog get latest dill version failed
    exit 1
fi

is_latest_dill_running
if [ $? -eq 0 ]; then
    tlog current running dill version is latest version $DILL_VERSION, no need to upgrade
    exit 1
fi

find_dill_folder
if [ $? -ne 0 ]; then
    tlog dill folder not found
    exit 1
fi

tlog found dill folder at $DILL_DIR

upgrade_dill
if [ $? -ne 0 ]; then
    tlog upgrade dill failed
    exit 1
fi
