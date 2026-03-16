defmodule BaileysEx.Feature.Profile do
  @moduledoc """
  Profile management functions aligned with Baileys `chats.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Connection.Store
  alias BaileysEx.Feature.AppState
  alias BaileysEx.Feature.TcToken
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID
  alias BaileysEx.Protocol.USync

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000
  @default_picture_dimensions %{width: 640, height: 640}

  @type picture_type :: :preview | :image

  @doc """
  Update the profile picture for yourself or a group.

  Mirrors Baileys `updateProfilePicture`. The image bytes are obtained from
  `opts[:picture_generator]` when supplied. Without a generator, the function
  returns an explicit dependency error rather than silently inventing a local
  transform.
  """
  @spec update_picture(term(), String.t(), term(), map() | nil, keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_picture(queryable, jid, image_data, dimensions \\ nil, opts \\ [])

  def update_picture(_queryable, "", _image_data, _dimensions, _opts), do: {:error, :missing_jid}

  def update_picture(queryable, jid, image_data, dimensions, opts)
      when is_binary(jid) and is_list(opts) do
    with {:ok, %{img: img}} <- generate_picture(image_data, dimensions, opts) do
      node = %BinaryNode{
        tag: "iq",
        attrs:
          Map.merge(
            %{
              "to" => @s_whatsapp_net,
              "type" => "set",
              "xmlns" => "w:profile:picture"
            },
            target_attr(jid, opts)
          ),
        content: [%BinaryNode{tag: "picture", attrs: %{"type" => "image"}, content: img}]
      }

      query(queryable, node, Keyword.get(opts, :query_timeout, @timeout))
    end
  end

  @doc """
  Remove the profile picture for yourself or a group.
  """
  @spec remove_picture(term(), String.t(), keyword()) :: {:ok, BinaryNode.t()} | {:error, term()}
  def remove_picture(queryable, jid, opts \\ [])

  def remove_picture(_queryable, "", _opts), do: {:error, :missing_jid}

  def remove_picture(queryable, jid, opts) when is_binary(jid) and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs:
        Map.merge(
          %{
            "to" => @s_whatsapp_net,
            "type" => "set",
            "xmlns" => "w:profile:picture"
          },
          target_attr(jid, opts)
        ),
      content: nil
    }

    query(queryable, node, Keyword.get(opts, :query_timeout, @timeout))
  end

  @doc """
  Fetch the profile-picture URL for a user or group.
  """
  @spec picture_url(term(), String.t(), picture_type(), keyword()) ::
          {:ok, String.t() | nil} | {:error, term()}
  def picture_url(queryable, jid, type \\ :preview, opts \\ [])
      when is_binary(jid) and type in [:preview, :image] and is_list(opts) do
    base_content = [
      %BinaryNode{tag: "picture", attrs: %{"type" => Atom.to_string(type), "query" => "url"}}
    ]

    node = %BinaryNode{
      tag: "iq",
      attrs: %{
        "target" => JID.normalized_user(jid),
        "to" => @s_whatsapp_net,
        "type" => "get",
        "xmlns" => "w:profile:picture"
      },
      content: TcToken.build_content(opts[:signal_store], jid, base_content)
    }

    with {:ok, %BinaryNode{} = response} <-
           query(queryable, node, Keyword.get(opts, :query_timeout, @timeout)) do
      {:ok, response |> BinaryNodeUtil.child("picture") |> maybe_url()}
    end
  end

  @doc """
  Update the display name via the Baileys `pushNameSetting` app-state patch.
  """
  @spec update_name(term(), String.t()) :: {:ok, map()} | {:error, term()}
  def update_name(conn, name) when is_binary(name),
    do: AppState.push_patch(conn, :push_name_setting, "", name)

  @doc """
  Update the profile status text for the current account.
  """
  @spec update_status(term(), String.t(), keyword()) :: {:ok, BinaryNode.t()} | {:error, term()}
  def update_status(queryable, status, opts \\ []) when is_binary(status) and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "status"},
      content: [%BinaryNode{tag: "status", attrs: %{}, content: status}]
    }

    query(queryable, node, Keyword.get(opts, :query_timeout, @timeout))
  end

  @doc """
  Fetch profile status text for one or more JIDs via USync.
  """
  @spec fetch_status(term(), [String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_status(queryable, jids, opts \\ []) when is_list(jids) and is_list(opts) do
    query =
      Enum.reduce(
        jids,
        USync.new(context: :interactive) |> USync.with_protocol(:status),
        fn jid, acc ->
          USync.with_user(acc, %{id: jid})
        end
      )

    if query.users == [] do
      {:ok, []}
    else
      sid =
        Keyword.get_lazy(opts, :sid, fn ->
          Integer.to_string(System.unique_integer([:positive]))
        end)

      with {:ok, node} <- USync.to_node(query, sid),
           {:ok, %BinaryNode{} = response} <-
             query(queryable, node, Keyword.get(opts, :query_timeout, @timeout)),
           {:ok, %{list: list}} <- USync.parse_result(query, response) do
        {:ok, list}
      end
    end
  end

  @doc """
  Fetch the business profile for a given JID.
  """
  @spec get_business_profile(term(), String.t(), keyword()) ::
          {:ok, map() | nil} | {:error, term()}
  def get_business_profile(queryable, jid, opts \\ []) when is_binary(jid) and is_list(opts) do
    node = %BinaryNode{
      tag: "iq",
      attrs: %{"to" => @s_whatsapp_net, "xmlns" => "w:biz", "type" => "get"},
      content: [
        %BinaryNode{
          tag: "business_profile",
          attrs: %{"v" => "244"},
          content: [%BinaryNode{tag: "profile", attrs: %{"jid" => jid}, content: nil}]
        }
      ]
    }

    with {:ok, %BinaryNode{} = response} <-
           query(queryable, node, Keyword.get(opts, :query_timeout, @timeout)) do
      {:ok, parse_business_profile(response)}
    end
  end

  defp maybe_url(%BinaryNode{attrs: attrs}), do: attrs["url"]
  defp maybe_url(nil), do: nil

  defp generate_picture(image_data, dimensions, opts) do
    generator =
      Keyword.get(opts, :picture_generator, fn _image_data, _dimensions ->
        {:error, {:missing_dependency, :profile_picture_generator}}
      end)

    generator.(image_data, normalize_dimensions(dimensions))
  end

  defp normalize_dimensions(nil), do: @default_picture_dimensions
  defp normalize_dimensions(%{width: _width, height: _height} = dimensions), do: dimensions

  defp target_attr(jid, opts) when is_binary(jid) do
    normalized = JID.normalized_user(jid)
    current_user = current_user_jid(opts)

    if normalized == "" or normalized == current_user do
      %{}
    else
      %{"target" => normalized}
    end
  end

  defp current_user_jid(opts) do
    case opts[:me] || store_me(opts[:store]) do
      %{id: id} when is_binary(id) -> JID.normalized_user(id)
      %{"id" => id} when is_binary(id) -> JID.normalized_user(id)
      _ -> nil
    end
  end

  defp store_me(nil), do: nil
  defp store_me(%Store.Ref{} = store), do: Store.get(store, :creds, %{})[:me]

  defp store_me(store) do
    store
    |> Store.wrap()
    |> Store.get(:creds, %{})
    |> Map.get(:me)
  rescue
    ArgumentError -> nil
  end

  defp parse_business_profile(%BinaryNode{} = response) do
    with %BinaryNode{} = business_profile <- BinaryNodeUtil.child(response, "business_profile"),
         %BinaryNode{} = profile <- BinaryNodeUtil.child(business_profile, "profile") do
      address = child_content(profile, "address")
      description = child_content(profile, "description") || ""
      website = child_content(profile, "website")
      email = child_content(profile, "email")

      category =
        profile
        |> BinaryNodeUtil.child("categories")
        |> child_content("category")

      business_hours = BinaryNodeUtil.child(profile, "business_hours")

      %{
        wid: profile.attrs["jid"],
        address: address,
        description: description,
        website: if(is_binary(website), do: [website], else: []),
        email: email,
        category: category,
        business_hours: %{
          timezone: business_hours && business_hours.attrs["timezone"],
          business_config:
            if business_hours do
              Enum.map(
                BinaryNodeUtil.children(business_hours, "business_hours_config"),
                & &1.attrs
              )
            else
              []
            end
        }
      }
    else
      _ -> nil
    end
  end

  defp child_content(nil, _tag), do: nil

  defp child_content(%BinaryNode{} = node, tag) do
    case BinaryNodeUtil.child(node, tag) do
      %BinaryNode{content: {:binary, content}} when is_binary(content) -> content
      %BinaryNode{content: content} when is_binary(content) -> content
      _ -> nil
    end
  end

  defp query(queryable, %BinaryNode{} = node, timeout) when is_function(queryable, 2),
    do: queryable.(node, timeout)

  defp query(queryable, %BinaryNode{} = node, _timeout) when is_function(queryable, 1),
    do: queryable.(node)

  defp query({module, server}, %BinaryNode{} = node, timeout) when is_atom(module),
    do: module.query(server, node, timeout)

  defp query(queryable, %BinaryNode{} = node, timeout),
    do: Socket.query(queryable, node, timeout)
end
