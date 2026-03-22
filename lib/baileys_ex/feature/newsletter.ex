defmodule BaileysEx.Feature.Newsletter do
  @moduledoc """
  Newsletter helpers mapped from Baileys' `newsletter.ts`.
  """

  alias BaileysEx.BinaryNode
  import BaileysEx.Connection.TransportAdapter, only: [query: 3]
  alias BaileysEx.Protocol.WMex

  @create_query_id "8823471724422422"
  @update_metadata_query_id "24250201037901610"
  @metadata_query_id "6563316087068696"
  @subscribers_query_id "9783111038412085"
  @follow_query_id "7871414976211147"
  @unfollow_query_id "7238632346214362"
  @mute_query_id "29766401636284406"
  @unmute_query_id "9864994326891137"
  @admin_count_query_id "7130823597031706"
  @change_owner_query_id "7341777602580933"
  @demote_query_id "6551828931592903"
  @delete_query_id "30062808666639665"
  @timeout 60_000
  @default_picture_dimensions %{width: 640, height: 640}

  @doc "Create a newsletter via WMex."
  @spec create(term(), String.t(), String.t() | nil, keyword()) :: {:ok, map()} | {:error, term()}
  def create(conn, name, description \\ nil, opts \\ [])
      when is_binary(name) and (is_binary(description) or is_nil(description)) and is_list(opts) do
    variables = %{
      "input" => %{
        "name" => name,
        "description" => description
      }
    }

    with {:ok, result} <-
           execute_wmex_query(
             conn,
             variables,
             @create_query_id,
             "xwa2_newsletter_create",
             opts
           ) do
      {:ok, parse_create_response(result)}
    end
  end

  @doc "Delete a newsletter via WMex."
  @spec delete(term(), String.t(), keyword()) :: :ok | {:error, term()}
  def delete(conn, newsletter_jid, opts \\ []) when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, _result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @delete_query_id,
             "xwa2_newsletter_delete_v2",
             opts
           ) do
      :ok
    end
  end

  @doc "Update newsletter metadata via WMex."
  @spec update(term(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def update(conn, newsletter_jid, updates, opts \\ [])
      when is_binary(newsletter_jid) and is_map(updates) and is_list(opts) do
    variables = %{
      "newsletter_id" => newsletter_jid,
      "updates" => Map.put(stringify_keys(updates), "settings", nil)
    }

    with {:ok, result} <-
           execute_wmex_query(
             conn,
             variables,
             @update_metadata_query_id,
             "xwa2_newsletter_update",
             opts
           ) do
      {:ok, normalize_id_result(result)}
    end
  end

  @doc "Fetch newsletter metadata by invite or JID."
  @spec metadata(term(), :invite | :jid, String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def metadata(conn, type, key, opts \\ [])
      when type in [:invite, :jid] and is_binary(key) and is_list(opts) do
    variables = %{
      "fetch_creation_time" => true,
      "fetch_full_image" => true,
      "fetch_viewer_metadata" => true,
      "input" => %{"key" => key, "type" => type |> Atom.to_string() |> String.upcase()}
    }

    with {:ok, result} <-
           execute_wmex_query(conn, variables, @metadata_query_id, "xwa2_newsletter", opts) do
      {:ok, parse_metadata(result)}
    end
  end

  @doc "Fetch subscriber counts."
  @spec subscribers(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def subscribers(conn, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, %{"subscribers" => subscribers}} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @subscribers_query_id,
             "xwa2_newsletter_subscribers",
             opts
           ) do
      {:ok, %{subscribers: subscribers}}
    end
  end

  @doc "Fetch admin counts."
  @spec admin_count(term(), String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def admin_count(conn, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, %{"admin_count" => admin_count}} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @admin_count_query_id,
             "xwa2_newsletter_admin",
             opts
           ) do
      {:ok, admin_count}
    end
  end

  @doc "Follow a newsletter."
  @spec follow(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def follow(conn, newsletter_jid, opts \\ []) when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @follow_query_id,
             "xwa2_newsletter_follow",
             opts
           ) do
      {:ok, normalize_id_result(result)}
    end
  end

  @doc "Unfollow a newsletter."
  @spec unfollow(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def unfollow(conn, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @unfollow_query_id,
             "xwa2_newsletter_unfollow",
             opts
           ) do
      {:ok, normalize_id_result(result)}
    end
  end

  @doc "Mute a newsletter."
  @spec mute(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def mute(conn, newsletter_jid, opts \\ []) when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @mute_query_id,
             "xwa2_newsletter_mute_v2",
             opts
           ) do
      {:ok, normalize_id_result(result)}
    end
  end

  @doc "Unmute a newsletter."
  @spec unmute(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def unmute(conn, newsletter_jid, opts \\ []) when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid},
             @unmute_query_id,
             "xwa2_newsletter_unmute_v2",
             opts
           ) do
      {:ok, normalize_id_result(result)}
    end
  end

  @doc "Subscribe to live newsletter updates over the newsletter IQ transport."
  @spec subscribe_updates(term(), String.t(), keyword()) ::
          {:ok, %{duration: String.t()} | nil} | {:error, term()}
  def subscribe_updates(conn, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, %BinaryNode{} = response} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{
                 "id" => message_tag(opts),
                 "type" => "set",
                 "xmlns" => "newsletter",
                 "to" => newsletter_jid
               },
               content: [%BinaryNode{tag: "live_updates", attrs: %{}, content: []}]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      case Enum.find(response.content || [], &match?(%BinaryNode{tag: "live_updates"}, &1)) do
        %BinaryNode{attrs: %{"duration" => duration}} -> {:ok, %{duration: duration}}
        _ -> {:ok, nil}
      end
    end
  end

  @doc "Fetch newsletter message history over the newsletter IQ transport."
  @spec fetch_messages(term(), String.t(), pos_integer(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def fetch_messages(conn, newsletter_jid, count, opts \\ [])
      when is_binary(newsletter_jid) and is_integer(count) and count > 0 and is_list(opts) do
    attrs =
      %{"count" => Integer.to_string(count)}
      |> maybe_put("since", integer_string(opts[:since]))
      |> maybe_put("after", integer_string(opts[:after]))

    query(
      conn,
      %BinaryNode{
        tag: "iq",
        attrs: %{
          "id" => message_tag(opts),
          "type" => "get",
          "xmlns" => "newsletter",
          "to" => newsletter_jid
        },
        content: [%BinaryNode{tag: "message_updates", attrs: attrs}]
      },
      Keyword.get(opts, :query_timeout, @timeout)
    )
  end

  @doc "Send a newsletter reaction or delete an existing reaction."
  @spec react_message(term(), String.t(), String.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  def react_message(conn, newsletter_jid, server_id, reaction \\ nil, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(server_id) and is_list(opts) do
    attrs =
      %{
        "to" => newsletter_jid,
        "type" => "reaction",
        "server_id" => server_id,
        "id" => message_tag(opts)
      }
      |> maybe_put("edit", if(is_nil(reaction), do: "7", else: nil))

    case query(
           conn,
           %BinaryNode{
             tag: "message",
             attrs: attrs,
             content: [%BinaryNode{tag: "reaction", attrs: reaction_attrs(reaction)}]
           },
           Keyword.get(opts, :query_timeout, @timeout)
         ) do
      {:ok, _} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @doc "Update the newsletter name."
  @spec update_name(term(), String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_name(conn, newsletter_jid, name, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(name) and is_list(opts) do
    update(conn, newsletter_jid, %{name: name}, opts)
  end

  @doc "Update the newsletter description."
  @spec update_description(term(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def update_description(conn, newsletter_jid, description, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(description) and is_list(opts) do
    update(conn, newsletter_jid, %{description: description}, opts)
  end

  @doc "Update the newsletter picture."
  @spec update_picture(term(), String.t(), term(), keyword()) :: {:ok, map()} | {:error, term()}
  def update_picture(conn, newsletter_jid, content, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    with {:ok, %{img: img}} <- generate_picture(content, opts) do
      update(conn, newsletter_jid, %{picture: Base.encode64(img)}, opts)
    end
  end

  @doc "Remove the newsletter picture."
  @spec remove_picture(term(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def remove_picture(conn, newsletter_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_list(opts) do
    update(conn, newsletter_jid, %{picture: ""}, opts)
  end

  @doc "Change the newsletter owner."
  @spec change_owner(term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def change_owner(conn, newsletter_jid, new_owner_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(new_owner_jid) and is_list(opts) do
    with {:ok, _result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid, "user_id" => new_owner_jid},
             @change_owner_query_id,
             "xwa2_newsletter_change_owner",
             opts
           ) do
      :ok
    end
  end

  @doc "Demote a newsletter admin."
  @spec demote(term(), String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def demote(conn, newsletter_jid, user_jid, opts \\ [])
      when is_binary(newsletter_jid) and is_binary(user_jid) and is_list(opts) do
    with {:ok, _result} <-
           execute_wmex_query(
             conn,
             %{"newsletter_id" => newsletter_jid, "user_id" => user_jid},
             @demote_query_id,
             "xwa2_newsletter_demote",
             opts
           ) do
      :ok
    end
  end

  defp execute_wmex_query(conn, variables, query_id, data_path, opts) do
    with {:ok, %BinaryNode{} = response} <-
           query(
             conn,
             WMex.build_query(query_id, variables, message_tag(opts)),
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      WMex.extract_result(response, data_path)
    end
  end

  defp parse_create_response(result) when is_map(result) do
    thread = result["thread_metadata"] || %{}
    viewer = result["viewer_metadata"] || %{}
    picture = thread["picture"] || %{}

    %{
      id: result["id"],
      owner: nil,
      name: get_in(thread, ["name", "text"]),
      creation_time: parse_int(thread["creation_time"]),
      description: get_in(thread, ["description", "text"]),
      invite: thread["invite"],
      subscribers: parse_int(thread["subscribers_count"]),
      verification: thread["verification"],
      picture: %{
        id: picture["id"],
        direct_path: picture["direct_path"]
      },
      mute_state: viewer["mute"]
    }
  end

  defp parse_metadata(%{"id" => _id} = result), do: result
  defp parse_metadata(%{"result" => %{"id" => _id} = result}), do: result
  defp parse_metadata(_result), do: nil

  defp normalize_id_result(%{"id" => id}), do: %{id: id}
  defp normalize_id_result(result), do: result

  defp stringify_keys(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp generate_picture(image_data, opts) do
    generator =
      Keyword.get(opts, :picture_generator, fn _image_data, _dimensions ->
        {:error, {:missing_dependency, :profile_picture_generator}}
      end)

    generator.(image_data, @default_picture_dimensions)
  end

  defp reaction_attrs(nil), do: %{}
  defp reaction_attrs(reaction), do: %{"code" => reaction}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp integer_string(value) when is_integer(value), do: Integer.to_string(value)
  defp integer_string(_value), do: nil

  defp parse_int(nil), do: nil
  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp message_tag(opts) do
    case opts[:message_tag_fun] do
      fun when is_function(fun, 0) -> fun.()
      _ -> Integer.to_string(System.unique_integer([:positive, :monotonic]))
    end
  end

end
