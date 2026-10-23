import typesystem


def test_emitted_reference_resolves_inside_its_json_schema_document():
    definitions = typesystem.Definitions()
    artist = typesystem.Schema(fields={"name": typesystem.String(max_length=100)})
    album = typesystem.Schema(fields={
        "artist": typesystem.Reference(to="Artist", definitions=definitions)
    })
    definitions["Artist"] = artist
    definitions["Album"] = album
    document = typesystem.to_json_schema(album)
    reference = document["properties"]["artist"]["$ref"]
    assert reference.startswith("#/")
    resolved = document
    for part in reference[2:].split("/"):
        resolved = resolved[part.replace("~1", "/").replace("~0", "~")]
    assert resolved["properties"]["name"]["type"] == "string"
