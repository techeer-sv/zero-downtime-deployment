#!/bin/bash

docker compose -f blue.yaml up -d --scale app-blue=3