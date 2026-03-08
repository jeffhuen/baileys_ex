# Elixir Anti-Patterns Reference

> Sources:
> - [hexdocs.pm/elixir — Anti-patterns](https://hexdocs.pm/elixir/what-anti-patterns.html)
> - [AppSignal — Memory-Efficient Elixir with Streams](https://blog.appsignal.com/2024/02/06/how-to-build-a-memory-efficient-elixir-app-with-streams.html)
>
> This is a concise reference for LLM agents. Follow these rules when writing or reviewing Elixir code.

---

## 1. Code Anti-Patterns

### 1.1 Comments Overuse

Don't comment self-explanatory code. Use descriptive names and module attributes instead.

```elixir
# BAD
unix_now = DateTime.to_unix(now, :second) # Convert to Unix timestamp
unix_now + (60 * 5) # Add five minutes

# GOOD
@five_min_in_seconds 60 * 5
DateTime.to_unix(now, :second) + @five_min_in_seconds
```

### 1.2 Complex `else` in `with`

Don't flatten all error handling into one `else` block. Extract error normalization into helper functions.

```elixir
# BAD
with {:ok, encoded} <- File.read(path),
     {:ok, decoded} <- Base.decode64(encoded) do
  {:ok, String.trim(decoded)}
else
  {:error, _} -> {:error, :badfile}
  :error -> {:error, :badencoding}
end

# GOOD — normalize in helpers, let with handle happy path
with {:ok, encoded} <- file_read(path),
     {:ok, decoded} <- base_decode64(encoded) do
  {:ok, String.trim(decoded)}
end

defp file_read(path) do
  case File.read(path) do
    {:ok, contents} -> {:ok, contents}
    {:error, _} -> {:error, :badfile}
  end
end
```

### 1.3 Complex Extractions in Clauses

Only extract guard-related variables in function heads. Handle body-specific extractions inside the function.

```elixir
# BAD
def drive(%User{name: name, age: age}) when age >= 18 do
  "#{name} can drive"
end

# GOOD
def drive(%User{age: age} = user) when age >= 18 do
  "#{name} can drive"
end
```

### 1.4 Dynamic Atom Creation

Never create atoms from untrusted input. Atoms are not garbage collected; the BEAM limits them to ~1 million.

```elixir
# BAD — atom exhaustion risk
String.to_atom(user_input)

# GOOD — explicit mapping
defp convert_status("ok"), do: :ok
defp convert_status("error"), do: :error

# GOOD — only allows existing atoms
String.to_existing_atom(status)
```

### 1.5 Long Parameter Lists

Group related parameters using maps, structs, or keyword lists.

```elixir
# BAD
def loan(user_name, email, password, alias, book_title, book_ed)

# GOOD
def loan(%User{} = user, %Book{} = book)
```

### 1.6 Namespace Trespassing

Never define modules under another library's namespace. Prefix with your own library name.

```elixir
# BAD — :plug_auth package defining under Plug namespace
defmodule Plug.Auth do ... end

# GOOD
defmodule PlugAuth do ... end
```

### 1.7 Non-Assertive Map Access

Use `map.key` (static access) for required keys. Use `map[:key]` (dynamic access) only for optional keys.

```elixir
# BAD — silently returns nil on missing required keys
{point[:x], point[:y]}

# GOOD — raises KeyError if key missing
{point.x, point.y, point[:z]}

# GOOD — pattern match
def plot(%{x: x, y: y} = point), do: {x, y, point[:z]}
```

### 1.8 Non-Assertive Pattern Matching

Fail fast with pattern matching instead of defensive code that silently returns wrong values.

```elixir
# BAD — silently handles malformed input
key_value = String.split(pair, "=")
Enum.at(key_value, 0) == desired_key && Enum.at(key_value, 1)

# GOOD — crashes on unexpected format
[key, value] = String.split(pair, "=")
key == desired_key && value
```

### 1.9 Non-Assertive Truthiness

Use `and`/`or`/`not` for boolean operands. Reserve `&&`/`||`/`!` for truthy/falsy values.

```elixir
# BAD
if is_binary(name) && is_integer(age), do: ...

# GOOD
if is_binary(name) and is_integer(age), do: ...
```

### 1.10 Structs with 32+ Fields

Keep structs under 32 fields. Above that threshold, BEAM switches from flat to hash map representation, losing key-sharing optimizations. Nest optional/related fields into sub-structs or metadata maps.

---

## 2. Design Anti-Patterns

### 2.1 Alternative Return Types

Don't use options that drastically change a function's return type. Create separate functions instead.

```elixir
# BAD
def parse(string, opts \\ [])  # returns {int, rest} OR just int depending on opts

# GOOD
def parse(string), do: Integer.parse(string)
def parse_discard_rest(string), do: ...
```

### 2.2 Boolean Obsession

Don't use multiple overlapping booleans. Use a single atom representing the state.

```elixir
# BAD
def process(invoice, admin: true, editor: false)

# GOOD
def process(invoice, role: :admin)
```

### 2.3 Exceptions for Control Flow

Use `{:ok, result} | {:error, reason}` tuples for expected errors. Reserve exceptions for truly exceptional conditions.

```elixir
# BAD
try do
  IO.puts(File.read!(file))
rescue
  e -> IO.puts(:stderr, Exception.message(e))
end

# GOOD
case File.read(file) do
  {:ok, binary} -> IO.puts(binary)
  {:error, reason} -> IO.puts(:stderr, "could not read: #{reason}")
end
```

### 2.4 Primitive Obsession

Don't represent complex domain concepts as raw strings/integers. Use structs.

```elixir
# BAD — repeatedly parsing address strings
def extract_postal_code(address) when is_binary(address), do: ...
def fill_in_country(address) when is_binary(address), do: ...

# GOOD
defmodule Address do
  defstruct [:street, :city, :state, :postal_code, :country]
end
```

### 2.5 Unrelated Multi-Clause Functions

Don't group unrelated logic under one function name with pattern matching. Use separate, descriptive function names.

```elixir
# BAD
def update(%Product{}), do: ...
def update(%Animal{}), do: ...

# GOOD
def update_product(%Product{}), do: ...
def update_animal(%Animal{}), do: ...
```

### 2.6 Application Config for Libraries

Don't use `Application.get_env/fetch_env!` in library code. Accept config as function parameters.

```elixir
# BAD
def split(string) do
  parts = Application.fetch_env!(:app_config, :parts)
  String.split(string, "-", parts: parts)
end

# GOOD
def split(string, opts \\ []) do
  parts = Keyword.get(opts, :parts, 2)
  String.split(string, "-", parts: parts)
end
```

---

## 3. Process Anti-Patterns

### 3.1 Code Organization by Process

Don't use GenServer/Agent for pure computation. Use plain modules and functions. Processes are for concurrency, state, and resource management.

```elixir
# BAD — GenServer for stateless math
defmodule Calculator do
  use GenServer
  def add(a, b, pid), do: GenServer.call(pid, {:add, a, b})
end

# GOOD
defmodule Calculator do
  def add(a, b), do: a + b
end
```

### 3.2 Scattered Process Interfaces

Centralize all direct process interaction (Agent/GenServer calls) in one module. Don't spread `Agent.update/get` or `GenServer.call/cast` across multiple modules.

```elixir
# BAD — multiple modules directly calling Agent
defmodule A do
  def update(agent), do: Agent.update(agent, fn _ -> 123 end)
end

# GOOD — single module owns the process interface
defmodule Bucket do
  use Agent
  def put(bucket, key, value), do: Agent.update(bucket, &Map.put(&1, key, value))
  def get(bucket, key), do: Agent.get(bucket, &Map.get(&1, key))
end
```

### 3.3 Sending Unnecessary Data

Extract only needed fields before sending to another process. Message passing copies entire messages (share-nothing architecture).

```elixir
# BAD — copies entire conn struct
spawn(fn -> log_request_ip(conn) end)

# ALSO BAD — conn is still captured in closure
spawn(fn -> log_request_ip(conn.remote_ip) end)

# GOOD — extract first, then spawn
ip = conn.remote_ip
spawn(fn -> log_request_ip(ip) end)
```

### 3.4 Unsupervised Processes

Always place long-running processes in a supervision tree. Don't call `start_link` outside of a supervisor.

```elixir
# BAD
Counter.start_link()

# GOOD
children = [Counter]
Supervisor.start_link(children, strategy: :one_for_one)
```

### 3.5 Branchless Failure Tests

Don't claim a test covers branch A when setup actually drives branch B.

```elixir
# BAD — says "not in PATH" but bypasses PATH lookup branch
config = %{binary: "/nonexistent/ngrok"}
assert {:error, {:port_open_failed, _}} = Ngrok.start_link(config)

# GOOD — force PATH lookup miss and assert launch was not attempted
parent = self()

config = %{
  find_executable_fn: fn "ngrok" -> nil end,
  open_fn: fn _, _, _ ->
    send(parent, :open_called)
    {:error, :should_not_be_called}
  end
}

assert {:error, :ngrok_not_found} = Ngrok.start_link(config)
refute_receive :open_called
```

### 3.6 Over-Constrained `start_link` Failure Assertions

For linked processes, startup failures may surface as `{:error, reason}` or as linked `EXIT` depending on runtime context. Assert the reason across both shapes unless shape is the contract.

```elixir
# BAD — brittle: only one failure transport shape
assert {:error, :cloudflared_not_found} = Cloudflare.start_link(config)

# GOOD — assert reason in both valid shapes
Process.flag(:trap_exit, true)

case Cloudflare.start_link(config) do
  {:error, :cloudflared_not_found} ->
    :ok

  {:ok, pid} ->
    assert_receive {:EXIT, ^pid, :cloudflared_not_found}, 5_000
end
```

---

## 4. Meta-Programming Anti-Patterns

### 4.1 Compile-Time Dependencies in Macros

Macros create compile-time dependencies on referenced modules. Use `Macro.expand_literals/2` to convert to runtime dependencies where possible.

### 4.2 Large Code Generation

Don't put logic inside `quote` blocks. Delegate to helper functions called by the generated code.

```elixir
# BAD — validation inside quote
defmacro get(route, handler) do
  quote do
    if not is_binary(unquote(route)), do: raise ArgumentError
    @routes {unquote(route), unquote(handler)}
  end
end

# GOOD — delegate to function
defmacro get(route, handler) do
  quote do
    Routes.__define__(__MODULE__, unquote(route), unquote(handler))
  end
end
```

### 4.3 Unnecessary Macros

Use functions instead of macros when no compile-time code transformation is needed.

```elixir
# BAD
defmacro sum(a, b), do: quote(do: unquote(a) + unquote(b))

# GOOD
def sum(a, b), do: a + b
```

### 4.4 `use` Instead of `import`

Prefer `import` and `alias` over `use`. Reserve `use` for when `__using__` macro behavior is truly needed. `import` is lexically scoped and explicit; `use` injects arbitrary code.

### 4.5 Untracked Compile-Time Dependencies

Don't dynamically construct module names at compile time. Use explicit module references so the compiler can track dependencies.

```elixir
# BAD — compiler can't track these
for part <- [:Foo, :Bar] do
  Module.concat(OtherModule, part).example()
end

# GOOD
for mod <- [OtherModule.Foo, OtherModule.Bar] do
  mod.example()
end
```

---

## 5. Memory & Performance Anti-Patterns

### 5.1 Eager Collection Processing

Don't use `Enum` pipelines on large or unbounded datasets. Each `Enum` step materializes the entire collection in memory, creating intermediate copies.

```elixir
# BAD — loads entire file, then creates full intermediate lists at every step
rows = csv |> File.read!() |> String.split("\n")
rows
|> Enum.map(&String.split(&1, ","))
|> Enum.map(fn row -> Enum.zip(headers, row) end)
|> Enum.map(&Map.new/1)

# GOOD — lazy pipeline, one element at a time
csv
|> File.stream!()
|> Stream.map(&String.split(&1, ["\n", ","], trim: true))
|> Stream.map(&Stream.zip(headers, &1))
|> Stream.map(&Map.new/1)
|> Enum.to_list()
```

### 5.2 Loading Entire Files into Memory

Don't use `File.read!/1` for large or variable-size files. Use `File.stream!/1` to process line-by-line without loading the whole file.

```elixir
# BAD — entire file in memory at once
contents = File.read!("large_dataset.csv")

# GOOD — returns a stream descriptor, no data loaded yet
File.stream!("large_dataset.csv")
```

### 5.3 Processing All Data When Only Some Is Needed

When you only need N items, use `Stream` so processing stops after N elements. `Enum` processes the entire collection before taking.

```elixir
# BAD — processes all 2M records, then takes 3
data
|> Enum.map(&transform/1)
|> Enum.take(3)

# GOOD — processes only 3 records total
data
|> Stream.map(&transform/1)
|> Enum.take(3)
```

### 5.4 When to Use Stream vs Enum

Use `Stream` (lazy) when:
- Data is large or unbounded (files, database cursors, API pagination)
- You only need a subset of results (`Enum.take`, `Enum.find`)
- Multiple transformation steps create intermediate collections

Use `Enum` (eager) when:
- Data is small and bounded (known short lists, config values)
- You need the full result immediately
- A single pass with no intermediate collections (e.g., one `Enum.map`)

**Rule of thumb**: if the data source is I/O or the collection size is unknown/large, default to `Stream`.

### 5.5 MapSet for Small Fixed Sets

Don't use `MapSet` for small, bounded sets (< ~30 elements). `MapSet.t()` is an opaque type that causes Dialyzer `contract_with_opaque` warnings on OTP 28+ due to internal representation changes. Use a plain map instead — it's what MapSet wraps internally.

```elixir
# BAD — opaque type causes Dialyzer warnings, unnecessary abstraction for 4 elements
@spec normalize_bypass_list(term()) :: MapSet.t()
defp normalize_bypass_list(list) do
  list |> Enum.filter(&valid?/1) |> MapSet.new()
end

# later:
MapSet.member?(config.bypass_set, :commands)

# GOOD — plain map, works in guards, no opaque type issues
@spec normalize_bypass_list(term()) :: %{optional(atom()) => []}
defp normalize_bypass_list(list) do
  list |> Enum.filter(&valid?/1) |> Map.new(&{&1, []})
end

# later:
is_map_key(config.bypass_set, :commands)
```

**When to use what:**

| Cardinality | Data structure | Why |
|-------------|---------------|-----|
| < ~30 elements | Plain map `%{key => []}` | Small maps are flat tuples; `is_map_key/2` works in guards; no opaque type issues |
| 30–1000 elements | `MapSet` with `@dialyzer` suppression | O(1) lookup; suppress the `contract_with_opaque` warning narrowly |
| 1000+ elements | `:sets.new(version: 2)` | OTP 28 EEP-70 optimized set; no opaque type issue; Erlang API |

---

## Quick Reference Checklist

| Rule | One-liner |
|------|-----------|
| No comment noise | Name things well, use module attributes |
| Simple `with` | Normalize errors in helpers, not `else` |
| No dynamic atoms | Map explicitly or use `to_existing_atom` |
| Group params | Structs/maps over long arg lists |
| Static map access | `map.key` for required, `map[:key]` for optional |
| Fail fast | Pattern match, don't silently handle bad data |
| `and`/`or` for bools | `&&`/`||` for truthy/falsy only |
| Structs < 32 fields | Nest optional fields |
| Separate return types | Different functions, not option flags |
| Atoms over booleans | Single role atom vs. multiple bool flags |
| Tuples over exceptions | `{:ok, _}` / `{:error, _}` for expected errors |
| Structs over primitives | Domain concepts deserve types |
| Named functions | Don't overload one name for unrelated logic |
| Params over app config | Libraries accept opts, not `Application.get_env` |
| Functions over processes | GenServer is for state/concurrency, not logic |
| One module per process | Centralize Agent/GenServer calls |
| Extract before sending | Don't copy large structs across processes |
| Supervise everything | Long-running processes in supervision trees |
| Prove the branch | Inject seams and assert branch-only side effects |
| `start_link` reason over shape | Accept `{:error, reason}` or linked `EXIT` unless shape is contract |
| Functions over macros | Only macro when you need AST transformation |
| Small quote blocks | Delegate logic to runtime functions |
| Explicit module refs | Let the compiler track dependencies |
| Stream large data | `Stream` over `Enum` for large/unbounded collections |
| Stream files | `File.stream!/1` over `File.read!/1` for large files |
| Stop early | `Stream` + `Enum.take` so you don't process everything |
| Plain maps for small sets | `%{key => []}` + `is_map_key/2` over `MapSet` for < 30 elements |
