# platform services

Each service under `services/` pins its dependencies in `deps.lock`
(`name version`, one per line). Shared libraries are meant to be pinned to
the same version across every service.
