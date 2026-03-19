[
  "test/support/parity/node_bridge.ex",
  "test/support/parity/case.ex",
  "test/support/**/*.ex",
  "test/support/**/*.exs",
  "test_helpers/**/*.ex",
  "test_helpers/**/*.exs"
]
|> Enum.flat_map(&Path.wildcard/1)
|> Enum.uniq()
|> Enum.each(&Code.require_file/1)

ExUnit.start()
ExUnit.configure(exclude: [parity: true])
