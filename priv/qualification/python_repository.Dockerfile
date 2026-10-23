# Preparation only: pass a repository@sha256:digest source image and exact
# pytest version compatible with that image's existing testbed interpreter.
ARG SOURCE_IMAGE=swerebench/sweb.eval.x86_64.encode_1776_typesystem-65@sha256:afcbfb7d0d99b626a6bc7b52808b1f80ae2661f12c4ea08ca7e58c98c787ee2c
FROM ${SOURCE_IMAGE}
ARG TARGET_DIST
ARG TARGET_MODULE
ARG PYTEST_VERSION
RUN test -n "$TARGET_DIST" && test -n "$TARGET_MODULE" && test -n "$PYTEST_VERSION" \
    && /opt/miniconda3/envs/testbed/bin/python -m pip install --no-cache-dir "pytest==$PYTEST_VERSION" \
    && /opt/miniconda3/envs/testbed/bin/python -m pip uninstall -y "$TARGET_DIST" \
    && /opt/conda/bin/python -m pip uninstall -y "$TARGET_DIST" \
    && rm -rf /testbed /root /opt/miniconda3/pkgs /opt/conda/pkgs \
    && /opt/miniconda3/envs/testbed/bin/python -I -B -c 'import importlib.util,sys; assert importlib.util.find_spec(sys.argv[1]) is None' "$TARGET_MODULE" \
    && /opt/conda/bin/python -I -B -c 'import importlib.util,sys; assert importlib.util.find_spec(sys.argv[1]) is None' "$TARGET_MODULE"
ENV PATH=/opt/miniconda3/envs/testbed/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTEST_ADDOPTS="-p no:cacheprovider"
WORKDIR /app
