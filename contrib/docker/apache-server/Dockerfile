FROM debian:bookworm

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV DEBIAN_FRONTEND=noninteractive
ENV SOURCE_DIR=/var/hg/source
ENV INSTALL_DIR=/var/hg/install
ENV REPOS_DIR=/var/hg/repos
ENV HTDOCS_DIR=/var/hg/htdocs
ENV WSGI_PROCESSES=4
ENV WSGI_THREADS=1
ENV WSGI_MAX_REQUESTS=100000

EXPOSE 80
VOLUME ["${HTDOCS_DIR}", "${REPOS_DIR}"]

RUN apt-get update && \
    apt-get -y install build-essential apache2 libapache2-mod-wsgi-py3 python3-dev less vim-tiny && \
    rm -rf /var/lib/apt/lists/*

# Install our own Apache site.
RUN a2dissite 000-default
COPY vhost.conf /etc/apache2/sites-available/hg.conf
RUN a2ensite hg

COPY hgwebconfig /defaulthgwebconfig

COPY entrypoint.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]

CMD ["/usr/sbin/apache2", "-DFOREGROUND"]
