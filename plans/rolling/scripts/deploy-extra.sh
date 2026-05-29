#!/bin/bash

PARALLEL=$1

echo "롤링 배포를 위해 새로운 버젼 replica + ${PARALLEL}"

REPLICA=$((${PARALLEL} + 3))
docker compose -f rolling.yaml up -d --scale app-rolling=${REPLICA}