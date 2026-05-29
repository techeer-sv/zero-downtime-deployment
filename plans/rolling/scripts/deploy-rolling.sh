#!/bin/bash
echo "롤링 배포 기본 replica = 3"
docker compose -f rolling.yaml up -d --scale app-rolling=3