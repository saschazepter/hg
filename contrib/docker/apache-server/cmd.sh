#!/bin/bash

echo "Starting Apache HTTP Server on port 80"
echo "We hope you remembered to publish this port when running the container!"
echo "If this is an interactive container, simply CTRL^C to stop."

(. /etc/apache2/envvars && /usr/sbin/apache2 -DFOREGROUND) &

(set -o allexport && . /etc/anubis/hgweb.env && set +o allexport && /usr/bin/anubis) &

wait -n

exit $?
