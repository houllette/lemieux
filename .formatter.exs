# Used by "mix format"
[
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    # Runnable examples and helper scripts are read as documentation, so they
    # keep the house style too; three had drifted out of it unnoticed. Each
    # project under examples/extensions formats itself.
    "examples/*.exs",
    "examples/{discovery,experiments}/*.exs",
    "scripts/*.exs"
  ]
]
