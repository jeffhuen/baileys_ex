defmodule BaileysEx.Connection.StoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Connection.Store

  test "wrap exposes seeded auth state and creds through ETS reads" do
    assert {:ok, store} =
             Store.start_link(
               auth_state: %{
                 creds: %{
                   me: %{id: "15551234567@s.whatsapp.net"},
                   routing_info: <<1, 2, 3>>
                 }
               }
             )

    ref = Store.wrap(store)

    assert %{creds: %{routing_info: <<1, 2, 3>>}} = Store.get(ref, :auth_state)

    assert Store.get(ref, :creds) == %{
             me: %{id: "15551234567@s.whatsapp.net"},
             routing_info: <<1, 2, 3>>
           }
  end

  test "put and merge_creds update the shared ETS view" do
    assert {:ok, store} =
             Store.start_link(
               auth_state: %{
                 creds: %{
                   me: %{id: "15551234567@s.whatsapp.net"}
                 }
               }
             )

    ref = Store.wrap(store)

    assert :ok = Store.put(store, :last_account_sync_timestamp, 1_710_000_000)

    assert :ok =
             Store.merge_creds(store, %{
               routing_info: <<4, 5, 6>>,
               me: %{lid: "12345678901234@lid"}
             })

    assert Store.get(ref, :last_account_sync_timestamp) == 1_710_000_000

    assert Store.get(ref, :creds) == %{
             me: %{id: "15551234567@s.whatsapp.net", lid: "12345678901234@lid"},
             routing_info: <<4, 5, 6>>
           }
  end

  test "reads bypass the GenServer and still work while the owner is suspended" do
    assert {:ok, store} =
             Store.start_link(
               auth_state: %{
                 creds: %{
                   me: %{id: "15551234567@s.whatsapp.net"}
                 }
               }
             )

    ref = Store.wrap(store)
    :sys.suspend(store)

    try do
      task = Task.async(fn -> Store.get(ref, :creds) end)

      assert Task.await(task, 100) == %{
               me: %{id: "15551234567@s.whatsapp.net"}
             }
    after
      :sys.resume(store)
    end
  end
end
