# This scripted starter case demonstrates build identity, not fresh-task efficacy.
[
  source: Path.expand("..", __DIR__),
  profile: %{
    "execution" => "scripted",
    "model" => "test:model",
    "tools" => [],
    "options" => %{
      "system" => "You review source code. Follow the requested JSON contract.",
      "max_turns" => 1,
      "temperature" => 0,
      "answer" =>
        JSON.encode!(%{
          "findings" => [
            %{
              "path" => "calculator.ex",
              "line" => 2,
              "message" => "Zero denominator is not validated."
            }
          ]
        })
    }
  }
]
