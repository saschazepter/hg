FROM debian:trixie

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ARG PIP_HG_VERSION=7.0.2
ARG ANUBIS_VERSION=1.19.1
ENV INSTALL_DIR=/var/hg/install
ENV REPOS_DIR=/var/hg/repos
ENV HTDOCS_DIR=/var/hg/htdocs
ENV WSGI_PROCESSES=4
ENV WSGI_THREADS=1
ENV WSGI_MAX_REQUESTS=100000

EXPOSE 80
VOLUME ["${HTDOCS_DIR}", "${REPOS_DIR}"]

RUN apt-get update && \
    apt-get -y --no-install-recommends install apache2 libapache2-mod-wsgi-py3 python3-venv less vim-tiny && \
    rm -rf /var/lib/apt/lists/*

ADD --checksum=sha256:0194e0ed433d26090f2b57c91a9e877f8717ae68208d53227d6513404ef56140 \
    https://github.com/TecharoHQ/anubis/releases/download/v${ANUBIS_VERSION}/anubis_${ANUBIS_VERSION}_amd64.deb \
    /tmp/

RUN apt-get install /tmp/anubis_${ANUBIS_VERSION}_amd64.deb && \
    rm /tmp/anubis_${ANUBIS_VERSION}_amd64.deb

RUN /usr/bin/python3.13 -m venv "${INSTALL_DIR}" && \
    "${INSTALL_DIR}"/bin/python -m pip install "mercurial==${PIP_HG_VERSION}"

# Enable the extra Apache mods that we need.
RUN a2enmod headers
RUN a2enmod proxy_http

# Install our own Apache site.
RUN a2dissite 000-default
COPY vhost.conf /etc/apache2/sites-available/hg.conf
RUN a2ensite hg

COPY hgwebconfig /var/hg/defaulthgwebconfig

COPY --chmod=0700 entrypoint.sh /var/hg/entrypoint.sh
ENTRYPOINT ["/var/hg/entrypoint.sh"]

COPY --chmod=0700 cmd.sh /var/hg/cmd.sh
CMD ["/var/hg/cmd.sh"]

WORKDIR /var/hg/
