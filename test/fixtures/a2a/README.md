These fixtures are hand-authored from the A2A **v1.0.0** specification, not
serialized with Lemieux codecs. They pin field names, enum values, response
unions, interface selection and the JSON-RPC error registry independently.

Sources: https://a2a-protocol.org/v1.0.0/specification/ and
https://github.com/a2aproject/A2A/blob/v1.0.0/specification/a2a.proto.

Socket tests also assert outbound messages and headers before emitting these
fixtures. Distributed tests exercise the separate trusted-BEAM binding.
