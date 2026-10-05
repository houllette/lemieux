module github.com/acme/edge-proxy

go 1.22

require (
	github.com/acme/ratelimit v1.4.0
	golang.org/x/sync v0.7.0
)

replace github.com/acme/ratelimit => ./vendor-local/ratelimit
