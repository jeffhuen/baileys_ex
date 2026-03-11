["test_helpers/**/*.ex", "test_helpers/**/*.exs"]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.each(&Code.require_file/1)

ExUnit.start()
