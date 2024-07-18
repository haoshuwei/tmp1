#!/usr/bin/env bash

################################################
#
# KUBE_VERSION     the expected kubernetes version
# eg.  ./attach_node.sh
#           --docker-version 17.06.2-ce-1 \
#           --token 264db1.30bcc2b89969a4ca \
#           --endpoint 192.168.0.80:6443
#           --cluster-dns 172.19.0.10
################################################

set -e -x

PKG=pkg
RUN=run

export openapi=http://cs-anony.aliyuncs.com
export GPU_FOUNDED=0
export HTTP_META="curl --retry 30 --retry-delay 5 -sSL http://100.100.100.200/latest/meta-data"
export DISABLE_SWAP=0

# Set default cloudtype to public
if [ "$CLOUD_TYPE" == "" ]; then
    export CLOUD_TYPE=public
fi

if [ "$BETA_VERSION" != "" ]; then
    export BETA_PATH=\/$BETA_VERSION
fi

public::common::log() {
    echo $(date +"[%Y%m%d %H:%M:%S]: ") $1
}

public::common::region() {
    if [ "$CLOUD_TYPE" == "public" ]; then
        region=$(${HTTP_META}/region-id)
        if [ "" == "$region" ]; then
            kube::common::log "can not get regionid and instanceid! ${HTTP_META}/region-id" && exit 256
        fi
        export REGION=$region
    else
        public::common::log "Do nothing for aglity"
    fi
}

public::common::region

# 安装Kubernetes时候会启动一些AddOn插件的镜像。
# 改插件设置镜像仓库的前缀。
if [ "$KUBE_REPO_PREFIX" == "" ]; then
    export KUBE_REPO_PREFIX=registry-vpc.$REGION.aliyuncs.com/acs
fi

public::common::prepare_package() {
    PKG_TYPE=$1
    PKG_VERSION=$2
    if [ ! -f ${PKG_TYPE}-${PKG_VERSION}.tar.gz ]; then
        if [ -z $PKG_FILE_SERVER ]; then
            public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, And PKG_FILE_SERVER is not config"
            public::common::log "installer does not known where to download installer binary package without PKG_FILE_SERVER env been set. Error: exit"
            exit 1
        fi
        public::common::log "local file ${PKG_TYPE}-${PKG_VERSION}.tar.gz does not exist, trying to download from [$PKG_FILE_SERVER]"
        curl --retry 4 $PKG_FILE_SERVER/$CLOUD_TYPE/pkg/$PKG_TYPE/${PKG_TYPE}-${PKG_VERSION}.tar.gz \
            >${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "download failed with 4 retry,exit 1" && exit 1)
    fi
    tar -xvf ${PKG_TYPE}-${PKG_VERSION}.tar.gz || (public::common::log "untar ${PKG_VERSION}.tar.gz failed!, exit" && exit 1)
}

public::common::os_env() {

	set +e
    grep -q "Ubuntu" /etc/os-release && export OS="Ubuntu" && return
    grep -q "SUSE" /etc/os-release && export OS="SUSE" && return
    grep -q "Red Hat" /etc/os-release && export OS="RedHat" && return
    grep -q "CentOS Linux" /etc/os-release && export OS="CentOS" && return
    grep -q "Aliyun Linux" /etc/os-release && export OS="AliyunOS" && return
    grep -q "Alibaba Cloud Linux" /etc/os-release && export OS="AliyunOS" && return
    grep -q "Alibaba Group Enterprise Linux" /etc/os-release && export OS="AliOS" && return
	set -e

    public::common::log "unknown os...  exit."
    exit 1
}

public::common::get_node_info() {
    if [ "$CLOUD_TYPE" == "public" ]; then
        insid=$(${HTTP_META}/instance-id)
        # openapi_vpc_regions=("cn-north-2-gov-1" "cn-shenzhen-finance-1" "cn-shanghai-finance-1" "cn-hangzhou-finance" "cn-wulanchabu" "cn-heyuan" "cn-qingdao" "rus-west-1")

        if [ ! -z "$REGION" ]; then
            # set defualt to regional openapi endpoint
            # export openapi="http://cs-anony.${REGION}.aliyuncs.com"
            # for openapi_vpc_region in ${openapi_vpc_regions[@]};
            # do
            #    if [ "$REGION" == "$openapi_vpc_region" ]; then
                    # if matched, change to vpc openapi endpoint
                   export openapi="http://cs-anony-vpc.${REGION}.aliyuncs.com"
            #       break
            #   fi
            #done
        fi
        info=$(curl --retry 5 -H "Date:$(date -R)" -sfSL "$openapi/token/${OPENAPI_TOKEN}/instance/${insid}/node_info" | grep '\w')
        eval "$info"
        export CALLBACK_URL=$(echo "$callback_url" | sed "s#cs-anony.*aliyuncs.com#cs-anony-vpc.${REGION}.aliyuncs.com#")
        export DOCKER_VERSION=$docker_version
        export CLUSTER_DNS=$cluster_dns
        export TOKEN=$token
        export ENDPOINT=$endpoint
        export APISERVER_LB=${ENDPOINT//:6443/}
        if [ "$NAME_MODE" == "" ]; then
            export NAME_MODE=$name_mode
        fi
        if [ -n "$network" ]; then
            export NETWORK="$network"
        fi
    fi
}

public::common::callback() {
    if [ "$CLOUD_TYPE" != "public" ]; then return; fi

    curl -H "Date:$(date -R)" -X POST -sfSL "${CALLBACK_URL}"
    echo "====================================================================="
    echo "                              SUCCESS                                "
    echo "====================================================================="
}

public::main::cleanup() {
    set +e
    ip link del cni0
    rm -rf /var/lib/cni/*
    rm -rf /etc/kubernetes
    docker ps | grep k8s_ | awk '{print $1}' | xargs -I '{}' docker stop {}
    if [ -d "/var/lib/kubelet/pki/" ]; then
        now=$(date "+%Y-%m-%d-%H-%M-%S")
        mv /var/lib/kubelet/pki/ /var/lib/kubelet/pki-$now
    fi
    systemctl stop kubelet
    rm -rf /var/lib/kubelet/cpu_manager_state
    if [ "$OS" == "CentOS" ] || [ "$OS" == "RedHat" ] || [ "$OS" == "AliOS" ] || [ "$OS" == "AliyunOS" ]; then
      timeout 60 yum remove -y kubectl kubeadm kubelet kubernetes-cni
      echo "done yum remove -y kubectl kubeadm kubelet kubernetes-cni"
    elif [ "$OS" == "Ubuntu" ]; then
      timeout 60 apt purge -y kubectl kubeadm kubelet kubernetes-cni
      echo "done apt purge -y kubectl kubeadm kubelet kubernetes-cni"
    fi
    set -e
}

public::main::clean_cache() {
	rm -rf ./{addons-$KUBE_VERSION.tar.gz,\
run-$RUN_VERSION.tar.gz,\
kubernetes-$KUBE_VERSION.tar.gz,\
docker-$DOCKER_VERSION.tar.gz,\
$RUNTIME-$RUNTIME_VERSION.tar.gz}
}

public::attach::node() {
    public::common::prepare_package "run" "$KUBE_VERSION"

    if [[ $KUBE_VERSION == 1.18* ]]; then
      export RUN_VERSION=$KUBE_VERSION
      ## Args parse happened Here.
      #
      source $PKG/$RUN/$KUBE_VERSION/kubernetes.sh --role source

      public::common::parse_args $ALL_ARGS
      public::node::deploy
    else
      ROLE="deploy-nodes" $PKG/$RUN/$KUBE_VERSION/bin/kubernetes.sh $args
    fi
}

public::main::disableswap() {
    if [ "$DISABLE_SWAP" = "1" ]; then
        swap=$(swapon -s)
        if [ -n "$swap" ]; then
            swapoff -a
            sed -i '/swap/d' /etc/fstab
        fi
    fi
}

rewrite_args() {
    args=""
    while [[ $# -gt 0 ]]; do
        local key="$1"
        case $key in
        --kube-version)
            shift
            ;;
        *)
            args+=$key
            args+=" "
            ;;
        esac
        shift
    done
    export ALL_ARGS="$args"
}

parse_args() {
    while
        [[ $# -gt 0 ]]
    do
        key="$1"
        case $key in
        --kube-version)
            shift
            ;;
        --runtime)
            export RUNTIME=$2
            shift
            ;;
        --runtime-version)
            export RUNTIME_VERSION=$2
            shift
            ;;
        --docker-version)
            export DOCKER_VERSION=$2
            shift
            ;;
        --cluster-dns)
            export CLUSTER_DNS=$2
            shift
            ;;
        --token)
            export TOKEN=$2
            shift
            ;;
        --ip-vlan-enabled)
            export IPVLAN_ENABLED=$2
            shift
            ;;
        --endpoint)
            export ENDPOINT=$2
            export APISERVER_LB=${ENDPOINT//:6443/}
            shift
            ;;
        --openapi-token)
            export OPENAPI_TOKEN=$2
            shift
            ;;
        --ess)
            export FROM_ESS=$2
            export AUTO_FDISK=1
            shift
            ;;
        --auto-fdisk)
            export AUTO_FDISK=1
            ;;
        --disk-device)
            export DISK_DEVICE=$2
            shift
            ;;
        --labels)
            export LABELS=$2
            shift
            ;;
        --taints)
            export TAINTS=$2
            shift
            ;;
        --node-config)
            export NODE_CONFIG=$2
            shift
            ;;
        --node-name-mode)
            export NAME_MODE=$2
            shift
            ;;
        --beta-version)
            export BETA_PATH=\/$2
            shift
            ;;
        --cpu-policy)
            export CPU_POLICY=$2
            shift
            ;;
        --cluster-domain)
            export CLUSTER_DOMAIN=$2
            shift
            ;;
        --network)
            export NETWORK=$2
            shift
            ;;
        --addon-names)
            export ADDON_NAMES=$2
            shift
            ;;
        --node-port-range)
            export NODE_PORT_RANGE=$2
            shift
            ;;
        --overwrite-hostname)
            export OVERWRITE_HOSTNAME=$2
            shift
            ;;
        --cluster-type)
            export CLUSTER_TYPE=$2
            shift
            ;;
        --disable-swap)
            export DISABLE_SWAP=1
            ;;
        *)
            public::common::log "unknown option [$key]"
            ;;
        esac
        shift
    done
}

common::validate() {
    if [ "$DOCKER_VERSION" == "" -a "$RUNTIME" == "" ]; then
        public::common::log "DOCKER_VERSION or RUNTIME is not set."
        exit 1
    fi

    # 首先从本地读取相应版本的tar包。当所需要的安装包不存在的时候
    # 如果设置了参数PKG_FILE_SERVER，就从该Server上下载。
    # 如果是在公有云上执行，可以使用内网oss地址
    if [ "$PKG_FILE_SERVER" == "" ]; then
        export PKG_FILE_SERVER=http://aliacs-k8s-$REGION.oss-$REGION-internal.aliyuncs.com$BETA_PATH
    fi

    ## retry to get kubernetes version information in case of apiserver temp failure
    if [[ "$KUBE_VERSION" == "" ]]; then
        cnt=0
        while ((cnt <= 120)); do
            KUBE_VERSION=$(
                curl -k --connect-timeout 4 https://${APISERVER_LB}:6443/version |
                    grep gitVersion | awk '{print $2}' | cut -f2 -d \"
            )
            if [[ "$KUBE_VERSION" == "" ]]; then
                echo "can not get kubeversion from apiserver, retry"

                # curl again for specific error
                set +e
                curl -k --connect-timeout 4 https://${APISERVER_LB}:6443/version
                set -e
                # sleep & continue
                ((cnt += 1))
                sleep 2
                continue
            fi
            export KUBE_VERSION=${KUBE_VERSION:1}
            break
        done
    fi
    if [[ "$KUBE_VERSION" == "" ]]; then
        # Using default cidr.
        public::common::log "KUBE_VERSION $KUBE_VERSION is failed to set."
        exit 1
    fi

    if [ "$TOKEN" == "" ]; then
        # Using default cidr.
        public::common::log "TOKEN $TOKEN is not set."
        exit 1
    fi

    if [ "$CLUSTER_DNS" == "" ]; then
        # Using default cidr.
        public::common::log "CLUSTER_DNS $CLUSTER_DNS is not set."
        exit 1
    fi

    # Aone #37545945
    if [[ `rpm -qa systemd` < "systemd-219-67" ]]; then
        public::common::log "warning: systemd version must more then 219.67, try update"
        yum update -y systemd
    fi
}



main() {
    rewrite_args "$@"
    parse_args "$@"

    if [ "$OPENAPI_TOKEN" != "" ]; then
        public::common::get_node_info
    fi

    common::validate
    public::common::os_env

    # Do some clean up
    if ! grep -q "ACK-Optimized-OS" /etc/image-id; then
        public::main::cleanup
    fi

    public::main::disableswap
    public::attach::node

    if [ "$OPENAPI_TOKEN" != "" ]; then public::common::callback; fi

    public::main::clean_cache
    if [[ $KUBE_VERSION == 1.18* ]]; then
      export ATTACH_NODE="True"
      public::common::worker::dengbao
    fi
}

main "$@"
