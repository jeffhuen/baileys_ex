defmodule BaileysEx.Auth.KeyStoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Signal.Store

  @async_timeout 5_000

  defmodule TrackingPersistence do
    @behaviour BaileysEx.Auth.Persistence

    def start_link(initial_data \\ %{}) do
      Agent.start_link(fn ->
        %{
          data: initial_data,
          loads: %{},
          saves: %{},
          deletes: %{},
          fail_once: MapSet.new(),
          failed: MapSet.new(),
          failure_observers: %{},
          gates: %{}
        }
      end)
    end

    def load_credentials, do: {:error, :unsupported}
    def save_credentials(_state), do: :ok
    def load_keys(_type, _id), do: {:error, :missing_context}
    def save_keys(_type, _id, _data), do: {:error, :missing_context}
    def delete_keys(_type, _id), do: {:error, :missing_context}

    def load_keys(agent, type, id) do
      Agent.get_and_update(agent, fn state ->
        loads = Map.update(state.loads, {type, id}, 1, &(&1 + 1))

        result =
          case state.data |> Map.get(type, %{}) |> Map.fetch(id) do
            {:ok, value} -> {:ok, value}
            :error -> {:error, :not_found}
          end

        {result, %{state | loads: loads}}
      end)
    end

    def save_keys(agent, type, id, data) do
      operation = {:save, type, id}
      maybe_wait_for_gate(agent, operation)

      Agent.get_and_update(agent, fn state ->
        if MapSet.member?(state.fail_once, operation) and
             not MapSet.member?(state.failed, operation) do
          notify_failure(state, operation)

          {{:error, :forced_failure}, %{state | failed: MapSet.put(state.failed, operation)}}
        else
          saves = Map.update(state.saves, {type, id}, 1, &(&1 + 1))
          data_by_type = Map.update(state.data, type, %{id => data}, &Map.put(&1, id, data))
          {:ok, %{state | saves: saves, data: data_by_type}}
        end
      end)
    end

    def delete_keys(agent, type, id) do
      operation = {:delete, type, id}
      maybe_wait_for_gate(agent, operation)

      Agent.get_and_update(agent, fn state ->
        if MapSet.member?(state.fail_once, operation) and
             not MapSet.member?(state.failed, operation) do
          notify_failure(state, operation)

          {{:error, :forced_failure}, %{state | failed: MapSet.put(state.failed, operation)}}
        else
          deletes = Map.update(state.deletes, {type, id}, 1, &(&1 + 1))
          data_by_type = Map.update(state.data, type, %{}, &Map.delete(&1, id))
          {:ok, %{state | deletes: deletes, data: data_by_type}}
        end
      end)
    end

    def load_count(agent, type, id) do
      Agent.get(agent, fn state -> Map.get(state.loads, {type, id}, 0) end)
    end

    def delete_count(agent, type, id) do
      Agent.get(agent, fn state -> Map.get(state.deletes, {type, id}, 0) end)
    end

    def put_fail_once(agent, operation, observer \\ nil) do
      Agent.update(agent, fn state ->
        %{
          state
          | fail_once: MapSet.put(state.fail_once, operation),
            failure_observers: Map.put(state.failure_observers, operation, observer)
        }
      end)
    end

    def gate_once(agent, operation, observer, gate) do
      Agent.update(agent, fn state ->
        %{state | gates: Map.put(state.gates, operation, {observer, gate})}
      end)
    end

    defp maybe_wait_for_gate(agent, operation) do
      case Agent.get_and_update(agent, fn state ->
             {Map.get(state.gates, operation),
              %{state | gates: Map.delete(state.gates, operation)}}
           end) do
        {observer, gate} ->
          send(observer, {:persistence_blocked, operation, self()})

          receive do
            {:continue_persistence, ^gate} -> :ok
          end

        nil ->
          :ok
      end
    end

    defp notify_failure(state, operation) do
      case Map.get(state.failure_observers, operation) do
        observer when is_pid(observer) -> send(observer, {:persistence_failed, operation})
        _other -> :ok
      end
    end
  end

  @tag :tmp_dir
  test "persists supported signal datasets across store restarts for built-in persistence backends",
       %{tmp_dir: tmp_dir} do
    Enum.each(
      [
        {FilePersistence, Path.join(tmp_dir, "compat")},
        {NativeFilePersistence, Path.join(tmp_dir, "native")}
      ],
      fn {persistence_module, persistence_context} ->
        assert_store_restart_roundtrip(persistence_module, persistence_context)
      end
    )
  end

  test "uses transaction cache and ETS read-through caching to avoid redundant persistence loads" do
    {:ok, persistence} = TrackingPersistence.start_link(%{session: %{"alice.0" => <<1, 2, 3>>}})

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence
      )

    assert :ok =
             Store.transaction(store, "session:alice", fn tx_store ->
               refute Store.in_transaction?(store)
               assert Store.in_transaction?(tx_store)
               assert %{"alice.0" => <<1, 2, 3>>} = Store.get(tx_store, :session, ["alice.0"])
               assert %{"alice.0" => <<1, 2, 3>>} = Store.get(tx_store, :session, ["alice.0"])
               assert Store.get(tx_store, :session, ["missing.0"]) == %{}
               assert Store.get(tx_store, :session, ["missing.0"]) == %{}
               :ok
             end)

    assert 1 == TrackingPersistence.load_count(persistence, :session, "alice.0")
    assert 1 == TrackingPersistence.load_count(persistence, :session, "missing.0")

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :session, ["alice.0"])
    assert Store.get(store, :session, ["missing.0"]) == %{}

    assert 1 == TrackingPersistence.load_count(persistence, :session, "alice.0")
    assert 1 == TrackingPersistence.load_count(persistence, :session, "missing.0")
  end

  test "serializes concurrent transactions for the same key" do
    {:ok, persistence} = TrackingPersistence.start_link()

    {:ok, store} =
      start_store(persistence_module: TrackingPersistence, persistence_context: persistence)

    parent = self()

    first =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          send(parent, :first_entered)
          assert_receive :finish_first_transaction, @async_timeout
          assert :ok = Store.set(tx_store, %{session: %{"alice.0" => <<1, 2, 3>>}})
          :first
        end)
      end)

    assert_receive :first_entered, @async_timeout

    second =
      Task.async(fn ->
        send(parent, :second_transaction_attempting)

        Store.transaction(store, "session:alice", fn tx_store ->
          send(parent, {:second_loaded, Store.get(tx_store, :session, ["alice.0"])})
          :second
        end)
      end)

    assert_receive :second_transaction_attempting, @async_timeout
    refute_receive {:second_loaded, _}, 20

    send(first.pid, :finish_first_transaction)
    assert :first = Task.await(first)

    assert_receive {:second_loaded, %{"alice.0" => <<1, 2, 3>>}}, @async_timeout
    assert :second = Task.await(second)
  end

  test "releases the lock when a transaction owner dies" do
    {:ok, persistence} = TrackingPersistence.start_link()

    {:ok, store} =
      start_store(persistence_module: TrackingPersistence, persistence_context: persistence)

    parent = self()

    owner =
      spawn(fn ->
        Store.transaction(store, "session:alice", fn _tx_store ->
          send(parent, :owner_entered)
          assert_receive :release_owner, @async_timeout
        end)
      end)

    owner_ref = Process.monitor(owner)

    assert_receive :owner_entered, @async_timeout

    waiter =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          assert :ok = Store.set(tx_store, %{session: %{"alice.0" => <<9, 9, 9>>}})
          send(parent, {:waiter_entered, Store.get(tx_store, :session, ["alice.0"])})
          :waiter_committed
        end)
      end)

    refute_receive {:waiter_entered, _}, 20

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}, @async_timeout
    assert_receive {:waiter_entered, %{"alice.0" => <<9, 9, 9>>}}, @async_timeout
    assert :waiter_committed = Task.await(waiter)
    assert %{"alice.0" => <<9, 9, 9>>} = Store.get(store, :session, ["alice.0"])
  end

  test "rolls back failed transaction commits to the previous persisted snapshot" do
    {:ok, persistence} =
      TrackingPersistence.start_link(%{
        session: %{"alice.0" => <<0>>}
      })

    TrackingPersistence.put_fail_once(persistence, {:save, :"device-list", "alice"})

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence,
        max_commit_retries: 1,
        delay_between_tries_ms: 1
      )

    assert_raise KeyStore.OperationError, fn ->
      Store.transaction(store, "session:alice", fn tx_store ->
        assert :ok =
                 Store.set(tx_store, %{
                   :"device-list" => %{"alice" => ["0", "2"]},
                   session: %{"alice.0" => <<1, 2, 3>>}
                 })
      end)
    end

    assert %{"alice.0" => <<0>>} = Store.get(store, :session, ["alice.0"])
    assert Store.get(store, :"device-list", ["alice"]) == %{}
  end

  test "does not retry a commit after its persistence rollback fails" do
    {:ok, persistence} = TrackingPersistence.start_link()

    TrackingPersistence.put_fail_once(persistence, {:save, :session, "bob.0"})
    TrackingPersistence.put_fail_once(persistence, {:delete, :session, "alice.0"})

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence,
        max_commit_retries: 2,
        retry_timer_fun: manual_retry_clock(self())
      )

    error =
      assert_raise KeyStore.OperationError, fn ->
        Store.set(store, %{session: %{"alice.0" => <<1>>, "bob.0" => <<2>>}})
      end

    assert error.reason == {:rollback_failed, :forced_failure, :forced_failure}
    refute_received {:retry_scheduled, _target, _message}
  end

  test "commit retry backoff does not block unrelated transaction locks" do
    {:ok, persistence} = TrackingPersistence.start_link()
    operation = {:save, :session, "alice.0"}
    TrackingPersistence.put_fail_once(persistence, operation, self())

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence,
        max_commit_retries: 2,
        retry_timer_fun: manual_retry_clock(self())
      )

    setter = Task.async(fn -> Store.set(store, %{session: %{"alice.0" => <<1>>}}) end)
    assert_receive {:persistence_failed, ^operation}
    assert_receive {:retry_scheduled, retry_target, retry_message}

    parent = self()

    transaction =
      Task.async(fn ->
        Store.transaction(store, "session:bob", fn _tx_store ->
          send(parent, :unrelated_lock_acquired)
          :ok
        end)
      end)

    assert_receive :unrelated_lock_acquired
    send(retry_target, retry_message)
    assert :ok = Task.await(setter)
    assert :ok = Task.await(transaction)
  end

  test "commit queue rejects excess writes during retry backoff" do
    {:ok, persistence} = TrackingPersistence.start_link()
    operation = {:save, :session, "alice.0"}
    TrackingPersistence.put_fail_once(persistence, operation, self())

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence,
        max_commit_retries: 2,
        max_commit_queue: 1,
        retry_timer_fun: manual_retry_clock(self())
      )

    setter = Task.async(fn -> Store.set(store, %{session: %{"alice.0" => <<1>>}}) end)
    assert_receive {:persistence_failed, ^operation}
    assert_receive {:retry_scheduled, retry_target, retry_message}

    error =
      assert_raise KeyStore.OperationError, fn ->
        Store.set(store, %{session: %{"bob.0" => <<2>>}})
      end

    assert error.reason == :commit_queue_full

    send(retry_target, retry_message)
    assert :ok = Task.await(setter)
  end

  test "slow persistence I/O does not block unrelated transaction locks" do
    {:ok, persistence} = TrackingPersistence.start_link()
    operation = {:save, :session, "alice.0"}
    gate = make_ref()
    TrackingPersistence.gate_once(persistence, operation, self(), gate)

    {:ok, store} =
      start_store(persistence_module: TrackingPersistence, persistence_context: persistence)

    setter = Task.async(fn -> Store.set(store, %{session: %{"alice.0" => <<1>>}}) end)
    assert_receive {:persistence_blocked, ^operation, persistence_task}

    parent = self()

    transaction =
      Task.async(fn ->
        Store.transaction(store, "session:bob", fn _tx_store ->
          send(parent, :lock_acquired_during_slow_io)
          :ok
        end)
      end)

    assert_receive :lock_acquired_during_slow_io
    send(persistence_task, {:continue_persistence, gate})
    assert :ok = Task.await(setter)
    assert :ok = Task.await(transaction)
  end

  test "dead transaction owner retains its lock until an active retry commits" do
    {:ok, persistence} = TrackingPersistence.start_link()
    operation = {:save, :session, "alice.0"}
    TrackingPersistence.put_fail_once(persistence, operation, self())

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence,
        max_commit_retries: 2,
        retry_timer_fun: manual_retry_clock(self())
      )

    parent = self()

    owner =
      spawn(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          Store.set(tx_store, %{session: %{"alice.0" => <<1>>}})
          send(parent, :owner_ready_to_commit)
          :owner_committed
        end)
      end)

    owner_ref = Process.monitor(owner)
    assert_receive :owner_ready_to_commit
    assert_receive {:persistence_failed, ^operation}
    assert_receive {:retry_scheduled, retry_target, retry_message}

    waiter =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn tx_store ->
          send(parent, {:waiter_entered_after_retry, Store.get(tx_store, :session, ["alice.0"])})
          :waiter_committed
        end)
      end)

    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^owner_ref, :process, ^owner, :killed}
    refute_received {:waiter_entered_after_retry, _value}

    send(retry_target, retry_message)
    assert_receive {:waiter_entered_after_retry, %{"alice.0" => <<1>>}}
    assert :waiter_committed = Task.await(waiter)
  end

  test "applies Baileys-style pre-key deletion safeguards" do
    {:ok, persistence} =
      TrackingPersistence.start_link(%{
        :"pre-key" => %{
          "1" => %{public: <<1>>, private: <<2>>},
          "2" => %{public: <<3>>, private: <<4>>}
        }
      })

    {:ok, store} =
      start_store(
        persistence_module: TrackingPersistence,
        persistence_context: persistence
      )

    assert :ok = Store.set(store, %{:"pre-key" => %{"missing" => nil, "1" => nil}})

    assert Store.get(store, :"pre-key", ["1", "missing"]) == %{}
    assert 0 == TrackingPersistence.delete_count(persistence, :"pre-key", "missing")
    assert 1 == TrackingPersistence.delete_count(persistence, :"pre-key", "1")

    assert :ok =
             Store.transaction(store, "pre-key", fn tx_store ->
               assert %{"2" => %{public: <<3>>, private: <<4>>}} =
                        Store.get(tx_store, :"pre-key", ["2"])

               assert :ok = Store.set(tx_store, %{:"pre-key" => %{"2" => nil, "3" => nil}})
             end)

    assert Store.get(store, :"pre-key", ["2", "3"]) == %{}
    assert 1 == TrackingPersistence.delete_count(persistence, :"pre-key", "2")
    assert 0 == TrackingPersistence.delete_count(persistence, :"pre-key", "3")
  end

  @tag :tmp_dir
  test "uses native persistence behavior when no persistence module is configured", %{
    tmp_dir: tmp_dir
  } do
    assert {:ok, store} =
             Store.new(module: KeyStore, persistence_context: tmp_dir, max_commit_retries: 1)

    assert :ok = Store.set(store, %{session: %{"alice.0" => <<1, 2, 3>>}})
    assert :ok = GenServer.stop(store.ref.pid)

    assert {:ok, reloaded} =
             Store.new(module: KeyStore, persistence_context: tmp_dir, max_commit_retries: 1)

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(reloaded, :session, ["alice.0"])
  end

  defp start_store(opts) do
    Store.new(
      Keyword.merge(
        [
          module: KeyStore,
          max_commit_retries: 2,
          delay_between_tries_ms: 5
        ],
        opts
      )
    )
  end

  defp manual_retry_clock(test_pid) do
    fn target, message, _delay_ms ->
      send(test_pid, {:retry_scheduled, target, message})
      make_ref()
    end
  end

  defp assert_store_restart_roundtrip(persistence_module, persistence_context) do
    {:ok, store} =
      start_store(
        persistence_module: persistence_module,
        persistence_context: persistence_context
      )

    assert :ok =
             Store.set(store, %{
               :"lid-mapping" => %{
                 "5511999887766" => "12345",
                 "12345_reverse" => "5511999887766"
               },
               :"device-list" => %{"5511999887766" => ["0", "2"]},
               :"identity-key" => %{"alice.0" => <<1, 2, 3>>},
               :"sender-key-memory" => %{"1203630@g.us" => %{"alice:0" => true}},
               :tctoken => %{
                 "15551234567@s.whatsapp.net" => %{token: <<9, 8, 7>>, timestamp: "1710000000"}
               }
             })

    assert %{"5511999887766" => "12345", "12345_reverse" => "5511999887766"} =
             Store.get(store, :"lid-mapping", ["5511999887766", "12345_reverse"])

    assert %{"5511999887766" => ["0", "2"]} =
             Store.get(store, :"device-list", ["5511999887766"])

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :"identity-key", ["alice.0"])

    assert %{"1203630@g.us" => %{"alice:0" => true}} =
             Store.get(store, :"sender-key-memory", ["1203630@g.us"])

    assert %{
             "15551234567@s.whatsapp.net" => %{token: <<9, 8, 7>>, timestamp: "1710000000"}
           } = Store.get(store, :tctoken, ["15551234567@s.whatsapp.net"])

    assert :ok = GenServer.stop(store.ref.pid)

    {:ok, reloaded} =
      start_store(
        persistence_module: persistence_module,
        persistence_context: persistence_context
      )

    assert %{"5511999887766" => "12345"} =
             Store.get(reloaded, :"lid-mapping", ["5511999887766"])

    assert %{"5511999887766" => ["0", "2"]} =
             Store.get(reloaded, :"device-list", ["5511999887766"])

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(reloaded, :"identity-key", ["alice.0"])

    assert :ok = GenServer.stop(reloaded.ref.pid)
  end
end
