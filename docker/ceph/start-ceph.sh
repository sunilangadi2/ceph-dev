#!/bin/bash

set -e

source /docker/set-start-env.sh

# Build frontend:
if [[ "$FRONTEND_BUILD_REQUIRED" == 1 ]]; then
    cd "$MGR_PYTHON_PATH"/dashboard/frontend

    # Set dev server proxy:
    DASHBOARD_URL="\"$HTTP_PROTO://localhost:$CEPH_MGR_DASHBOARD_PORT\""
    [[ -n "$REMOTE_DASHBOARD_URL" ]] && DASHBOARD_URL="\"$REMOTE_DASHBOARD_URL\""
    jq '.["/api/"].target'="$DASHBOARD_URL" proxy.conf.json.sample | jq '.["/ui-api/"].target'="$DASHBOARD_URL" > proxy.conf.json

    if [[ "$CEPH_VERSION" == '13' ]]; then
        rm -rf package-lock.json node_modules/@angular/cli
        npm update @angular/cli
    fi

    npm ci

    if [[ -z "$REMOTE_DASHBOARD_URL" ]]; then
        # Required to run dashboard python module.
        npm run build
    fi

    # Start dev server
    if [[ "$DASHBOARD_DEV_SERVER" == 1 || -n "$REMOTE_DASHBOARD_URL" ]]; then
        npm run start &
    elif [[ -z "${E2E_CMD}" ]]; then
        npm run build -- ${FRONTEND_BUILD_OPTIONS} --watch &
    fi
fi

if [[ -n "$REMOTE_DASHBOARD_URL" ]]; then
    [[ "$FRONTEND_BUILD_REQUIRED" != 1 ]] && echo 'ERROR: ceph repo not found.' && exit 1
    exit 0
fi

rm -rf "$CEPH_CONF_PATH"/*

cd /ceph/build
../src/vstart.sh ${VSTART_OPTIONS}

echo 'vstart.sh completed!'

# Create rbd pool:
"$CEPH_BIN"/ceph osd pool create rbd-pool 8 8 replicated
"$CEPH_BIN"/ceph osd pool application enable rbd-pool rbd

# Configure Object Gateway:
if [[ "$RGW" -gt 0  ||  "$RGW_MULTISITE" == 1 ]]; then
    /docker/set-rgw.sh
fi

# Enable prometheus module
if [[ "$IS_FIRST_CLUSTER" == 1 ]]; then
    "$CEPH_BIN"/ceph mgr module enable prometheus
    echo 'Prometheus mgr module enabled.'
fi

# Upstream luminous start ends here
if [[ "$IS_UPSTREAM_LUMINOUS" != 0 ]]; then
    exit 0
fi

# Disable ssl (if selected)
readonly VSTART_HAS_SSL_FLAG=$(cat /ceph/src/vstart.sh | grep DASHBOARD_SSL | wc -l)
if [[ "$DASHBOARD_SSL" == 0 && "$VSTART_HAS_SSL_FLAG" == 0 && "$IS_FIRST_CLUSTER" == 1 ]]; then
    echo "Disabling SSL..."

    SSL_OPTIONS='--force'
    if [[ "$CEPH_VERSION" == 13 ]]; then
        SSL_OPTIONS=''
    fi

    "$CEPH_BIN"/ceph config set mgr mgr/dashboard/ssl false $SSL_OPTIONS
    "$CEPH_BIN"/ceph config set mgr mgr/dashboard/x/server_port "$CEPH_MGR_DASHBOARD_PORT" $SSL_OPTIONS
    /docker/restart-dashboard.sh

    echo "SSL disabled."
fi

# Upstream mimic start ends here
if [[ "$CEPH_VERSION" == '13' || "$IS_FIRST_CLUSTER" == 0 ]]; then
    exit 0
fi

# Create dashboard "test" user:
[[ "$CEPH_VERSION" -gt '14' ]] && DASHBOARD_USER_CREATE_OPTIONS='--force-password'
"$CEPH_BIN"/ceph dashboard ac-user-create ${DASHBOARD_USER_CREATE_OPTIONS} test test

# Set monitoring stack:
/docker/set-monitoring.sh
