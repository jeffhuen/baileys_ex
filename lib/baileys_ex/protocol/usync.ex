defmodule BaileysEx.Protocol.USync do
  @moduledoc """
  Baileys-aligned USync query builder and result parser.

  Reference:
  - `dev/reference/Baileys-master/src/WAUSync/USyncQuery.ts`
  - `dev/reference/Baileys-master/src/WAUSync/USyncUser.ts`
  - `dev/reference/Baileys-master/src/WAUSync/Protocols/*.ts`
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID

  @protocols [:devices, :contact, :status, :disappearing_mode, :lid, :bot]
  @contexts [:interactive, :background, :message, :notification]
  @modes [:query, :delta]

  defmodule User do
    @moduledoc """
    User selector for a USync query.
    """

    @type t :: %__MODULE__{
            id: String.t() | nil,
            lid: String.t() | nil,
            phone: String.t() | nil,
            type: String.t() | nil,
            persona_id: String.t() | nil
          }

    defstruct [:id, :lid, :phone, :type, :persona_id]
  end

  @type protocol :: :devices | :contact | :status | :disappearing_mode | :lid | :bot
  @type context :: :interactive | :background | :message | :notification
  @type mode :: :query | :delta
  @type user_result :: %{required(:id) => String.t(), optional(atom()) => term()}
  @type result :: %{list: [user_result()], side_list: [user_result()]}

  @type t :: %__MODULE__{
          protocols: [protocol()],
          users: [User.t()],
          context: context(),
          mode: mode()
        }

  defstruct protocols: [], users: [], context: :interactive, mode: :query

  @doc "Creates a new empty USync query configuration struct."
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      protocols:
        opts
        |> Keyword.get(:protocols, [])
        |> Enum.map(&normalize_protocol/1)
        |> Enum.reverse(),
      users:
        opts
        |> Keyword.get(:users, [])
        |> Enum.map(&normalize_user/1)
        |> Enum.reverse(),
      context: normalize_context(Keyword.get(opts, :context, :interactive)),
      mode: normalize_mode(Keyword.get(opts, :mode, :query))
    }
  end

  @doc "Appends an explicit feature protocol string to the USync query."
  @spec with_protocol(t(), protocol() | :device) :: t()
  def with_protocol(%__MODULE__{} = query, protocol) do
    %{query | protocols: [normalize_protocol(protocol) | query.protocols]}
  end

  @doc "Appends a user resolution request payload to the USync query."
  @spec with_user(t(), User.t() | map()) :: t()
  def with_user(%__MODULE__{} = query, %User{} = user) do
    %{query | users: [user | query.users]}
  end

  def with_user(%__MODULE__{} = query, user) when is_map(user) do
    with_user(query, normalize_user(user))
  end

  @doc "Modifies the invocation context context tag."
  @spec with_context(t(), context() | String.t()) :: t()
  def with_context(%__MODULE__{} = query, context) do
    %{query | context: normalize_context(context)}
  end

  @doc "Modifies the USync node query mapping string mode value."
  @spec with_mode(t(), mode() | String.t()) :: t()
  def with_mode(%__MODULE__{} = query, mode) do
    %{query | mode: normalize_mode(mode)}
  end

  @doc "A fast-path method for generating a complete USync query node from raw details."
  @spec build_query([protocol() | :device], [User.t() | map()], keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def build_query(protocols, users, opts \\ []) do
    query = new(Keyword.merge(opts, protocols: protocols, users: users))
    sid = Keyword.get_lazy(opts, :sid, &default_sid/0)
    to_node(query, sid)
  end

  @doc "Marshals the USync struct builder mapping to a final send-able WABinary."
  @spec to_node(t(), String.t()) :: {:ok, BinaryNode.t()} | {:error, term()}
  def to_node(%__MODULE__{protocols: []}, _sid), do: {:error, {:missing_protocols, []}}
  def to_node(%__MODULE__{users: []}, _sid), do: {:error, {:missing_users, []}}

  def to_node(%__MODULE__{} = query, sid) when is_binary(sid) do
    protocols = ordered_protocols(query)

    {:ok,
     %BinaryNode{
       tag: "iq",
       attrs: %{"to" => JID.s_whatsapp_net(), "type" => "get", "xmlns" => "usync"},
       content: [
         %BinaryNode{
           tag: "usync",
           attrs: %{
             "context" => Atom.to_string(query.context),
             "mode" => Atom.to_string(query.mode),
             "sid" => sid,
             "last" => "true",
             "index" => "0"
           },
           content: [
             %BinaryNode{
               tag: "query",
               attrs: %{},
               content: Enum.map(protocols, &protocol_query_node/1)
             },
             %BinaryNode{
               tag: "list",
               attrs: %{},
               content: Enum.map(ordered_users(query), &user_query_node(&1, protocols))
             }
           ]
         }
       ]
     }}
  end

  def to_node(%__MODULE__{}, sid), do: {:error, {:invalid_sid, sid}}

  @doc "Deserializes the query IQ response into structural data maps."
  @spec parse_result(t(), BinaryNode.t()) :: {:ok, result()} | {:error, term()}
  def parse_result(%__MODULE__{} = query, %BinaryNode{attrs: %{"type" => "result"}} = response) do
    with %BinaryNode{} = usync_node <- BinaryNodeUtil.child(response, "usync"),
         {:ok, list} <- parse_user_list(BinaryNodeUtil.child(usync_node, "list"), query.protocols),
         {:ok, side_list} <-
           parse_user_list(BinaryNodeUtil.child(usync_node, "side_list"), query.protocols) do
      {:ok, %{list: list, side_list: side_list}}
    else
      nil -> {:error, :missing_usync}
      {:error, _} = error -> error
    end
  end

  def parse_result(%__MODULE__{}, %BinaryNode{attrs: %{"type" => type}}),
    do: {:error, {:unexpected_iq_type, type}}

  def parse_result(%__MODULE__{}, %BinaryNode{}), do: {:error, {:unexpected_iq_type, nil}}

  defp ordered_protocols(%__MODULE__{protocols: protocols}), do: Enum.reverse(protocols)
  defp ordered_users(%__MODULE__{users: users}), do: Enum.reverse(users)

  defp normalize_user(%User{} = user), do: user
  defp normalize_user(user) when is_map(user), do: struct(User, user)

  defp parse_user_list(nil, _protocols), do: {:ok, []}

  defp parse_user_list(%BinaryNode{} = list_node, protocols) do
    list_node
    |> BinaryNodeUtil.children("user")
    |> Enum.reduce_while({:ok, []}, fn user_node, {:ok, acc} ->
      case parse_user_node(user_node, protocols) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp parse_user_node(%BinaryNode{attrs: attrs} = user_node, protocols) do
    jid = attrs["jid"]

    if is_nil(jid) do
      {:ok, nil}
    else
      with :ok <- BinaryNodeUtil.assert_error_free(user_node),
           {:ok, entry} <- parse_protocol_entries(user_node, protocols, %{id: jid}) do
        {:ok, entry}
      else
        {:error, %{code: _, text: _, node: _} = error} ->
          {:error, {:protocol_error, error, jid}}

        {:error, _} = error ->
          error
      end
    end
  end

  defp parse_protocol_entries(%BinaryNode{} = user_node, protocols, entry) do
    user_node
    |> BinaryNodeUtil.children()
    |> Enum.reduce_while({:ok, entry}, fn child, {:ok, acc} ->
      case parse_protocol_node(child, protocols, entry[:id]) do
        {:ok, nil} -> {:cont, {:ok, acc}}
        {:ok, {key, value}} -> {:cont, {:ok, Map.put(acc, key, value)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp parse_protocol_node(%BinaryNode{tag: "error"}, _protocols, _jid), do: {:ok, nil}

  defp parse_protocol_node(%BinaryNode{tag: tag} = node, protocols, jid) do
    protocol = protocol_for_tag(tag)

    if is_nil(protocol) or protocol not in protocols do
      {:ok, nil}
    else
      with :ok <- BinaryNodeUtil.assert_error_free(node) do
        {:ok, {protocol, parse_protocol_value(protocol, node, jid)}}
      end
    end
  end

  defp parse_protocol_value(:devices, %BinaryNode{} = node) do
    device_list =
      node
      |> BinaryNodeUtil.child("device-list")
      |> BinaryNodeUtil.children("device")
      |> Enum.map(fn %BinaryNode{attrs: attrs} ->
        %{
          id: parse_required_int(attrs["id"]),
          key_index: parse_int(attrs["key-index"]),
          is_hosted: attrs["is_hosted"] == "true"
        }
      end)

    key_index =
      case BinaryNodeUtil.child(node, "key-index-list") do
        nil ->
          nil

        %BinaryNode{attrs: attrs, content: content} ->
          %{
            timestamp: parse_required_int(attrs["ts"]),
            signed_key_index: content_bytes(content),
            expected_timestamp: parse_int(attrs["expected_ts"])
          }
      end

    %{device_list: device_list, key_index: key_index}
  end

  defp parse_protocol_value(:contact, %BinaryNode{attrs: attrs}), do: attrs["type"] == "in"

  defp parse_protocol_value(:status, %BinaryNode{attrs: attrs, content: content}) do
    status =
      case content_string(content) do
        nil -> if(attrs["code"] == "401", do: "", else: nil)
        "" -> if(attrs["code"] == "401", do: "", else: nil)
        value -> value
      end

    %{status: status, set_at: unix_datetime(attrs["t"])}
  end

  defp parse_protocol_value(:disappearing_mode, %BinaryNode{attrs: attrs}) do
    %{duration: parse_required_int(attrs["duration"]), set_at: unix_datetime(attrs["t"])}
  end

  defp parse_protocol_value(:lid, %BinaryNode{attrs: attrs}), do: attrs["val"]

  defp parse_protocol_value(:bot, %BinaryNode{} = node, jid) do
    profile = BinaryNodeUtil.child(node, "profile")
    commands_node = BinaryNodeUtil.child(profile, "commands")
    prompts_node = BinaryNodeUtil.child(profile, "prompts")

    %{
      jid: jid,
      name: BinaryNodeUtil.child_string(profile, "name"),
      attributes: BinaryNodeUtil.child_string(profile, "attributes"),
      description: BinaryNodeUtil.child_string(profile, "description"),
      category: BinaryNodeUtil.child_string(profile, "category"),
      is_default: match?(%BinaryNode{}, BinaryNodeUtil.child(profile, "default")),
      prompts: parse_bot_prompts(prompts_node),
      persona_id: profile && profile.attrs["persona_id"],
      commands: parse_bot_commands(commands_node),
      commands_description: BinaryNodeUtil.child_string(commands_node, "description")
    }
  end

  defp parse_protocol_value(protocol, node, _jid), do: parse_protocol_value(protocol, node)

  defp protocol_query_node(:devices), do: %BinaryNode{tag: "devices", attrs: %{"version" => "2"}}
  defp protocol_query_node(:contact), do: %BinaryNode{tag: "contact", attrs: %{}}
  defp protocol_query_node(:status), do: %BinaryNode{tag: "status", attrs: %{}}

  defp protocol_query_node(:disappearing_mode),
    do: %BinaryNode{tag: "disappearing_mode", attrs: %{}}

  defp protocol_query_node(:lid), do: %BinaryNode{tag: "lid", attrs: %{}}

  defp protocol_query_node(:bot) do
    %BinaryNode{
      tag: "bot",
      attrs: %{},
      content: [%BinaryNode{tag: "profile", attrs: %{"v" => "1"}}]
    }
  end

  defp user_query_node(%User{} = user, protocols) do
    attrs =
      case user.phone do
        nil -> maybe_put(%{}, "jid", user.id)
        _phone -> %{}
      end

    content =
      protocols
      |> Enum.map(&protocol_user_node(&1, user))
      |> Enum.reject(&is_nil/1)

    %BinaryNode{tag: "user", attrs: attrs, content: content}
  end

  defp protocol_user_node(:contact, %User{phone: phone}) when is_binary(phone) do
    %BinaryNode{tag: "contact", attrs: %{}, content: phone}
  end

  defp protocol_user_node(:lid, %User{lid: lid}) when is_binary(lid) do
    %BinaryNode{tag: "lid", attrs: %{"jid" => lid}}
  end

  defp protocol_user_node(:bot, %User{persona_id: persona_id}) when is_binary(persona_id) do
    %BinaryNode{
      tag: "bot",
      attrs: %{},
      content: [%BinaryNode{tag: "profile", attrs: %{"persona_id" => persona_id}}]
    }
  end

  defp protocol_user_node(_protocol, _user), do: nil

  defp default_sid do
    System.unique_integer([:positive])
    |> Integer.to_string()
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp normalize_protocol(:device), do: :devices
  defp normalize_protocol(protocol) when protocol in @protocols, do: protocol

  defp normalize_protocol(protocol),
    do: raise(ArgumentError, "unsupported USync protocol: #{inspect(protocol)}")

  defp normalize_context("interactive"), do: :interactive
  defp normalize_context("background"), do: :background
  defp normalize_context("message"), do: :message
  defp normalize_context("notification"), do: :notification
  defp normalize_context(context) when context in @contexts, do: context

  defp normalize_context(context),
    do: raise(ArgumentError, "unsupported USync context: #{inspect(context)}")

  defp normalize_mode("query"), do: :query
  defp normalize_mode("delta"), do: :delta
  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(mode), do: raise(ArgumentError, "unsupported USync mode: #{inspect(mode)}")

  defp protocol_for_tag("devices"), do: :devices
  defp protocol_for_tag("contact"), do: :contact
  defp protocol_for_tag("status"), do: :status
  defp protocol_for_tag("disappearing_mode"), do: :disappearing_mode
  defp protocol_for_tag("lid"), do: :lid
  defp protocol_for_tag("bot"), do: :bot
  defp protocol_for_tag(_tag), do: nil

  defp content_bytes({:binary, bytes}) when is_binary(bytes), do: bytes
  defp content_bytes(bytes) when is_binary(bytes), do: bytes
  defp content_bytes(_content), do: nil

  defp content_string({:binary, bytes}) when is_binary(bytes), do: bytes
  defp content_string(bytes) when is_binary(bytes), do: bytes
  defp content_string(_content), do: nil

  defp parse_required_int(value) do
    case parse_int(value) do
      nil -> raise ArgumentError, "expected integer string, got: #{inspect(value)}"
      int -> int
    end
  end

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp unix_datetime(nil), do: DateTime.from_unix!(0)

  defp unix_datetime(value) when is_binary(value) do
    case parse_int(value) do
      nil -> nil
      seconds -> DateTime.from_unix!(seconds)
    end
  end

  defp parse_bot_commands(commands_node) do
    commands_node
    |> BinaryNodeUtil.children("command")
    |> Enum.map(fn command ->
      %{
        name: BinaryNodeUtil.child_string(command, "name"),
        description: BinaryNodeUtil.child_string(command, "description")
      }
    end)
  end

  defp parse_bot_prompts(prompts_node) do
    prompts_node
    |> BinaryNodeUtil.children("prompt")
    |> Enum.map(fn prompt ->
      [BinaryNodeUtil.child_string(prompt, "emoji"), BinaryNodeUtil.child_string(prompt, "text")]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end)
  end
end
