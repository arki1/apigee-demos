#!/usr/bin/env bash

BASEDIR="$(dirname $0)"
pushd $BASEDIR/.. > /dev/null

PATH="./node_modules/.bin:$PATH"
apigeelint --profile apigeex -f table.js -s src/main/apigee/apiproxies/gcpreleases-v1/apiproxy/
popd > /dev/null