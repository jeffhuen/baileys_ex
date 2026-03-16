defmodule BaileysEx.Feature.BusinessTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Feature.Business

  test "update_business_profile builds the Baileys business profile mutation" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, %BinaryNode{tag: "iq"}} =
             Business.update_business_profile(query_fun, %{
               address: "1 Market",
               email: "support@example.com",
               description: "Phase 11 business",
               websites: ["https://example.com", "https://shop.example.com"],
               hours: %{
                 timezone: "America/Los_Angeles",
                 days: [
                   %{
                     day: "MONDAY",
                     mode: "specific_hours",
                     open_time: "540",
                     close_time: "1020"
                   },
                   %{day: "TUESDAY", mode: "open_24h"}
                 ]
               }
             })

    assert_receive {:query,
                    %BinaryNode{
                      tag: "iq",
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz"
                      },
                      content: [
                        %BinaryNode{
                          tag: "business_profile",
                          attrs: %{"v" => "3", "mutation_type" => "delta"},
                          content: [
                            %BinaryNode{tag: "address", content: "1 Market"},
                            %BinaryNode{tag: "email", content: "support@example.com"},
                            %BinaryNode{tag: "description", content: "Phase 11 business"},
                            %BinaryNode{tag: "website", content: "https://example.com"},
                            %BinaryNode{tag: "website", content: "https://shop.example.com"},
                            %BinaryNode{
                              tag: "business_hours",
                              attrs: %{"timezone" => "America/Los_Angeles"},
                              content: [
                                %BinaryNode{
                                  tag: "business_hours_config",
                                  attrs: %{
                                    "day_of_week" => "MONDAY",
                                    "mode" => "specific_hours",
                                    "open_time" => "540",
                                    "close_time" => "1020"
                                  }
                                },
                                %BinaryNode{
                                  tag: "business_hours_config",
                                  attrs: %{"day_of_week" => "TUESDAY", "mode" => "open_24h"}
                                }
                              ]
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "cover photo mutations use the media upload pipeline and the correct biz node shape" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, %BinaryNode{tag: "iq", attrs: %{"type" => "result"}, content: nil}}
    end

    assert {:ok, "fbid-123"} =
             Business.update_cover_photo(query_fun, :cover_photo,
               raw_media_upload_data_fun: fn :cover_photo, "biz-cover-photo" ->
                 {:ok, %{file_sha256: <<1, 2, 3>>, file_path: "/tmp/cover-photo"}}
               end,
               media_upload_fun: fn "/tmp/cover-photo",
                                    %{
                                      file_enc_sha256_b64: "AQID",
                                      media_type: "biz-cover-photo"
                                    } ->
                 {:ok, %{meta_hmac: "hmac-123", fbid: "fbid-123", ts: 1_710_000_000}}
               end
             )

    assert {:ok, %BinaryNode{tag: "iq"}} =
             Business.remove_cover_photo(query_fun, "fbid-123")

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz"
                      },
                      content: [
                        %BinaryNode{
                          tag: "business_profile",
                          attrs: %{"v" => "3", "mutation_type" => "delta"},
                          content: [
                            %BinaryNode{
                              tag: "cover_photo",
                              attrs: %{
                                "id" => "fbid-123",
                                "op" => "update",
                                "token" => "hmac-123",
                                "ts" => "1710000000"
                              }
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz"
                      },
                      content: [
                        %BinaryNode{
                          tag: "business_profile",
                          attrs: %{"v" => "3", "mutation_type" => "delta"},
                          content: [
                            %BinaryNode{
                              tag: "cover_photo",
                              attrs: %{"op" => "delete", "id" => "fbid-123"}
                            }
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "catalog, product, and order helpers mirror the Baileys business nodes" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})

      response =
        case {node.attrs["xmlns"], node.content} do
          {"w:biz:catalog", [%BinaryNode{tag: "product_catalog"}]} ->
            catalog_result_node()

          {"w:biz:catalog", [%BinaryNode{tag: "collections"}]} ->
            collections_result_node()

          {"w:biz:catalog", [%BinaryNode{tag: "product_catalog_add"}]} ->
            product_catalog_add_result_node()

          {"w:biz:catalog", [%BinaryNode{tag: "product_catalog_edit"}]} ->
            product_catalog_edit_result_node()

          {"w:biz:catalog", [%BinaryNode{tag: "product_catalog_delete"}]} ->
            %BinaryNode{
              tag: "iq",
              attrs: %{"type" => "result"},
              content: [
                %BinaryNode{
                  tag: "product_catalog_delete",
                  attrs: %{"deleted_count" => "2"}
                }
              ]
            }

          {"fb:thrift_iq", [%BinaryNode{tag: "order"}]} ->
            order_details_result_node()
        end

      {:ok, response}
    end

    assert {:ok, catalog} =
             Business.get_catalog(query_fun,
               jid: "15550001111:2@s.whatsapp.net",
               limit: 20,
               cursor: "cursor-1"
             )

    assert catalog.next_page_cursor == "cursor-2"
    assert [%{id: "prod-1", name: "Product One"}] = catalog.products

    assert {:ok, %{collections: [%{id: "collection-1", name: "Featured"}]}} =
             Business.get_collections(query_fun, "15550001111:2@s.whatsapp.net", 25)

    assert {:ok, product} =
             Business.product_create(query_fun, %{
               name: "Product One",
               description: "Body",
               retailer_id: "SKU-1",
               images: [%{url: "https://mmg.whatsapp.net/product-1"}],
               price: 5000,
               currency: "USD",
               origin_country_code: "US"
             })

    assert product.id == "prod-1"

    assert {:ok, updated_product} =
             Business.product_update(query_fun, "prod-1", %{
               name: "Product One Updated",
               description: "Updated body",
               retailer_id: "SKU-1",
               images: [%{url: "https://mmg.whatsapp.net/product-1"}],
               price: 5500,
               currency: "USD",
               is_hidden: true,
               origin_country_code: nil
             })

    assert updated_product.id == "prod-1"
    assert updated_product.is_hidden == true

    assert {:ok, %{deleted: 2}} = Business.product_delete(query_fun, ["prod-1", "prod-2"])

    assert {:ok, order_details} = Business.get_order_details(query_fun, "order-1", "token-1")
    assert order_details.price.total == 5000
    assert [%{id: "prod-1", quantity: 2}] = order_details.products

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "w:biz:catalog"
                      },
                      content: [
                        %BinaryNode{
                          tag: "product_catalog",
                          attrs: %{
                            "jid" => "15550001111@s.whatsapp.net",
                            "allow_shop_source" => "true"
                          },
                          content: [
                            %BinaryNode{tag: "limit", content: "20"},
                            %BinaryNode{tag: "width", content: "100"},
                            %BinaryNode{tag: "height", content: "100"},
                            %BinaryNode{tag: "after", content: "cursor-1"}
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "w:biz:catalog",
                        "smax_id" => "35"
                      },
                      content: [
                        %BinaryNode{
                          tag: "collections",
                          attrs: %{"biz_jid" => "15550001111@s.whatsapp.net"},
                          content: [
                            %BinaryNode{tag: "collection_limit", content: "25"},
                            %BinaryNode{tag: "item_limit", content: "25"},
                            %BinaryNode{tag: "width", content: "100"},
                            %BinaryNode{tag: "height", content: "100"}
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz:catalog"
                      },
                      content: [
                        %BinaryNode{
                          tag: "product_catalog_add",
                          attrs: %{"v" => "1"},
                          content: [
                            %BinaryNode{
                              tag: "product",
                              attrs: %{},
                              content: product_content
                            },
                            %BinaryNode{tag: "width", content: "100"},
                            %BinaryNode{tag: "height", content: "100"}
                          ]
                        }
                      ]
                    }, 60_000}

    assert Enum.any?(
             product_content,
             &match?(%BinaryNode{tag: "name", content: "Product One"}, &1)
           )

    assert Enum.any?(
             product_content,
             &match?(%BinaryNode{tag: "retailer_id", content: "SKU-1"}, &1)
           )

    assert Enum.any?(product_content, &match?(%BinaryNode{tag: "price", content: "5000"}, &1))
    assert Enum.any?(product_content, &match?(%BinaryNode{tag: "currency", content: "USD"}, &1))

    assert Enum.any?(product_content, fn
             %BinaryNode{
               tag: "media",
               content: [
                 %BinaryNode{
                   tag: "image",
                   content: [
                     %BinaryNode{tag: "url", content: "https://mmg.whatsapp.net/product-1"}
                   ]
                 }
               ]
             } ->
               true

             _ ->
               false
           end)

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz:catalog"
                      },
                      content: [
                        %BinaryNode{
                          tag: "product_catalog_edit",
                          attrs: %{"v" => "1"},
                          content: [
                            %BinaryNode{
                              tag: "product",
                              attrs: %{
                                "is_hidden" => "true",
                                "compliance_category" => "COUNTRY_ORIGIN_EXEMPT"
                              },
                              content: edit_content
                            },
                            %BinaryNode{tag: "width", content: "100"},
                            %BinaryNode{tag: "height", content: "100"}
                          ]
                        }
                      ]
                    }, 60_000}

    assert Enum.any?(edit_content, &match?(%BinaryNode{tag: "id", content: "prod-1"}, &1))

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "set",
                        "xmlns" => "w:biz:catalog"
                      },
                      content: [
                        %BinaryNode{
                          tag: "product_catalog_delete",
                          attrs: %{"v" => "1"},
                          content: [
                            %BinaryNode{
                              tag: "product",
                              content: [%BinaryNode{tag: "id", content: "prod-1"}]
                            },
                            %BinaryNode{
                              tag: "product",
                              content: [%BinaryNode{tag: "id", content: "prod-2"}]
                            }
                          ]
                        }
                      ]
                    }, 60_000}

    assert_receive {:query,
                    %BinaryNode{
                      attrs: %{
                        "to" => "s.whatsapp.net",
                        "type" => "get",
                        "xmlns" => "fb:thrift_iq",
                        "smax_id" => "5"
                      },
                      content: [
                        %BinaryNode{
                          tag: "order",
                          attrs: %{"op" => "get", "id" => "order-1"},
                          content: [
                            %BinaryNode{
                              tag: "image_dimensions",
                              content: [
                                %BinaryNode{tag: "width", content: "100"},
                                %BinaryNode{tag: "height", content: "100"}
                              ]
                            },
                            %BinaryNode{tag: "token", content: "token-1"}
                          ]
                        }
                      ]
                    }, 60_000}
  end

  test "product image handling only skips upload for WhatsApp-hosted URLs" do
    parent = self()

    query_fun = fn node, timeout ->
      send(parent, {:query, node, timeout})
      {:ok, product_catalog_add_result_node()}
    end

    assert {:ok, %{id: "prod-1"}} =
             Business.product_create(
               query_fun,
               %{
                 name: "Product One",
                 description: "Body",
                 retailer_id: "SKU-1",
                 images: [%{url: "https://example.com/product-1"}],
                 price: 5000,
                 currency: "USD"
               },
               upload_product_images_fun: fn images ->
                 send(parent, {:upload_images, images})
                 {:ok, [%{url: "https://mmg.whatsapp.net/uploaded-product-1"}]}
               end
             )

    assert_receive {:upload_images, [%{url: "https://example.com/product-1"}]}

    assert_receive {:query,
                    %BinaryNode{
                      content: [
                        %BinaryNode{
                          tag: "product_catalog_add",
                          content: [
                            %BinaryNode{
                              tag: "product",
                              content: product_content
                            },
                            %BinaryNode{tag: "width", content: "100"},
                            %BinaryNode{tag: "height", content: "100"}
                          ]
                        }
                      ]
                    }, 60_000}

    assert Enum.any?(product_content, fn
             %BinaryNode{
               tag: "media",
               content: [
                 %BinaryNode{
                   tag: "image",
                   content: [
                     %BinaryNode{
                       tag: "url",
                       content: "https://mmg.whatsapp.net/uploaded-product-1"
                     }
                   ]
                 }
               ]
             } ->
               true

             _ ->
               false
           end)
  end

  test "product_create errors when uploaded product images still do not contain urls" do
    query_fun = fn _node, _timeout ->
      flunk("product create should fail before issuing a query")
    end

    assert {:error, :invalid_product_image} =
             Business.product_create(
               query_fun,
               %{
                 name: "Product One",
                 description: "Body",
                 retailer_id: "SKU-1",
                 images: [%{path: "/tmp/local-image.jpg"}],
                 price: 5000,
                 currency: "USD"
               },
               upload_product_images_fun: fn images -> {:ok, images} end
             )
  end

  defp catalog_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "product_catalog",
          attrs: %{},
          content: [
            product_node("prod-1", "Product One", false),
            %BinaryNode{
              tag: "paging",
              attrs: %{},
              content: [%BinaryNode{tag: "after", attrs: %{}, content: "cursor-2"}]
            }
          ]
        }
      ]
    }
  end

  defp collections_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "collections",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "collection",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: "collection-1"},
                %BinaryNode{tag: "name", attrs: %{}, content: "Featured"},
                %BinaryNode{
                  tag: "status_info",
                  attrs: %{},
                  content: [
                    %BinaryNode{tag: "status", attrs: %{}, content: "APPROVED"},
                    %BinaryNode{tag: "can_appeal", attrs: %{}, content: "false"}
                  ]
                },
                product_node("prod-1", "Product One", false)
              ]
            }
          ]
        }
      ]
    }
  end

  defp product_catalog_add_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "product_catalog_add",
          attrs: %{},
          content: [product_node("prod-1", "Product One", false)]
        }
      ]
    }
  end

  defp product_catalog_edit_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "product_catalog_edit",
          attrs: %{},
          content: [product_node("prod-1", "Product One Updated", true)]
        }
      ]
    }
  end

  defp order_details_result_node do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "order",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "price",
              attrs: %{},
              content: [
                %BinaryNode{tag: "total", attrs: %{}, content: "5000"},
                %BinaryNode{tag: "currency", attrs: %{}, content: "USD"}
              ]
            },
            %BinaryNode{
              tag: "product",
              attrs: %{},
              content: [
                %BinaryNode{tag: "id", attrs: %{}, content: "prod-1"},
                %BinaryNode{tag: "name", attrs: %{}, content: "Product One"},
                %BinaryNode{
                  tag: "image",
                  attrs: %{},
                  content: [
                    %BinaryNode{
                      tag: "url",
                      attrs: %{},
                      content: "https://mmg.whatsapp.net/product-1"
                    }
                  ]
                },
                %BinaryNode{tag: "price", attrs: %{}, content: "5000"},
                %BinaryNode{tag: "currency", attrs: %{}, content: "USD"},
                %BinaryNode{tag: "quantity", attrs: %{}, content: "2"}
              ]
            }
          ]
        }
      ]
    }
  end

  defp product_node(id, name, hidden?) do
    attrs = if hidden?, do: %{"is_hidden" => "true"}, else: %{}

    %BinaryNode{
      tag: "product",
      attrs: attrs,
      content: [
        %BinaryNode{tag: "id", attrs: %{}, content: id},
        %BinaryNode{tag: "name", attrs: %{}, content: name},
        %BinaryNode{tag: "retailer_id", attrs: %{}, content: "SKU-1"},
        %BinaryNode{tag: "description", attrs: %{}, content: "Body"},
        %BinaryNode{tag: "price", attrs: %{}, content: "5000"},
        %BinaryNode{tag: "currency", attrs: %{}, content: "USD"},
        %BinaryNode{tag: "url", attrs: %{}, content: "https://example.com/product"},
        %BinaryNode{
          tag: "media",
          attrs: %{},
          content: [
            %BinaryNode{
              tag: "image",
              attrs: %{},
              content: [
                %BinaryNode{
                  tag: "request_image_url",
                  attrs: %{},
                  content: "https://mmg.whatsapp.net/product-1"
                },
                %BinaryNode{
                  tag: "original_image_url",
                  attrs: %{},
                  content: "https://mmg.whatsapp.net/product-1"
                }
              ]
            }
          ]
        },
        %BinaryNode{
          tag: "status_info",
          attrs: %{},
          content: [
            %BinaryNode{tag: "status", attrs: %{}, content: "APPROVED"},
            %BinaryNode{tag: "can_appeal", attrs: %{}, content: "false"}
          ]
        }
      ]
    }
  end
end
