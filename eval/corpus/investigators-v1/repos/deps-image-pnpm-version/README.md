# storefront web

Production images are built by `deploy/build.sh` and pushed by CI after tests
pass. `docker-compose.yml` exists for local development only and is never used
to produce a production image.
