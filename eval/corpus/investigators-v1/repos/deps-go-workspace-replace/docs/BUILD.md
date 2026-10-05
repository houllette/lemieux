# Building

Build from the repository root with `go build ./cmd/...`.

The root contains a `go.work` file, so builds run in workspace mode. In
workspace mode the `use` and `replace` directives in `go.work` take precedence:
a `replace` in `go.work` overrides a `replace` for the same module path in any
`go.mod`, and `go.sum` entries for the replaced module are not consulted.
