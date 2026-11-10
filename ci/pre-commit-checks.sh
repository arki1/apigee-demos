#!/usr/bin/env bash

BASEDIR="$(dirname $0)"

# TODO(ronoaldo): spin up the emulator and deploy the proxy locally.

# Detects the emulator image
IMAGE_ID="$(docker images --format='{{ printf "%v,%v" .Repository .ID }}' |\
    grep apigee-emulator | cut -f 2 -d,)"

[ -z "${IMAGE_ID}" ] && {
    echo "Emulator image not found"
    exit 1
}

# Detects the running port
HOST_PORT="$(docker ps --filter ancestor=${IMAGE_ID} --format='{{.Ports}}' |\
    tr -d ' ' | tr ',' '\n' | grep 8998 | cut -f 1 -d '-')"

[ -z "${HOST_PORT}" ] && {
    echo "Emulator port not found"
    exit 1
}

echo "Validating proxy"
${BASEDIR}/lint.sh

echo "Setting up dependencies with npm ..."
npm install --quiet

echo "Running unit tests ..."
npm test

echo "Running integration tests ..."
APIGEE_HOST=${HOST_PORT}/gcpreleases/v1 npm run integration-test

echo "DONE"