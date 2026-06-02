defmodule BaileysEx.Feature.AccountTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Connection.EventEmitter
  alias BaileysEx.Feature.Account

  @reachout_timelock_query_id "23983697327930364"
  @message_capping_info_query_id "24503548349331633"

  test "fetch_account_reachout_timelock builds the rc13 WMex query and emits connection update" do
    parent = self()
    {:ok, emitter} = EventEmitter.start_link()
    _unsubscribe = EventEmitter.process(emitter, fn events -> send(parent, {:events, events}) end)

    query_fun = wmex_query_fun(parent)

    assert {:ok,
            %{
              is_active: true,
              time_enforcement_ends: ~U[2024-03-09 16:00:00Z],
              enforcement_type: "BIZ_QUALITY"
            }} =
             Account.fetch_account_reachout_timelock(query_fun,
               event_emitter: emitter,
               message_tag_fun: fn -> "account-tag-1" end
             )

    assert_receive {:wmex_query, @reachout_timelock_query_id, %{}, "account-tag-1"}

    assert_receive {:events,
                    %{
                      connection_update: %{
                        reachout_time_lock: %{
                          is_active: true,
                          time_enforcement_ends: ~U[2024-03-09 16:00:00Z],
                          enforcement_type: "BIZ_QUALITY"
                        }
                      }
                    }}
  end

  test "fetch_account_reachout_timelock normalizes inactive and missing fields like Baileys" do
    query_fun = wmex_query_fun(self(), reachout_payload: %{"is_active" => false})

    assert {:ok, %{is_active: false, enforcement_type: "DEFAULT"}} =
             Account.fetch_account_reachout_timelock(query_fun,
               message_tag_fun: fn -> "account-tag-2" end
             )

    refute_receive {:events, _events}
    assert_receive {:wmex_query, @reachout_timelock_query_id, %{}, "account-tag-2"}
  end

  test "fetch_new_chat_message_cap builds the rc13 WMex query and returns the cap payload" do
    query_fun = wmex_query_fun(self())

    assert {:ok,
            %{
              "total_quota" => 25,
              "used_quota" => 7,
              "cycle_start_timestamp" => "1710000000",
              "cycle_end_timestamp" => "1710600000",
              "server_sent_timestamp" => "1710000100",
              "ote_status" => "ACTIVE_IN_CURRENT_CYCLE",
              "mv_status" => "ACTIVE",
              "capping_status" => "FIRST_WARNING"
            }} =
             Account.fetch_new_chat_message_cap(query_fun,
               message_tag_fun: fn -> "account-tag-3" end
             )

    assert_receive {:wmex_query, @message_capping_info_query_id,
                    %{"input" => %{"type" => "INDIVIDUAL_NEW_CHAT_MSG"}}, "account-tag-3"}
  end

  defp wmex_query_fun(parent, opts \\ []) do
    fn node, timeout ->
      send(parent, {:query, node, timeout})

      assert %BinaryNode{
               tag: "iq",
               attrs: %{"xmlns" => "w:mex", "type" => "get"},
               content: [
                 %BinaryNode{
                   tag: "query",
                   attrs: %{"query_id" => query_id},
                   content: {:binary, payload}
                 }
               ]
             } = node

      variables = JSON.decode!(payload)["variables"]
      send(parent, {:wmex_query, query_id, variables, node.attrs["id"]})

      {:ok, wmex_response(query_id, opts)}
    end
  end

  defp wmex_response(@reachout_timelock_query_id, opts) do
    payload =
      Keyword.get(opts, :reachout_payload, %{
        "is_active" => true,
        "time_enforcement_ends" => "1710000000",
        "enforcement_type" => "BIZ_QUALITY"
      })

    wmex_result("xwa2_fetch_account_reachout_timelock", payload)
  end

  defp wmex_response(@message_capping_info_query_id, _opts) do
    wmex_result("xwa2_message_capping_info", %{
      "total_quota" => 25,
      "used_quota" => 7,
      "cycle_start_timestamp" => "1710000000",
      "cycle_end_timestamp" => "1710600000",
      "server_sent_timestamp" => "1710000100",
      "ote_status" => "ACTIVE_IN_CURRENT_CYCLE",
      "mv_status" => "ACTIVE",
      "capping_status" => "FIRST_WARNING"
    })
  end

  defp wmex_result(data_path, payload) do
    %BinaryNode{
      tag: "iq",
      attrs: %{"type" => "result"},
      content: [
        %BinaryNode{
          tag: "result",
          attrs: %{},
          content: {:binary, JSON.encode!(%{"data" => %{data_path => payload}})}
        }
      ]
    }
  end
end
