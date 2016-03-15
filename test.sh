#!/bin/bash
set -e -o pipefail

help() {
    echo 'Usage ./test.sh [-f docker-compose.yml] [-p project] [args]'
    echo
    echo 'Optional args'
    echo '  run:            [default] starts up the entire stack and runs the test clients.'
    echo '  check:          verify your local environment is correctly configured.'
    echo '  show:           open web pages of an already running stack.'
    echo '  test <logtype>: run test client against an already running stack. logtype'
    echo '                  should be one of: syslog, gelf'
    echo '  help            help. you are reading it now.'
    echo
    echo 'Optional flags:'
    echo '  -f <filename>   use this file as the docker-compose config file'
    echo '  -p <project>    use this name as the project prefix for docker-compose'
    echo
}


# default values which can be overriden by -f or -p flags
export COMPOSE_PROJECT_NAME=elk
export COMPOSE_FILE=

# give the docker remote api more time before timeout
export COMPOSE_HTTP_TIMEOUT=300


# ---------------------------------------------------
# Top-level commmands

run() {
    docker-compose up -d \
               elasticsearch \
               elasticsearch_master \
               kibana \
               logstash
    show
    test
}

show() {
    # poll Consul for liveness and then open the console
    poll-for-page "http://$(getIpPort consul 8500)/ui/" \
                  'Waiting for Consul...' \
                  'Opening Consul console... Refresh the page to watch services register.'

    # poll Kibana for liveness and then open the page
    poll-for-page "http://$(getIpPort kibana 5601)/app/kibana#discover" \
                  'Waiting for Kibana to register as healthy...' \
                  'Opening Kibana console.'
}

# Run test clients
test() {
    local logtype=$1
    local port
    local protocol=tcp
    case $logtype in
        gelf)
            port=12201
            protocol=udp
            ;;
        syslog)
            port=514 ;;
        # Triton supports fluentd but logstash codec support is broken:
        # https://github.com/logstash-plugins/logstash-codec-fluent/issues/2
        # https://github.com/logstash-plugins/logstash-codec-fluent/pull/5
        # fluentd)
        #    port=24224 ;;
        *)
            echo 'logtype arguments required: gelf or syslog'
            exit 1;;
    esac

    echo 'Starting Nginx log source...' && \
        CONSUL=$(getPrivateIpPort consul 8500 tcp) \
        LOGSTASH=$(getPrivateIpPort logstash $port $protocol) \
        CONTAINERBUDDY="$(cat ./nginx/containerbuddy.json)" \
        NGINX_CONF="$(cat ./nginx/nginx.conf)" \
        docker-compose -f test-compose.yml up -d nginx_$logtype

    poll-for-page "http://$(getIpPort nginx_$logtype 80)" \
                  'Waiting for Nginx to register as healthy...' \
                  'Opening web page.'
}



# ---------------------------------------------------
# utility functions

# check for prereqs
check() {
    command -v docker >/dev/null 2>&1 || {
        echo
        tput rev  # reverse
        tput bold # bold
        echo 'Docker is required, but does not appear to be installed.'
        echo 'See https://docs.joyent.com/public-cloud/api-access/docker'
        exit 1
    }
    command -v json >/dev/null 2>&1 || {
        echo
        tput rev  # reverse
        tput bold # bold
        echo 'Error! JSON CLI tool is required, but does not appear to be installed.'
        tput sgr0 # clear
        echo 'See https://apidocs.joyent.com/cloudapi/#getting-started'
        exit 1
    }

    # if we're not testing on Triton, don't bother checking Triton config
    if [ ! -z "${COMPOSE_FILE}" ]; then
        exit 0
    fi

    command -v triton >/dev/null 2>&1 || {
        echo
        tput rev  # reverse
        tput bold # bold
        echo 'Error! Joyent Triton CLI is required, but does not appear to be installed.'
        tput sgr0 # clear
        echo 'See https://www.joyent.com/blog/introducing-the-triton-command-line-tool'
        exit 1
    }

    # make sure Docker client is pointed to the same place as the Triton client
    local docker_user=$(docker info 2>&1 | awk -F": " '/SDCAccount:/{print $2}')
    local triton_user=$(triton profile get | awk -F": " '/account:/{print $2}')
    local docker_dc=$(echo $DOCKER_HOST | awk -F"/" '{print $3}' | awk -F'.' '{print $1}')
    local triton_dc=$(triton profile get | awk -F"/" '/url:/{print $3}' | awk -F'.' '{print $1}')

    if [ ! "$docker_user" = "$triton_user" ] || [ ! "$docker_dc" = "$triton_dc" ]; then
        echo
        tput rev  # reverse
        tput bold # bold
        echo 'Error! The Triton CLI configuration does not match the Docker CLI configuration.'
        tput sgr0 # clear
        echo
        echo "Docker user: ${docker_user}"
        echo "Triton user: ${triton_user}"
        echo "Docker data center: ${docker_dc}"
        echo "Triton data center: ${triton_dc}"
        exit 1
    fi

    local triton_cns_enabled=$(triton account get | awk -F": " '/cns/{print $2}')
    if [ ! "true" == "$triton_cns_enabled" ]; then
        echo
        tput rev  # reverse
        tput bold # bold
        echo 'Error! Triton CNS is required and not enabled.'
        tput sgr0 # clear
        echo
        exit 1
    fi
}

# get the IP:port of a container via either the local docker-machine or from
# triton CLI
getIpPort() {
    if [ -z "${COMPOSE_FILE}" ]; then
        local ip=$(triton inst get ${COMPOSE_PROJECT_NAME}_$1_1 | json -a ips.1)
    else
        local ip=$(docker-machine ip default)
    fi
    local port=$(getPort $1 $2 $3)
    echo "$ip:$port"
}

# get the IP:port of a container's private IP via `docker exec`
getPrivateIpPort() {
    local ip=$(docker exec -it ${COMPOSE_PROJECT_NAME}_$1_1 ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
    local port=$(getPort $1 $2 $3)
    echo "$ip:$port"
}

# get the mapped port number for a given container's port and protocol
getPort() {
    local protocol=$3
    if [ -z $protocol ]; then
        protocol='tcp'
    fi
    if [ -z "${COMPOSE_FILE}" ]; then
        local port=$2
    else
        local port=$(docker inspect ${COMPOSE_PROJECT_NAME}_$1_1 | json -a NetworkSettings.Ports."$2/$protocol" | json -a HostPort | sort -nb | head -1)
    fi
    echo $port
}

# usage: poll-for-page <url> <pre-message> <post-message>
poll-for-page() {
    echo "$2"
    while :
    do
        curl --fail -s -o /dev/null "$1" && break
        sleep 1
        echo -ne .
    done
    echo
    echo "$3"
    open "$1"
}

doStuff() {
    echo doStuff
}

# ---------------------------------------------------
# parse arguments

while getopts "f:p:h" optchar; do
    case "${optchar}" in
        f) export COMPOSE_FILE=${OPTARG} ;;
        p) export COMPOSE_PROJECT_NAME=${OPTARG} ;;
    esac
done
shift $(expr $OPTIND - 1 )

until
    cmd=$1
    if [ ! -z "$cmd" ]; then
        shift 1
        $cmd "$@"
        if [ $? == 127 ]; then
            help
        fi
        exit
    fi
do
    echo
done

# default behavior
check
echo "Starting example application"
echo "project prefix:      $COMPOSE_PROJECT_NAME"
echo "docker-compose file: $COMPOSE_FILE"
run
