FROM registry.heptapod.net/mercurial/ci-images/mercurial-core:v2.1

USER ci-runner

RUN mkdir /home/ci-runner/.local/
ENV PATH=/home/ci-runner/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PYTHONPATH=/home/ci-runner/.local/lib/python3.11/site-packages

RUN python3 -m pip install --user --break-system-packages --upgrade pytype==2023.11.21

ADD --chown=ci-runner entrypoint.sh /home/ci-runner/entrypoint.sh

RUN chmod -R a=rwX /home/ci-runner/.local/ /home/ci-runner/entrypoint.sh

CMD /home/ci-runner/entrypoint.sh
