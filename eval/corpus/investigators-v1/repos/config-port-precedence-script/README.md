# ping-service

Tiny health-check responder. In production it is started by the systemd unit
in `deploy/app.service`; `bin/start.sh` resolves the listening port from the
configuration sources it documents.
