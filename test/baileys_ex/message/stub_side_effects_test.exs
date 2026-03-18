defmodule BaileysEx.Message.StubSideEffectsTest do
  use ExUnit.Case, async: true

  alias BaileysEx.Message.StubSideEffects

  @group_jid "120363001234567890@g.us"
  @author "15551234567@s.whatsapp.net"
  @author_pn "15551234567@s.whatsapp.net"
  @me_id "15559999999@s.whatsapp.net"

  defp participant_json(jid, opts \\ []) do
    map = %{
      "id" => jid,
      "phone_number" => Keyword.get(opts, :phone_number, jid),
      "lid" => Keyword.get(opts, :lid),
      "admin" => Keyword.get(opts, :admin)
    }

    JSON.encode!(map)
  end

  describe "participant actions" do
    test "GROUP_PARTICIPANT_ADD emits add action" do
      participants = [participant_json("15550001111@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_ADD,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [
               {:group_participants_update,
                %{
                  id: @group_jid,
                  author: @author,
                  author_pn: @author_pn,
                  participants: [%{"id" => "15550001111@s.whatsapp.net"} | _],
                  action: :add
                }}
             ] = effects
    end

    test "GROUP_PARTICIPANT_INVITE emits add action" do
      participants = [participant_json("15550002222@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_INVITE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :add}}] = effects
    end

    test "GROUP_PARTICIPANT_ADD_REQUEST_JOIN emits add action" do
      participants = [participant_json("15550003333@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_ADD_REQUEST_JOIN,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :add}}] = effects
    end

    test "GROUP_PARTICIPANT_REMOVE emits remove action" do
      participants = [participant_json("15550004444@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_REMOVE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :remove}}] = effects
    end

    test "GROUP_PARTICIPANT_LEAVE emits remove action" do
      participants = [participant_json("15550005555@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_LEAVE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :remove}}] = effects
    end

    test "GROUP_PARTICIPANT_PROMOTE emits promote action" do
      participants = [participant_json("15550006666@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_PROMOTE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :promote}}] = effects
    end

    test "GROUP_PARTICIPANT_DEMOTE emits demote action" do
      participants = [participant_json("15550007777@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_DEMOTE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :demote}}] = effects
    end

    test "GROUP_CHANGE_SUBJECT (modify tag) emits modify action" do
      participants = [participant_json("15550008888@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_CHANGE_NUMBER,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, %{action: :modify}}] = effects
    end
  end

  describe "read_only flips" do
    test "remove/leave sets read_only true when participants include me" do
      participants = [participant_json(@me_id)]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_REMOVE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert {:group_participants_update, _} = Enum.at(effects, 0)
      assert {:chats_update, [%{id: @group_jid, read_only: true}]} = Enum.at(effects, 1)
    end

    test "add sets read_only false when participants include me" do
      participants = [participant_json(@me_id)]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_ADD,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert {:group_participants_update, _} = Enum.at(effects, 0)
      assert {:chats_update, [%{id: @group_jid, read_only: false}]} = Enum.at(effects, 1)
    end

    test "remove does not set read_only when participants do not include me" do
      participants = [participant_json("15550009999@s.whatsapp.net")]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_REMOVE,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, _}] = effects
    end
  end

  describe "group metadata updates" do
    test "GROUP_CHANGE_SUBJECT emits groups_update with subject" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_SUBJECT,
          stub_parameters: ["New Group Name"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [
               {:groups_update,
                [
                  %{
                    id: @group_jid,
                    subject: "New Group Name",
                    author: @author,
                    author_pn: @author_pn
                  }
                ]}
             ] = effects
    end

    test "GROUP_CHANGE_DESCRIPTION emits groups_update with desc" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_DESCRIPTION,
          stub_parameters: ["A new description"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [
               {:groups_update,
                [
                  %{
                    id: @group_jid,
                    desc: "A new description",
                    author: @author,
                    author_pn: @author_pn
                  }
                ]}
             ] = effects
    end

    test "GROUP_CHANGE_ANNOUNCE on emits groups_update with announce true" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_ANNOUNCE,
          stub_parameters: ["on"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, announce: true}]}] = effects
    end

    test "GROUP_CHANGE_ANNOUNCE off emits groups_update with announce false" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_ANNOUNCE,
          stub_parameters: ["off"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, announce: false}]}] = effects
    end

    test "GROUP_CHANGE_RESTRICT on emits groups_update with restrict true" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_RESTRICT,
          stub_parameters: ["on"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, restrict: true}]}] = effects
    end

    test "GROUP_CHANGE_RESTRICT off emits groups_update with restrict false" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_RESTRICT,
          stub_parameters: ["off"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, restrict: false}]}] = effects
    end

    test "GROUP_CHANGE_INVITE_LINK emits groups_update with invite_code" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_CHANGE_INVITE_LINK,
          stub_parameters: ["abc123"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, invite_code: "abc123"}]}] = effects
    end

    test "GROUP_MEMBER_ADD_MODE all_member_add emits groups_update with member_add_mode true" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_MEMBER_ADD_MODE,
          stub_parameters: ["all_member_add"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, member_add_mode: true}]}] = effects
    end

    test "GROUP_MEMBER_ADD_MODE other value emits groups_update with member_add_mode false" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_MEMBER_ADD_MODE,
          stub_parameters: ["admin_add"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, member_add_mode: false}]}] = effects
    end

    test "GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE on emits groups_update with join_approval_mode true" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE,
          stub_parameters: ["on"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, join_approval_mode: true}]}] = effects
    end

    test "GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE off emits groups_update with join_approval_mode false" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_MEMBERSHIP_JOIN_APPROVAL_MODE,
          stub_parameters: ["off"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:groups_update, [%{id: @group_jid, join_approval_mode: false}]}] = effects
    end
  end

  describe "group join request" do
    test "GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD emits group_join_request" do
      participant_data =
        JSON.encode!(%{"lid" => "12345@lid", "pn" => "15550001111@s.whatsapp.net"})

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_MEMBERSHIP_JOIN_APPROVAL_REQUEST_NON_ADMIN_ADD,
          stub_parameters: [participant_data, "created", "non_admin_add"],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [
               {:group_join_request,
                %{
                  id: @group_jid,
                  author: @author,
                  author_pn: @author_pn,
                  participant: "12345@lid",
                  participant_pn: "15550001111@s.whatsapp.net",
                  action: "created",
                  method: "non_admin_add"
                }}
             ] = effects
    end
  end

  describe "unknown stub types" do
    test "returns empty list for unrecognized stub types" do
      effects =
        StubSideEffects.derive(%{
          stub_type: :UNKNOWN_TYPE,
          stub_parameters: [],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [] = effects
    end

    test "returns empty list for nil stub type" do
      effects =
        StubSideEffects.derive(%{
          stub_type: nil,
          stub_parameters: [],
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [] = effects
    end
  end

  describe "multiple participants" do
    test "multiple participants are all included in the event" do
      participants = [
        participant_json("15550001111@s.whatsapp.net"),
        participant_json("15550002222@s.whatsapp.net")
      ]

      effects =
        StubSideEffects.derive(%{
          stub_type: :GROUP_PARTICIPANT_ADD,
          stub_parameters: participants,
          group_jid: @group_jid,
          author: @author,
          author_pn: @author_pn,
          me_id: @me_id
        })

      assert [{:group_participants_update, payload}] = effects
      assert length(payload.participants) == 2
    end
  end
end
