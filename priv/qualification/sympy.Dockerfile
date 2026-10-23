# Preparation only. Tasks and graders have no network and use its immutable ID.
# The source exporter reads exact Git archives from the original pinned image;
# the serving image must contain no repository history or cached target source.
FROM swebench/sweb.eval.x86_64.sympy_1776_sympy-19040@sha256:2238ea21e03d1548e7f3e5345fb924aba8459c99f8697270f8e04aa3661136b4
RUN /opt/miniconda3/envs/testbed/bin/python -m pip install --no-cache-dir pytest==8.4.2 \
    && /opt/miniconda3/envs/testbed/bin/python -m pip uninstall -y sympy \
    && rm -rf /testbed /root /opt/miniconda3/pkgs
ENV PATH=/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTEST_ADDOPTS="-p no:cacheprovider"
WORKDIR /app
