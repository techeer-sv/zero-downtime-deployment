#!/bin/bash

docker compose -f green.yaml up -d --scale app-green=3