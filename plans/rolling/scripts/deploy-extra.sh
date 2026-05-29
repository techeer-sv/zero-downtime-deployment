#!/bin/bash

export IMAGE_TAG=$1
PARALLEL=$2

if [ -z "${PARALLEL}" ]; then
  echo "병렬 수가 지정되지 않았습니다. 기본값 1을 사용합니다."
  PARALLEL=1
fi

echo "롤링 배포를 위해 새로운 버젼 replica + ${PARALLEL}"

REPLICA=$((${PARALLEL} + 3))
docker compose -f rolling.yaml up -d --scale app-rolling=${REPLICA} --no-deps --no-recreate