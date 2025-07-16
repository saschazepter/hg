====================
Apache Docker Server
====================

This directory contains code for running a Mercurial hgweb server via mod_wsgi
with the Apache HTTP Server and protected from scraper bots with Anubis inside
a Docker container.

.. important::

   This container is intended for testing purposes only: it is
   **not** meant to be suitable for production use.

Building Image
==============

The first step is to build a Docker image containing all the required
software::

  $ docker build -t hg-apache .

.. important::

   You should rebuild the image whenever the content of this directory
   changes. Rebuilding after pulling or when you haven't run the container
   in a while is typically a good idea.

Running the Server
==================

To run the container, you'll execute something like::

  $ docker run --init --rm -it -p 8000:80 hg-apache

If you aren't a Docker expert:

* ``--init`` will run an init inside the container so we can run multiple
  processes at once (i.e. both Apache HTTP Server and Anubis)
* ``--rm`` will remove the container when it stops (so it doesn't clutter
  your system)
* ``-i`` will launch the container in interactive mode so stdin is attached
* ``-t`` will allocate a pseudo TTY
* ``-p 8000:80`` will publish port ``80`` on the container to port ``8000``
  on the host, allowing you to access the HTTP server on the host interface.
* ``hg-apache`` is the container image to run. This should correspond to what
  we build with ``docker build``.

When starting the container, you should see some start-up actions (including a
Mercurial health check) and some output saying Apache and Anubis have started.
There will be messages related to Anubis configuration and random key
generation, but they are expected, since it was configured to simply run
successfully and protect one hgweb instance.

Now if you load ``http://localhost:8000/`` (or whatever interface Docker
is using), you should see hgweb running!

For your convenience, we've created an empty repository available at
``/repo``. Feel free to populate it with ``hg push``.

Customizing the Server
======================

This Docker container uses fairly minimal configuration and often relies on the
default values while making sure the software works together well. There are
very few advanced features, and the configuration that is present is hopefully
pretty self-explanatory. This should make it easier for people to understand
the principles behind the moving parts and how they all come together, and to
experiment with adding any new features without breaking anything.

Customizing the WSGI Dispatcher And Mercurial Config
----------------------------------------------------

By default, the Docker environment installs a custom ``hgweb.wsgi``
file (based on the example in ``contrib/hgweb.wsgi``). The file
is installed into ``/var/hg/htdocs/hgweb.wsgi``.

A default hgweb configuration file is also installed. The ``hgwebconfig``
file from this directory is installed into ``/var/hg/htdocs/config``.

You have a few options for customizing these files.

The simplest is to hack up ``hgwebconfig`` and ``entrypoint.sh`` in
this directory and to rebuild the Docker image. This has the downside
that the Mercurial working copy is modified and you may accidentally
commit unwanted changes.

The next simplest is to copy this directory somewhere, make your changes,
then rebuild the image. No working copy changes involved.

The preferred solution is to mount a host file into the container and
overwrite the built-in defaults.

For example, say we create a custom hgweb config file in ``~/hgweb``. We
can start the container like so to install our custom config file::

  $ docker run -v ~/hgweb:/var/hg/htdocs/config ...

You can do something similar to install a custom WSGI dispatcher::

  $ docker run -v ~/hgweb.wsgi:/var/hg/htdocs/hgweb.wsgi ...

Managing Repositories
---------------------

Repositories are served from ``/var/hg/repos`` by default. This directory
is configured as a Docker volume. This means you can mount an existing
data volume container in the container so repository data is persisted
across container invocations. See
https://docs.docker.com/userguide/dockervolumes/ for more.

Alternatively, if you just want to perform lightweight repository
manipulation, open a shell in the container::

  $ docker exec -it <container> /bin/bash

Then run ``hg init``, etc to manipulate the repositories in ``/var/hg/repos``.

Anubis Configuration Settings
-----------------------------

The newest and likely the most experimental part in this whole setup is Anubis,
which is described as "Web AI Firewall Utility", and in our case it protects
hgweb from the excessive scraping done by various bots online (mostly
AI-related, but not only those).

The current configuration file for Anubis, ``/etc/anubis/hgweb.env``, is
created inside ``entrypoint.sh``. It's purposefully short and uses the default
bot policy and doesn't use any advanced features, mostly because currently it's
difficult to make any assumptions about the future situation, and also because
this is just an example setup not meant for production.

Probably the best advice for maintaining a widely-accessible hgweb instance is
to keep Anubis package up-to-date and either rely on its defaults, or maintain
your own policy file and continuously monitor the logs.

See https://anubis.techaro.lol/docs/admin/installation for more on the
available settings.

Apache HTTP Server Settings
---------------------------

There is ``vhost.conf`` file in this directory that gets copied to
``/etc/apache2/sites-available/hg.conf`` in the container.

One feature that is worth mentioning is serving the files in the /static/
directory. It is possible to serve these files via hgweb, but that is not
recommended, since any web server software is much better at it. So there are
configuration directives related to that in the ``vhost.conf`` file.

But while we do serve the static files via Apache HTTP Server, it's worth
mentioning that they are also protected with Anubis (and get proxied through
it). Depending on your use-case, this might not be what you want. If you want
to serve the static files to HTTP clients quickly and without any checks, you
need to move the directives into the first ``VirtualHost`` (that proxies the
requests to Anubis) and use ``ProxyPass`` with ``!`` directive to not
reverse-proxy the /static/ directory. See
https://httpd.apache.org/docs/2.4/mod/mod_proxy.html#proxypass for more.

mod_wsgi Configuration Settings
-------------------------------

mod_wsgi settings can be controlled with the following environment
variables (defined in ``Dockerfile`` and used in ``vhost.conf``).

WSGI_PROCESSES
   Number of WSGI processes to run.
WSGI_THREADS
   Number of threads to run in each WSGI process
WSGI_MAX_REQUESTS
   Maximum number of requests each WSGI process may serve before it is
   reaped.

See https://modwsgi.readthedocs.io/en/master/configuration-directives/WSGIDaemonProcess.html
for more on these settings.

.. note::

   The default is to use 1 thread per process. The reason is that Mercurial
   doesn't perform well in multi-threaded mode due to the GIL. Most people
   run a single thread per process in production for this reason, so that's
   what we default to.
