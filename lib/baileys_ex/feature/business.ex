defmodule BaileysEx.Feature.Business do
  @moduledoc """
  Business helpers mapped from Baileys' `business.ts`.
  """

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.Socket
  alias BaileysEx.Protocol.BinaryNode, as: BinaryNodeUtil
  alias BaileysEx.Protocol.JID

  @s_whatsapp_net "s.whatsapp.net"
  @timeout 60_000
  @product_key_map %{
    "name" => :name,
    "description" => :description,
    "retailer_id" => :retailer_id,
    "images" => :images,
    "price" => :price,
    "currency" => :currency,
    "origin_country_code" => :origin_country_code,
    "is_hidden" => :is_hidden
  }

  @doc "Update the business profile mutation payload."
  @spec update_business_profile(term(), map(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def update_business_profile(conn, profile_data, opts \\ [])
      when is_map(profile_data) and is_list(opts) do
    query(
      conn,
      %BinaryNode{
        tag: "iq",
        attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz"},
        content: [
          %BinaryNode{
            tag: "business_profile",
            attrs: %{"v" => "3", "mutation_type" => "delta"},
            content: business_profile_content(profile_data)
          }
        ]
      },
      Keyword.get(opts, :query_timeout, @timeout)
    )
  end

  @doc "Upload and set the business cover photo."
  @spec update_cover_photo(term(), term(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def update_cover_photo(conn, photo, opts \\ []) when is_list(opts) do
    with {:ok, %{file_sha256: file_sha256, file_path: file_path}} <-
           raw_media_upload_data(photo, "biz-cover-photo", opts),
         {:ok, %{meta_hmac: meta_hmac, fbid: fbid, ts: ts}} <-
           media_upload(
             file_path,
             %{
               file_enc_sha256_b64: Base.encode64(file_sha256),
               media_type: "biz-cover-photo"
             },
             opts
           ),
         {:ok, _response} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz"},
               content: [
                 %BinaryNode{
                   tag: "business_profile",
                   attrs: %{"v" => "3", "mutation_type" => "delta"},
                   content: [
                     %BinaryNode{
                       tag: "cover_photo",
                       attrs: %{
                         "id" => to_string(fbid),
                         "op" => "update",
                         "token" => meta_hmac,
                         "ts" => to_string(ts)
                       }
                     }
                   ]
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      {:ok, to_string(fbid)}
    end
  end

  @doc "Remove the business cover photo."
  @spec remove_cover_photo(term(), String.t(), keyword()) ::
          {:ok, BinaryNode.t()} | {:error, term()}
  def remove_cover_photo(conn, cover_id, opts \\ [])
      when is_binary(cover_id) and is_list(opts) do
    query(
      conn,
      %BinaryNode{
        tag: "iq",
        attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz"},
        content: [
          %BinaryNode{
            tag: "business_profile",
            attrs: %{"v" => "3", "mutation_type" => "delta"},
            content: [
              %BinaryNode{tag: "cover_photo", attrs: %{"op" => "delete", "id" => cover_id}}
            ]
          }
        ]
      },
      Keyword.get(opts, :query_timeout, @timeout)
    )
  end

  @doc "Fetch the product catalog for a business."
  @spec get_catalog(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def get_catalog(conn, opts \\ []) when is_list(opts) do
    jid = opts[:jid] || me_id(opts[:me])
    jid = JID.normalized_user(jid)
    limit = opts[:limit] || 10

    content =
      [
        %BinaryNode{tag: "limit", attrs: %{}, content: Integer.to_string(limit)},
        %BinaryNode{tag: "width", attrs: %{}, content: "100"},
        %BinaryNode{tag: "height", attrs: %{}, content: "100"}
      ]
      |> maybe_append_cursor(opts[:cursor])

    with {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{"to" => @s_whatsapp_net, "type" => "get", "xmlns" => "w:biz:catalog"},
               content: [
                 %BinaryNode{
                   tag: "product_catalog",
                   attrs: %{"jid" => jid, "allow_shop_source" => "true"},
                   content: content
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      {:ok, parse_catalog(result)}
    end
  end

  @doc "Fetch business catalog collections."
  @spec get_collections(term(), String.t() | nil, pos_integer(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_collections(conn, jid \\ nil, limit \\ 51, opts \\ [])
      when is_list(opts) and is_integer(limit) and limit > 0 do
    jid = jid || me_id(opts[:me])
    jid = JID.normalized_user(jid)

    with {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{
                 "to" => @s_whatsapp_net,
                 "type" => "get",
                 "xmlns" => "w:biz:catalog",
                 "smax_id" => "35"
               },
               content: [
                 %BinaryNode{
                   tag: "collections",
                   attrs: %{"biz_jid" => jid},
                   content: [
                     %BinaryNode{
                       tag: "collection_limit",
                       attrs: %{},
                       content: Integer.to_string(limit)
                     },
                     %BinaryNode{
                       tag: "item_limit",
                       attrs: %{},
                       content: Integer.to_string(limit)
                     },
                     %BinaryNode{tag: "width", attrs: %{}, content: "100"},
                     %BinaryNode{tag: "height", attrs: %{}, content: "100"}
                   ]
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      {:ok, parse_collections(result)}
    end
  end

  @doc "Create a business product."
  @spec product_create(term(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def product_create(conn, product, opts \\ []) when is_map(product) and is_list(opts) do
    product =
      product
      |> Map.put_new(:is_hidden, false)
      |> upload_product_images(opts)

    with {:ok, product} <- product,
         {:ok, product_node} <- to_product_node(nil, product),
         {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz:catalog"},
               content: [
                 %BinaryNode{
                   tag: "product_catalog_add",
                   attrs: %{"v" => "1"},
                   content: [
                     product_node,
                     %BinaryNode{tag: "width", attrs: %{}, content: "100"},
                     %BinaryNode{tag: "height", attrs: %{}, content: "100"}
                   ]
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      result
      |> BinaryNodeUtil.child("product_catalog_add")
      |> BinaryNodeUtil.child("product")
      |> then(&{:ok, parse_product(&1)})
    end
  end

  @doc "Update a business product."
  @spec product_update(term(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def product_update(conn, product_id, updates, opts \\ [])
      when is_binary(product_id) and is_map(updates) and is_list(opts) do
    with {:ok, product} <- upload_product_images(updates, opts),
         {:ok, product_node} <- to_product_node(product_id, product),
         {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz:catalog"},
               content: [
                 %BinaryNode{
                   tag: "product_catalog_edit",
                   attrs: %{"v" => "1"},
                   content: [
                     product_node,
                     %BinaryNode{tag: "width", attrs: %{}, content: "100"},
                     %BinaryNode{tag: "height", attrs: %{}, content: "100"}
                   ]
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      result
      |> BinaryNodeUtil.child("product_catalog_edit")
      |> BinaryNodeUtil.child("product")
      |> then(&{:ok, parse_product(&1)})
    end
  end

  @doc "Delete products from the catalog."
  @spec product_delete(term(), [String.t()], keyword()) ::
          {:ok, %{deleted: non_neg_integer()}} | {:error, term()}
  def product_delete(conn, product_ids, opts \\ [])
      when is_list(product_ids) and is_list(opts) do
    with {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{"to" => @s_whatsapp_net, "type" => "set", "xmlns" => "w:biz:catalog"},
               content: [
                 %BinaryNode{
                   tag: "product_catalog_delete",
                   attrs: %{"v" => "1"},
                   content:
                     Enum.map(product_ids, fn product_id ->
                       %BinaryNode{
                         tag: "product",
                         attrs: %{},
                         content: [%BinaryNode{tag: "id", attrs: %{}, content: product_id}]
                       }
                     end)
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      deleted_count =
        case BinaryNodeUtil.child(result, "product_catalog_delete") do
          %BinaryNode{attrs: %{"deleted_count" => count}} -> parse_int(count) || 0
          _ -> 0
        end

      {:ok, %{deleted: deleted_count}}
    end
  end

  @doc "Fetch order details via the thrift IQ namespace."
  @spec get_order_details(term(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def get_order_details(conn, order_id, token, opts \\ [])
      when is_binary(order_id) and is_binary(token) and is_list(opts) do
    with {:ok, result} <-
           query(
             conn,
             %BinaryNode{
               tag: "iq",
               attrs: %{
                 "to" => @s_whatsapp_net,
                 "type" => "get",
                 "xmlns" => "fb:thrift_iq",
                 "smax_id" => "5"
               },
               content: [
                 %BinaryNode{
                   tag: "order",
                   attrs: %{"op" => "get", "id" => order_id},
                   content: [
                     %BinaryNode{
                       tag: "image_dimensions",
                       attrs: %{},
                       content: [
                         %BinaryNode{tag: "width", attrs: %{}, content: "100"},
                         %BinaryNode{tag: "height", attrs: %{}, content: "100"}
                       ]
                     },
                     %BinaryNode{tag: "token", attrs: %{}, content: token}
                   ]
                 }
               ]
             },
             Keyword.get(opts, :query_timeout, @timeout)
           ) do
      {:ok, parse_order_details(result)}
    end
  end

  defp business_profile_content(profile_data) do
    []
    |> maybe_append_simple_field("address", profile_data[:address] || profile_data["address"])
    |> maybe_append_simple_field("email", profile_data[:email] || profile_data["email"])
    |> maybe_append_simple_field(
      "description",
      profile_data[:description] || profile_data["description"]
    )
    |> append_websites(profile_data[:websites] || profile_data["websites"])
    |> append_business_hours(profile_data[:hours] || profile_data["hours"])
  end

  defp append_websites(content, websites) when is_list(websites) do
    content ++ Enum.map(websites, &%BinaryNode{tag: "website", attrs: %{}, content: &1})
  end

  defp append_websites(content, _websites), do: content

  defp append_business_hours(content, %{timezone: timezone, days: days})
       when is_binary(timezone) and is_list(days) do
    content ++
      [
        %BinaryNode{
          tag: "business_hours",
          attrs: %{"timezone" => timezone},
          content: Enum.map(days, &business_hours_config/1)
        }
      ]
  end

  defp append_business_hours(content, %{"timezone" => timezone, "days" => days})
       when is_binary(timezone) and is_list(days) do
    append_business_hours(content, %{timezone: timezone, days: days})
  end

  defp append_business_hours(content, _hours), do: content

  defp business_hours_config(day_config) do
    day = day_config[:day] || day_config["day"]
    mode = day_config[:mode] || day_config["mode"]

    attrs =
      %{"day_of_week" => day, "mode" => mode}
      |> maybe_put("open_time", day_config[:open_time] || day_config["open_time"])
      |> maybe_put("close_time", day_config[:close_time] || day_config["close_time"])

    %BinaryNode{tag: "business_hours_config", attrs: attrs}
  end

  defp maybe_append_simple_field(content, _tag, nil), do: content

  defp maybe_append_simple_field(content, tag, value) do
    content ++ [%BinaryNode{tag: tag, attrs: %{}, content: value}]
  end

  defp upload_product_images(product, opts) do
    images = product[:images] || product["images"]
    upload_fun = opts[:upload_product_images_fun]

    cond do
      not is_list(images) or images == [] ->
        {:ok, product}

      Enum.all?(images, &uploaded_image?/1) ->
        {:ok, product}

      is_function(upload_fun, 1) ->
        with {:ok, uploaded_images} <- upload_fun.(images) do
          {:ok, put_images(product, uploaded_images)}
        end

      true ->
        {:error, {:missing_dependency, :product_image_uploader}}
    end
  end

  defp uploaded_image?(%{url: url}) when is_binary(url),
    do: String.contains?(url, ".whatsapp.net")

  defp uploaded_image?(%{"url" => url}) when is_binary(url),
    do: String.contains?(url, ".whatsapp.net")

  defp uploaded_image?(_image), do: false

  defp put_images(product, uploaded_images) when is_map_key(product, :images),
    do: Map.put(product, :images, uploaded_images)

  defp put_images(product, uploaded_images), do: Map.put(product, "images", uploaded_images)

  defp raw_media_upload_data(photo, media_type, opts) do
    case opts[:raw_media_upload_data_fun] do
      fun when is_function(fun, 2) -> fun.(photo, media_type)
      _ -> {:error, {:missing_dependency, :raw_media_upload_data}}
    end
  end

  defp media_upload(file_path, upload_opts, opts) do
    case opts[:media_upload_fun] do
      fun when is_function(fun, 2) -> fun.(file_path, upload_opts)
      _ -> {:error, {:missing_dependency, :media_upload}}
    end
  end

  defp parse_catalog(node) do
    catalog_node = BinaryNodeUtil.child(node, "product_catalog")

    %{
      products: Enum.map(BinaryNodeUtil.children(catalog_node, "product"), &parse_product/1),
      next_page_cursor:
        catalog_node
        |> BinaryNodeUtil.child("paging")
        |> BinaryNodeUtil.child_string("after")
    }
  end

  defp parse_collections(node) do
    collections =
      node
      |> BinaryNodeUtil.child("collections")
      |> BinaryNodeUtil.children("collection")
      |> Enum.map(fn collection_node ->
        %{
          id: BinaryNodeUtil.child_string(collection_node, "id"),
          name: BinaryNodeUtil.child_string(collection_node, "name"),
          products:
            Enum.map(BinaryNodeUtil.children(collection_node, "product"), &parse_product/1),
          status: parse_status_info(collection_node)
        }
      end)

    %{collections: collections}
  end

  defp parse_order_details(node) do
    order_node = BinaryNodeUtil.child(node, "order")
    price_node = BinaryNodeUtil.child(order_node, "price")

    %{
      price: %{
        total: parse_int(BinaryNodeUtil.child_string(price_node, "total")),
        currency: BinaryNodeUtil.child_string(price_node, "currency")
      },
      products:
        Enum.map(BinaryNodeUtil.children(order_node, "product"), fn product_node ->
          image_node = BinaryNodeUtil.child(product_node, "image")

          %{
            id: BinaryNodeUtil.child_string(product_node, "id"),
            name: BinaryNodeUtil.child_string(product_node, "name"),
            image_url: BinaryNodeUtil.child_string(image_node, "url"),
            price: parse_int(BinaryNodeUtil.child_string(product_node, "price")),
            currency: BinaryNodeUtil.child_string(product_node, "currency"),
            quantity: parse_int(BinaryNodeUtil.child_string(product_node, "quantity"))
          }
        end)
    }
  end

  defp to_product_node(product_id, product) do
    product = normalize_product(product)

    attrs =
      %{}
      |> maybe_put("compliance_category", compliance_category(product))
      |> maybe_put("is_hidden", boolean_string(product[:is_hidden]))

    with {:ok, content} <-
           []
           |> maybe_append_simple_field("id", product_id)
           |> maybe_append_simple_field("name", product[:name])
           |> maybe_append_simple_field("description", product[:description])
           |> maybe_append_simple_field("retailer_id", product[:retailer_id])
           |> append_product_images(product[:images] || []) do
      content =
        content
        |> maybe_append_simple_field("price", maybe_string(product[:price]))
        |> maybe_append_simple_field("currency", product[:currency])
        |> append_origin_country_code(product[:origin_country_code])

      {:ok, %BinaryNode{tag: "product", attrs: attrs, content: content}}
    end
  end

  defp append_product_images(content, images) when is_list(images) and images != [] do
    with {:ok, image_nodes} <- images |> Enum.map(&product_image_node/1) |> collect_ok() do
      {:ok,
       content ++
         [
           %BinaryNode{
             tag: "media",
             attrs: %{},
             content: image_nodes
           }
         ]}
    end
  end

  defp append_product_images(content, _images), do: {:ok, content}

  defp append_origin_country_code(content, nil), do: content

  defp append_origin_country_code(content, country_code) do
    content ++
      [
        %BinaryNode{
          tag: "compliance_info",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "country_code_origin",
              attrs: %{},
              content: country_code
            }
          ]
        }
      ]
  end

  defp compliance_category(%{origin_country_code: nil}), do: "COUNTRY_ORIGIN_EXEMPT"
  defp compliance_category(%{origin_country_code: _country_code}), do: nil
  defp compliance_category(_product), do: nil

  defp parse_product(nil), do: nil

  defp parse_product(product_node) do
    status_info_node = BinaryNodeUtil.child(product_node, "status_info")
    media_node = BinaryNodeUtil.child(product_node, "media")
    image_node = BinaryNodeUtil.child(media_node, "image")

    %{
      id: BinaryNodeUtil.child_string(product_node, "id"),
      image_urls: %{
        requested: BinaryNodeUtil.child_string(image_node, "request_image_url"),
        original: BinaryNodeUtil.child_string(image_node, "original_image_url")
      },
      review_status: %{whatsapp: BinaryNodeUtil.child_string(status_info_node, "status")},
      availability: "in stock",
      name: BinaryNodeUtil.child_string(product_node, "name"),
      retailer_id: BinaryNodeUtil.child_string(product_node, "retailer_id"),
      url: BinaryNodeUtil.child_string(product_node, "url"),
      description: BinaryNodeUtil.child_string(product_node, "description"),
      price: parse_int(BinaryNodeUtil.child_string(product_node, "price")),
      currency: BinaryNodeUtil.child_string(product_node, "currency"),
      is_hidden: product_node.attrs["is_hidden"] == "true"
    }
  end

  defp parse_status_info(node) do
    status_info = BinaryNodeUtil.child(node, "status_info")

    %{
      status: BinaryNodeUtil.child_string(status_info, "status"),
      can_appeal: BinaryNodeUtil.child_string(status_info, "can_appeal") == "true"
    }
  end

  defp maybe_append_cursor(content, nil), do: content

  defp maybe_append_cursor(content, cursor),
    do: content ++ [%BinaryNode{tag: "after", attrs: %{}, content: cursor}]

  defp product_image_node(%{url: url}) when is_binary(url),
    do: {:ok, build_product_image_node(url)}

  defp product_image_node(%{"url" => url}) when is_binary(url),
    do: {:ok, build_product_image_node(url)}

  defp product_image_node(_image), do: {:error, :invalid_product_image}

  defp build_product_image_node(url) do
    %BinaryNode{
      tag: "image",
      attrs: %{},
      content: [%BinaryNode{tag: "url", attrs: %{}, content: url}]
    }
  end

  defp collect_ok(results) do
    results
    |> Enum.reduce_while({:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp me_id(%{id: id}) when is_binary(id), do: id
  defp me_id(%{"id" => id}) when is_binary(id), do: id
  defp me_id(_me), do: nil

  defp normalize_product(product) do
    Enum.reduce(product, %{}, fn
      {key, value}, acc when is_binary(key) ->
        case @product_key_map[key] do
          nil -> acc
          atom_key -> Map.put(acc, atom_key, value)
        end

      {key, value}, acc ->
        Map.put(acc, key, value)
    end)
  end

  defp boolean_string(true), do: "true"
  defp boolean_string(false), do: "false"
  defp boolean_string(nil), do: nil

  defp maybe_string(nil), do: nil
  defp maybe_string(value) when is_binary(value), do: value
  defp maybe_string(value) when is_integer(value), do: Integer.to_string(value)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_int(nil), do: nil

  defp parse_int(value) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
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
