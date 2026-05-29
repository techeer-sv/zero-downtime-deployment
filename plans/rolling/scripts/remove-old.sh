#!/bin/bash

CONTAINER_NAME=$1

echo "이전 버젼 컨테이너 ${CONTAINER_NAME} 제거 진행"

echo "컨테이너 중지"
docker stop ${CONTAINER_NAME}
sleep 2
echo "컨테이너 제거"
docker rm ${CONTAINER_NAME}