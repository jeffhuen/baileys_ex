defmodule BaileysEx.Signal.StoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.Store

  setup do
    {:ok, store} = Store.start_link()
    %{store: store}
  end

  test "stores and deletes values across logical key families", %{store: store} do
    assert :ok =
             Store.set(store, %{
               :session => %{"alice.0" => <<1, 2, 3>>},
               :"identity-key" => %{"alice.0" => <<4, 5, 6>>},
               :"device-list" => %{"alice" => ["0", "2"]}
             })

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :session, ["alice.0", "missing"])
    assert %{"alice.0" => <<4, 5, 6>>} = Store.get(store, :"identity-key", ["alice.0"])
    assert %{"alice" => ["0", "2"]} = Store.get(store, :"device-list", ["alice"])

    assert :ok = Store.set(store, %{session: %{"alice.0" => nil}})
    assert Store.get(store, :session, ["alice.0"]) == %{}
  end

  test "keeps writes local until transaction commit", %{store: store} do
    parent = self()

    task =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          refute Store.in_transaction?(store)
          assert Store.in_transaction?(tx_store)
          assert :ok = Store.set(tx_store, %{:session => %{"alice.0" => <<7, 8, 9>>}})
          send(parent, :written_in_transaction)
          Process.sleep(50)
          assert %{"alice.0" => <<7, 8, 9>>} = Store.get(tx_store, :session, ["alice.0"])
          assert Store.get(store, :session, ["alice.0"]) == %{}
          :committed
        end)
      end)

    assert_receive :written_in_transaction
    assert Store.get(store, :session, ["alice.0"]) == %{}
    assert :committed = Task.await(task)
    assert %{"alice.0" => <<7, 8, 9>>} = Store.get(store, :session, ["alice.0"])
  end

  test "reuses nested transaction context", %{store: store} do
    assert :nested =
             Store.transaction(store, "session:alice", fn tx_store ->
               assert :ok = Store.set(tx_store, %{:session => %{"alice.0" => <<1>>}})

               Store.transaction(tx_store, "session:bob", fn nested_store ->
                 assert tx_store == nested_store
                 assert Store.in_transaction?(nested_store)
                 refute Store.in_transaction?(store)
                 assert %{"alice.0" => <<1>>} = Store.get(nested_store, :session, ["alice.0"])
                 :nested
               end)
             end)

    assert %{"alice.0" => <<1>>} = Store.get(store, :session, ["alice.0"])
  end

  test "serializes concurrent transactions for the same key", %{store: store} do
    parent = self()

    first =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          send(parent, :first_transaction_entered)
          Process.sleep(75)
          assert :ok = Store.set(tx_store, %{:session => %{"alice.0" => <<1, 2, 3>>}})
          send(parent, :first_transaction_ready_to_commit)
          :first
        end)
      end)

    assert_receive :first_transaction_entered

    second =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          send(parent, {:second_transaction_loaded, Store.get(tx_store, :session, ["alice.0"])})
          :second
        end)
      end)

    refute_receive {:second_transaction_loaded, _}, 20

    assert_receive :first_transaction_ready_to_commit
    assert :first = Task.await(first)
    assert_receive {:second_transaction_loaded, %{"alice.0" => <<1, 2, 3>>}}
    assert :second = Task.await(second)
  end

  test "releases the lock when a transaction owner dies", %{store: store} do
    parent = self()

    owner =
      spawn(fn ->
        Store.transaction(store, "session:alice", fn _tx_store ->
          send(parent, :owner_entered)
          Process.sleep(:infinity)
        end)
      end)

    owner_ref = Process.monitor(owner)

    assert_receive :owner_entered

    waiter =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          assert :ok = Store.set(tx_store, %{session: %{"alice.0" => <<4, 5, 6>>}})
          send(parent, {:waiter_entered, Store.get(tx_store, :session, ["alice.0"])})
          :waiter_committed
        end)
      end)

    refute_receive {:waiter_entered, _}, 20

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    assert_receive {:waiter_entered, %{"alice.0" => <<4, 5, 6>>}}
    assert :waiter_committed = Task.await(waiter)
    assert %{"alice.0" => <<4, 5, 6>>} = Store.get(store, :session, ["alice.0"])
  end
end
