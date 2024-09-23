#!/bin/sh
# Overwrites the default_invalidate.any file to allow any hosts.
#
# Generate allowed clients for dispatcher
#
mkdir -p ${APACHE_PREFIX}/conf.dispatcher.d/cache
OUTPUT_FILE=${APACHE_PREFIX}/conf.dispatcher.d/cache/default_invalidate.any

cat << EOF > ${OUTPUT_FILE}
# Generated by docker entrypoint script, manual changes will be lost
/0001 {
  /type "allow"
  /glob "*"
}
EOF