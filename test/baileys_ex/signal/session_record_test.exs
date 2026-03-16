defmodule BaileysEx.Signal.SessionRecordTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Signal.SessionRecord

  defp make_session(base_key_type \\ :sending, closed \\ nil) do
    %{
      current_ratchet: %{
        root_key: :binary.copy(<<0xAA>>, 32),
        ephemeral_key_pair: %{
          public: :binary.copy(<<0x01>>, 32),
          private: :binary.copy(<<0x02>>, 32)
        },
        last_remote_ephemeral: :binary.copy(<<0x03>>, 32),
        previous_counter: 0
      },
      index_info: %{
        remote_identity_key: <<5>> <> :binary.copy(<<0x04>>, 32),
        local_identity_key: <<5>> <> :binary.copy(<<0x05>>, 32),
        base_key: <<5>> <> :binary.copy(<<0x06>>, 32),
        base_key_type: base_key_type,
        closed: closed
      },
      chains: %{},
      pending_pre_key: nil,
      registration_id: 42
    }
  end

  test "new record is empty with no open session" do
    record = SessionRecord.new()
    assert SessionRecord.empty?(record)
    refute SessionRecord.have_open_session?(record)
    assert SessionRecord.get_open_session(record) == nil
  end

  test "put_session adds a session" do
    record = SessionRecord.new()
    session = make_session()
    base_key = session.index_info.base_key

    record = SessionRecord.put_session(record, base_key, session)

    refute SessionRecord.empty?(record)
    assert SessionRecord.have_open_session?(record)
    assert {^base_key, ^session} = SessionRecord.get_open_session(record)
  end

  test "get_session retrieves by base_key" do
    record = SessionRecord.new()
    session = make_session()
    base_key = session.index_info.base_key

    record = SessionRecord.put_session(record, base_key, session)

    assert SessionRecord.get_session(record, base_key) == session
    assert SessionRecord.get_session(record, "nonexistent") == nil
  end

  test "close_session marks session as closed" do
    record = SessionRecord.new()
    session = make_session()
    base_key = session.index_info.base_key

    record = SessionRecord.put_session(record, base_key, session)
    assert SessionRecord.have_open_session?(record)

    record = SessionRecord.close_session(record, base_key)
    refute SessionRecord.have_open_session?(record)
    refute SessionRecord.empty?(record)
  end

  test "close_open_session closes the current open session" do
    record = SessionRecord.new()
    session = make_session()
    base_key = session.index_info.base_key

    record = SessionRecord.put_session(record, base_key, session)
    record = SessionRecord.close_open_session(record)

    refute SessionRecord.have_open_session?(record)
  end

  test "close_open_session is a no-op when no open session" do
    record = SessionRecord.new()
    assert SessionRecord.close_open_session(record) == record
  end

  test "close_session with nonexistent key is a no-op" do
    record = SessionRecord.new()
    assert SessionRecord.close_session(record, "nonexistent") == record
  end

  test "trimming respects max 40 closed sessions" do
    record = SessionRecord.new()

    # Add 45 closed sessions
    record =
      Enum.reduce(1..45, record, fn i, acc ->
        session = make_session(:sending, -i)
        base_key = <<5>> <> <<i::unsigned-big-256>>
        session = put_in(session.index_info.base_key, base_key)
        SessionRecord.put_session(acc, base_key, session)
      end)

    # Add one open session
    open_session = make_session()
    open_key = <<5>> <> :binary.copy(<<0xFF>>, 32)
    open_session = put_in(open_session.index_info.base_key, open_key)
    record = SessionRecord.put_session(record, open_key, open_session)

    # Closing the open session should trigger trim
    record = SessionRecord.close_session(record, open_key)

    # Should have at most 41 sessions (40 closed + the one we just closed)
    assert map_size(record.sessions) <= 41
  end

  test "multiple sessions — only one open at a time after close_open_session" do
    record = SessionRecord.new()

    session1 = make_session()
    key1 = <<5>> <> :binary.copy(<<0x10>>, 32)
    session1 = put_in(session1.index_info.base_key, key1)
    record = SessionRecord.put_session(record, key1, session1)

    record = SessionRecord.close_open_session(record)

    session2 = make_session()
    key2 = <<5>> <> :binary.copy(<<0x20>>, 32)
    session2 = put_in(session2.index_info.base_key, key2)
    record = SessionRecord.put_session(record, key2, session2)

    assert SessionRecord.have_open_session?(record)
    {open_key, _session} = SessionRecord.get_open_session(record)
    assert open_key == key2
  end
end
