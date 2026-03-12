defmodule BaileysEx.Message.IdentityChangeHandlerTest do
  use ExUnit.Case, async: true

  alias BaileysEx.BinaryNode
  alias BaileysEx.Message.IdentityChangeHandler
  alias BaileysEx.Signal.Repository
  alias BaileysEx.TestHelpers.MessageSignalHelpers

  test "handle/4 refreshes sessions for primary-device identity changes with an existing session" do
    {repo, _store} = MessageSignalHelpers.new_repo()
    session = MessageSignalHelpers.session_fixture()
    repo = inject_session!(repo, "15551234567@s.whatsapp.net", session)

    node = %BinaryNode{
      tag: "notification",
      attrs: %{"type" => "encrypt", "from" => "15551234567@s.whatsapp.net"},
      content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
    }

    context = %{
      signal_repository: repo,
      me_id: "15550001111@s.whatsapp.net",
      me_lid: "15550001111@lid",
      assert_sessions_fun: fn ctx, ["15551234567@s.whatsapp.net"], true ->
        send(self(), {:assert_sessions, ctx.signal_repository})
        {:ok, ctx, true}
      end
    }

    assert {:ok, %{action: :session_refreshed}, %{signal_repository: %Repository{}}, cache} =
             IdentityChangeHandler.handle(node, context, %{}, now_ms: 1_000)

    assert cache["15551234567@s.whatsapp.net"] == 1_000
    assert_received {:assert_sessions, %Repository{}}
  end

  test "handle/4 skips companion devices, self-primary, offline nodes, missing sessions, and debounces repeats" do
    {repo, _store} = MessageSignalHelpers.new_repo()

    assert {:ok, %{action: :skipped_companion_device, device: 2}, _context, _cache} =
             IdentityChangeHandler.handle(
               %BinaryNode{
                 tag: "notification",
                 attrs: %{"type" => "encrypt", "from" => "15551234567:2@s.whatsapp.net"},
                 content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
               },
               %{signal_repository: repo, me_id: "15550001111@s.whatsapp.net", me_lid: nil},
               %{},
               now_ms: 1_000
             )

    assert {:ok, %{action: :skipped_self_primary}, _context, _cache} =
             IdentityChangeHandler.handle(
               %BinaryNode{
                 tag: "notification",
                 attrs: %{"type" => "encrypt", "from" => "15550001111@s.whatsapp.net"},
                 content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
               },
               %{signal_repository: repo, me_id: "15550001111@s.whatsapp.net", me_lid: nil},
               %{},
               now_ms: 1_000
             )

    assert {:ok, %{action: :skipped_no_session}, _context, cache} =
             IdentityChangeHandler.handle(
               %BinaryNode{
                 tag: "notification",
                 attrs: %{"type" => "encrypt", "from" => "15557654321@s.whatsapp.net"},
                 content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
               },
               %{signal_repository: repo, me_id: "15550001111@s.whatsapp.net", me_lid: nil},
               %{},
               now_ms: 1_000
             )

    repo =
      inject_session!(repo, "15551234567@s.whatsapp.net", MessageSignalHelpers.session_fixture())

    assert {:ok, %{action: :skipped_offline}, _context, cache} =
             IdentityChangeHandler.handle(
               %BinaryNode{
                 tag: "notification",
                 attrs: %{
                   "type" => "encrypt",
                   "from" => "15551234567@s.whatsapp.net",
                   "offline" => "1"
                 },
                 content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
               },
               %{
                 signal_repository: repo,
                 me_id: "15550001111@s.whatsapp.net",
                 me_lid: nil,
                 assert_sessions_fun: fn _ctx, _jids, _force ->
                   flunk("offline identity changes should not assert sessions")
                 end
               },
               cache,
               now_ms: 2_000
             )

    assert {:ok, %{action: :debounced}, _context, _cache} =
             IdentityChangeHandler.handle(
               %BinaryNode{
                 tag: "notification",
                 attrs: %{"type" => "encrypt", "from" => "15551234567@s.whatsapp.net"},
                 content: [%BinaryNode{tag: "identity", attrs: %{}, content: nil}]
               },
               %{
                 signal_repository: repo,
                 me_id: "15550001111@s.whatsapp.net",
                 me_lid: nil,
                 assert_sessions_fun: fn _ctx, _jids, _force ->
                   flunk("debounced identity changes should not assert sessions")
                 end
               },
               cache,
               now_ms: 2_500
             )
  end

  defp inject_session!(repo, jid, session) do
    assert {:ok, next_repo} = Repository.inject_e2e_session(repo, %{jid: jid, session: session})
    next_repo
  end
end
