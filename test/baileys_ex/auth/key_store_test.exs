defmodule BaileysEx.Auth.KeyStoreTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Auth.FilePersistence
  alias BaileysEx.Auth.KeyStore
  alias BaileysEx.Auth.NativeFilePersistence
  alias BaileysEx.Signal.Store

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
          failed: MapSet.new()
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
      Agent.get_and_update(agent, fn state ->
        key = {:save, type, id}

        if MapSet.member?(state.fail_once, key) and not MapSet.member?(state.failed, key) do
          {{:error, :forced_failure}, %{state | failed: MapSet.put(state.failed, key)}}
        else
          saves = Map.update(state.saves, {type, id}, 1, &(&1 + 1))
          data_by_type = Map.update(state.data, type, %{id => data}, &Map.put(&1, id, data))
          {:ok, %{state | saves: saves, data: data_by_type}}
        end
      end)
    end

    def delete_keys(agent, type, id) do
      Agent.get_and_update(agent, fn state ->
        key = {:delete, type, id}

        if MapSet.member?(state.fail_once, key) and not MapSet.member?(state.failed, key) do
          {{:error, :forced_failure}, %{state | failed: MapSet.put(state.failed, key)}}
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

    def put_fail_once(agent, operation) do
      Agent.update(agent, fn state ->
        %{state | fail_once: MapSet.put(state.fail_once, operation)}
      end)
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
             Store.transaction(store, "session:alice", fn ->
               assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :session, ["alice.0"])
               assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :session, ["alice.0"])
               assert %{} = Store.get(store, :session, ["missing.0"])
               assert %{} = Store.get(store, :session, ["missing.0"])
               :ok
             end)

    assert 1 == TrackingPersistence.load_count(persistence, :session, "alice.0")
    assert 1 == TrackingPersistence.load_count(persistence, :session, "missing.0")

    assert %{"alice.0" => <<1, 2, 3>>} = Store.get(store, :session, ["alice.0"])
    assert %{} = Store.get(store, :session, ["missing.0"])

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
        Store.transaction(store, "session:alice", fn ->
          send(parent, :first_entered)
          Process.sleep(75)
          assert :ok = Store.set(store, %{session: %{"alice.0" => <<1, 2, 3>>}})
          send(parent, :first_ready_to_commit)
          :first
        end)
      end)

    assert_receive :first_entered

    second =
      Task.async(fn ->
        Store.transaction(store, "session:alice", fn ->
          send(parent, {:second_loaded, Store.get(store, :session, ["alice.0"])})
          :second
        end)
      end)

    refute_receive {:second_loaded, _}, 20

    assert_receive :first_ready_to_commit, 250
    assert :first = Task.await(first)
    assert_receive {:second_loaded, %{"alice.0" => <<1, 2, 3>>}}
    assert :second = Task.await(second)
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
      Store.transaction(store, "session:alice", fn ->
        assert :ok =
                 Store.set(store, %{
                   :"device-list" => %{"alice" => ["0", "2"]},
                   session: %{"alice.0" => <<1, 2, 3>>}
                 })
      end)
    end

    assert %{"alice.0" => <<0>>} = Store.get(store, :session, ["alice.0"])
    assert %{} = Store.get(store, :"device-list", ["alice"])
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

    assert %{} = Store.get(store, :"pre-key", ["1", "missing"])
    assert 0 == TrackingPersistence.delete_count(persistence, :"pre-key", "missing")
    assert 1 == TrackingPersistence.delete_count(persistence, :"pre-key", "1")

    assert :ok =
             Store.transaction(store, "pre-key", fn ->
               assert %{"2" => %{public: <<3>>, private: <<4>>}} =
                        Store.get(store, :"pre-key", ["2"])

               assert :ok = Store.set(store, %{:"pre-key" => %{"2" => nil, "3" => nil}})
             end)

    assert %{} = Store.get(store, :"pre-key", ["2", "3"])
    assert 1 == TrackingPersistence.delete_count(persistence, :"pre-key", "2")
    assert 0 == TrackingPersistence.delete_count(persistence, :"pre-key", "3")
  end

  defp start_store(opts) do
    Store.start_link(
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
