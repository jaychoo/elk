MAKEFLAGS += --warn-undefined-variables
SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail
.DEFAULT_GOAL := build

PHONY: *

# -------------------------------------------
# build and release

build:
	export LOGSTASH=
	docker-compose -f local-compose.yml -p elk build kibana logstash

ship:
	docker tag -f elk_kibana 0x74696d/triton-kibana
	docker tag -f elk_logstash 0x74696d/triton-logstash
	docker push 0x74696d/triton-kibana
	docker push 0x74696d/triton-logstash


# -------------------------------------------
# run on Triton

run: export LOGSTASH = n/a
run:
	./test.sh

# with 3 ES data nodes and 2 kibana app instances
scale: export LOGSTASH = n/a
scale:
	docker-compose -p elk scale elasticsearch=3
	docker-compose -p elk scale kibana=2

# run test for test-syslog, test-gelf (or test-fluentd once it works)
test-%:
	./test.sh test $*


# -------------------------------------------
# run against a local Docker environment

local: export LOGSTASH = n/a
local:
	-docker-compose -p elk stop || true
	-docker-compose -p elk rm -f || true
	docker-compose -p elk -f local-compose.yml pull
	docker-compose -p elk -f local-compose.yml build
	./test.sh -f local-compose.yml

# test for local-test-syslog, local-test-gelf
# (or local-test-fluentd once it works)
local-test-%:
	./test.sh -f local-compose.yml test $*
