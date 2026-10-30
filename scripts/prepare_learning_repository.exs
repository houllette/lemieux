# mix run scripts/prepare_learning_repository.exs --dataset PRIVATE.json ...
# Provider-free curation; the prepared image supplies the project's Python.
{opts, [], []} =
  OptionParser.parse(System.argv(),
    strict: [
      dataset: :string,
      instance: :string,
      source_image: :string,
      image: :string,
      public_check: :string,
      output: :string
    ]
  )

opts = Keyword.put(opts, :repo, Path.expand("..", __DIR__))
manifest = Lemieux.CLI.Learning.RepositoryPreparation.prepare(opts)
IO.puts("Prepared development fixture and control evidence: #{manifest}")
