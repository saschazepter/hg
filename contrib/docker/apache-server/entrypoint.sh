#!/bin/bash

# This script gets executed on container start. Its job is to set up
# the Mercurial environment and invoke the server.

# Currently it can install any Mercurial release that has binary packages
# (wheels) available on PyPI.

set -e

# Provide a default config if the user hasn't supplied one.
if [ ! -f ${HTDOCS_DIR}/config ]; then
  install -m 0644 /defaulthgwebconfig ${HTDOCS_DIR}/config
fi

if [ ! -f ${HTDOCS_DIR}/hgweb.wsgi ]; then
  cat >> ${HTDOCS_DIR}/hgweb.wsgi << EOF
config = b'${HTDOCS_DIR}/config'

import sys
sys.path.insert(0, '${INSTALL_DIR}/lib/python3.11/site-packages')

from mercurial import demandimport
demandimport.enable()

from mercurial.hgweb import hgweb
application = hgweb(config)
EOF
fi

if [ ! -d ${REPOS_DIR}/repo ]; then
  ${INSTALL_DIR}/bin/hg init ${REPOS_DIR}/repo
  chown -R www-data:www-data ${REPOS_DIR}/repo
fi

# This is necessary to make debuginstall happy.
if [ ! -f ~/.hgrc ]; then
  cat >> ~/.hgrc << EOF
[ui]
username = Dummy User <nobody@example.com>
EOF
fi

echo "Verifying Mercurial installation looks happy"
${INSTALL_DIR}/bin/hg debuginstall

. /etc/apache2/envvars

echo "Starting Apache HTTP Server on port 80"
echo "We hope you remembered to publish this port when running the container!"
echo "If this is an interactive container, simply CTRL^C to stop."

exec "$@"
