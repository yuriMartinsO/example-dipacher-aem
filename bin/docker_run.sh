#!/bin/bash
#
# Script to run docker dispatcher image
# with dispatcher configs (in flexible mode)
# or entries generated by validator (in legacy mode)
#
# Usage: docker_run.sh dump-folder aemhost:aemport localport [env]
# or: docker_run.sh dump-folder aemhost:aemport test [env]
#

set -e

usage() {
    cat <<EOF >& 1
Usage: $0 deployment-folder aem-host:aem-port localport
or: $0 deployment-folder aem-host:aem-port test

Examples:
  # Use deployment folder "out", start dispatcher container on port 8080, for AEM running on myhost:4503
  $0 out myhost:4503 8080

  # Same as above, but AEM runs on your host at port 4503
  $0 out host.docker.internal:4503 8080

  # Same as above, but simulate a stage environment
  DISP_RUN_MODE=stage $0 out host.docker.internal:4503 8080

  # Same as above, but set dispatcher log level to debug to see HTTP traffic to the backend
  DISP_LOG_LEVEL=trace1 $0 out host.docker.internal:4503 8080

  # Same as above, but set rewrite log level to trace2 to see how your RewriteRules get applied
  REWRITE_LOG_LEVEL=trace2 $0 out host.docker.internal:4503 8080

  # Use deployment folder "out", start httpd -t to test the configuration, dump processed dispatcher.any config
  # (note: provided aemhost needs to be resolvable, using "localhost" is possible)
  $0 out localhost:4503 test

Environment variables available:
  DISP_RUN_MODE:     defines the environment type or run mode.
                     Valid values are dev, stage or prod (default is dev)
  DISP_LOG_LEVEL:    sets the dispatcher log level
                     Valid values are trace1, debug, info, warn or error (default is warn)
  REWRITE_LOG_LEVEL: sets the rewrite log level
                     Valid values are trace1-trace8, debug, info, warn or error (default is warn)
  ENV_FILE:          specifies a file of environment variables that should be imported.
                     Valid values are paths to files. (e.g. my_envs.env) (default is not set)
  HOT_RELOAD:        specifies rather to activate the hot reload functionallity that is reloading the configuration of the configuration
                     folder as soon as it changes
                     Valid values: true/false (default is false)
  ALLOW_CACHE_INVALIDATION_GLOBALLY: specifies if the default_invalidate.any file for cache should be overwritten to allow all connections
                                     Valid values: true/false (default is false)
  HTTPD_DUMP_VHOSTS: enable dump of vhosts for debug
                     Valid values are true/false (default is false)
EOF
    exit 1
}

error() {
    echo >&2 "** error: $1"
    exit 2
}

[ $# -eq 3 ] || usage

folder=$1
shift

aemhostport=$1
shift

uname -a
echo "$SHELL"

aemhost=$(echo "${aemhostport}" | sed -En 's/([^:]+):.*/\1/p')
aemport=$(echo "${aemhostport}" | sed -En 's/.+:([0-9]+)/\1/p')
{ [ -n "${aemhost}" ] || [ -n "${aemport}" ]; } || error "host:port combination expected, got: ${aemhostport}"

localport=$1
shift

command -v docker >/dev/null 2>&1 || error "docker not found, aborting."

volumes="-v ${PWD}/${CACHE_FOLDER-cache}:/mnt/var/www"
config_dir=/etc/httpd
customer_dir_mount=/mnt/dev/src
httpd_dir=${config_dir}/conf.d
dispatcher_dir=${config_dir}/conf.dispatcher.d
scriptDir="$(cd -P "$(dirname "$0")" && pwd -P)"

# Make folder path absolute for docker volume mount
first=$(echo "${folder}" | sed 's/\(.\).*/\1/')
if [ "${first}" != "/" ]
then
    folder=${PWD}/${folder}
fi

[ -d "${folder}" ] || error "deployment folder not found: ${folder}"
if [ -f "${folder}/values.csv" ]
then
	# Process files in generated folder and generate volume argument
	echo "values.csv found in deployment folder: ${folder} - using files listed there"
    for file in $(tr "," "\n" < "${folder}"/values.csv)
    do
        case ${file} in
        clientheaders_any)
            volumes="-v ${folder}/${file}:${dispatcher_dir}/clientheaders/clientheaders.any:ro ${volumes}"
            ;;
        custom_vars)
            volumes="-v ${folder}/${file}:${httpd_dir}/variables/custom.vars:ro ${volumes}"
            ;;
        farms_any)
            volumes="-v ${folder}/${file}:${dispatcher_dir}/enabled_farms/farms.any:ro ${volumes}"
            ;;
        filters_any)
            volumes="-v ${folder}/${file}:${dispatcher_dir}/filters/filters.any:ro ${volumes}"
            ;;
        global_vars)
            volumes="-v ${folder}/${file}:${httpd_dir}/variables/global.vars:ro ${volumes}"
            ;;
        rewrite_rules)
            volumes="-v ${folder}/${file}:${httpd_dir}/rewrites/rewrite.rules:ro ${volumes}"
            ;;
        rules_any)
            volumes="-v ${folder}/${file}:${dispatcher_dir}/cache/rules.any:ro ${volumes}"
            ;;
        virtualhosts_any)
            volumes="-v ${folder}/${file}:${dispatcher_dir}/virtualhosts/virtualhosts.any:ro ${volumes}"
            ;;
        vhosts_conf)
            volumes="-v ${folder}/${file}:${httpd_dir}/enabled_vhosts/vhosts.conf:ro ${volumes}"
            ;;
        esac
    done
else
    # Mounting the customer folder as whole folder as well as the import script.
    
    volumes="-v ${scriptDir}/../lib/import_sdk_config.sh:/docker_entrypoint.d/zzz-import-sdk-config.sh:ro ${volumes}"
    volumes="-v ${scriptDir}/../lib/dummy_gitinit_metadata.sh:/docker_entrypoint.d/zzz-overwrite_gitinit_metadata.sh:ro ${volumes}"
    if [ "$ALLOW_CACHE_INVALIDATION_GLOBALLY" == "true" ]; then
        volumes="-v ${scriptDir}/../lib/overwrite_cache_invalidation.sh:/docker_entrypoint.d/zzz-overwrite_cache_invalidation.sh:ro ${volumes}"
    fi
    volumes="-v ${folder}:${customer_dir_mount}:ro ${volumes}"
    if [ "${HOT_RELOAD}" == "true" ]; then
        if [ -f "${folder}"/opt-in/USE_SOURCES_DIRECTLY ]; then
            echo "opt-in USE_SOURCES_DIRECTLY marker file detected"
            volumes="-v ${scriptDir}/../lib/httpd-reload-monitor:/usr/sbin/httpd-reload-monitor:ro ${volumes}"
        else
            echo "This feature is only available if flexible mode is enabled."
            echo "Please see more information here: https://experienceleague.adobe.com/docs/experience-manager-cloud-service/content/implementing/content-delivery/validation-debug.html?lang=en#migrating"
            exit 1
        fi
    fi
fi

# Mount libs
volumes="-v ${scriptDir}/../lib:/usr/lib/dispatcher-sdk:ro ${volumes}"

uname=$(uname)

envvars="--env AEM_HOST=${aemhost} --env AEM_PORT=${aemport} --env HOST_OS=${uname}"
if [ -n "${DISP_RUN_MODE}" ]; then
    case "${DISP_RUN_MODE}" in
        dev|stage|prod)
            envvars="$envvars --env ENVIRONMENT_TYPE=${DISP_RUN_MODE}"
            ;;
        *)
            error "unknown environment type: ${DISP_RUN_MODE} (expected dev, stage or prod)"
            ;;
    esac
fi
if [ -n "${DISP_LOG_LEVEL}" ]; then
    DISP_LOG_LEVEL=$(echo "${DISP_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')
    case "${DISP_LOG_LEVEL}" in
        trace1 | debug | info | warn | error)
            envvars="$envvars --env DISP_LOG_LEVEL=${DISP_LOG_LEVEL}"
            ;;
        *)
            error "unknown dispatcher log level: ${DISP_LOG_LEVEL} (expected trace1, debug, info, warn or prod)"
            ;;
    esac
fi
if [ -n "${REWRITE_LOG_LEVEL}" ]; then
    REWRITE_LOG_LEVEL=$(echo "${REWRITE_LOG_LEVEL}" | tr '[:upper:]' '[:lower:]')
    case "${REWRITE_LOG_LEVEL}" in
        trace[1-8] | debug | info | warn | error)
            envvars="$envvars --env REWRITE_LOG_LEVEL=${REWRITE_LOG_LEVEL}"
            ;;
        *)
            error "unknown rewrite log level: ${REWRITE_LOG_LEVEL} (expected trace1-trace8, debug, info, warn or prod)"
            ;;
    esac
fi
if [ -n "${ENV_FILE}" ]; then
    envvars="$envvars --env-file=${ENV_FILE}"
fi

repo=adobe
image=aem-cs/dispatcher-publish
version=2.0.193
imageurl="${repo}/${image}:${version}"

if [ -z "$(docker images -q "${imageurl}" 2> /dev/null)" ]; then
    echo "Required image not found, trying to load from archive..."
    # Use arm64 image for e.g. M1 Macbooks
    arch=$(uname -m)
    echo "Architecture: ${arch}"
    if [[ "$arch" == "arm64" || "$arch" == "aarch64" ]]; then
        file=$(dirname "$0")/../lib/dispatcher-publish-arm64.tar.gz
    else
        file=$(dirname "$0")/../lib/dispatcher-publish-amd64.tar.gz
    fi
    [ -f "${file}" ] || error "unable to find archive at expected location: $file"
    gunzip -c "${file}" | docker load
    [ -n "$(docker images -q "${imageurl}" 2> /dev/null)" ] || error "required image still not found: $imageurl"
fi

if [ "${localport}" = "test" ]; then
    cmd="docker run --rm ${volumes} ${envvars} --env SKIP_BACKEND_WAIT=true --env SKIP_CONFIG_TESTING=true ${imageurl} /usr/sbin/httpd-test"
    if [ "${HTTPD_DUMP_VHOSTS}" == "true" ]; then

        # Will test existence of /usr/sbin/httpd-vhosts script
        # - mount a volume if httpd-vhosts script doesn't exists (backward compatibility)
        if ! docker run --rm --entrypoint test ${imageurl} -f /usr/sbin/httpd-vhosts; then
            volumes="-v ${scriptDir}/../lib/httpd-vhosts:/usr/sbin/httpd-vhosts:ro ${volumes}"
        fi
        dump_vhosts_cmd="docker run --rm ${volumes} ${envvars} --env SKIP_BACKEND_WAIT=true --env SKIP_CONFIG_TESTING=true ${imageurl} /usr/sbin/httpd-vhosts"
    fi
else
    cmd="docker run --rm -p ${localport}:80 ${volumes} ${envvars} ${imageurl}"
fi
eval "$cmd"
if [ "${HTTPD_DUMP_VHOSTS}" == "true" ]; then
    eval "$dump_vhosts_cmd"
fi
