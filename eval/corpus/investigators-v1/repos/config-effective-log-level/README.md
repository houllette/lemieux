# notify-service

Small notification dispatcher. Configuration is layered; see `config/README.md`
for the exact order in which the layers are applied.

Deployments are started by the systemd unit under `deploy/`, which is where the
stage name (`APP_ENV`) comes from.
