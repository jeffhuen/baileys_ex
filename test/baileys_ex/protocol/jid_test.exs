defmodule BaileysEx.Protocol.JIDTest do
  use ExUnit.Case, async: true

  alias BaileysEx.JID
  alias BaileysEx.Protocol.JID, as: JIDUtil

  describe "parse/1" do
    test "parses user@s.whatsapp.net" do
      jid = JIDUtil.parse("5511999887766@s.whatsapp.net")
      assert %JID{user: "5511999887766", server: "s.whatsapp.net", device: nil, agent: nil} = jid
    end

    test "parses group@g.us" do
      jid = JIDUtil.parse("120363001234567890@g.us")
      assert %JID{user: "120363001234567890", server: "g.us", device: nil, agent: nil} = jid
    end

    test "parses status@broadcast" do
      jid = JIDUtil.parse("status@broadcast")
      assert %JID{user: "status", server: "broadcast", device: nil, agent: nil} = jid
    end

    test "parses user@lid" do
      jid = JIDUtil.parse("abc123@lid")
      assert %JID{user: "abc123", server: "lid", device: nil, agent: nil} = jid
    end

    test "parses user:device@server" do
      jid = JIDUtil.parse("5511999887766:2@s.whatsapp.net")
      assert %JID{user: "5511999887766", server: "s.whatsapp.net", device: 2, agent: nil} = jid
    end

    test "parses user_agent:device@server" do
      jid = JIDUtil.parse("5511999887766_1:3@s.whatsapp.net")
      assert %JID{user: "5511999887766", server: "s.whatsapp.net", device: 3, agent: 1} = jid
    end

    test "parses @server with nil user" do
      jid = JIDUtil.parse("@s.whatsapp.net")
      assert %JID{user: nil, server: "s.whatsapp.net", device: nil, agent: nil} = jid
    end

    test "parses newsletter JID" do
      jid = JIDUtil.parse("1234567890@newsletter")
      assert %JID{user: "1234567890", server: "newsletter", device: nil, agent: nil} = jid
    end

    test "returns nil for string without @" do
      assert JIDUtil.parse("noatsign") == nil
    end

    test "returns nil for nil input" do
      assert JIDUtil.parse(nil) == nil
    end

    test "returns nil for empty string" do
      assert JIDUtil.parse("") == nil
    end
  end

  describe "to_string/1" do
    test "formats basic user JID" do
      jid = %JID{user: "5511999887766", server: "s.whatsapp.net"}
      assert JIDUtil.to_string(jid) == "5511999887766@s.whatsapp.net"
    end

    test "formats group JID" do
      jid = %JID{user: "120363001234567890", server: "g.us"}
      assert JIDUtil.to_string(jid) == "120363001234567890@g.us"
    end

    test "formats JID with device" do
      jid = %JID{user: "5511999887766", server: "s.whatsapp.net", device: 2}
      assert JIDUtil.to_string(jid) == "5511999887766:2@s.whatsapp.net"
    end

    test "formats JID with agent and device" do
      jid = %JID{user: "5511999887766", server: "s.whatsapp.net", device: 3, agent: 1}
      assert JIDUtil.to_string(jid) == "5511999887766_1:3@s.whatsapp.net"
    end

    test "formats JID with nil user" do
      jid = %JID{user: nil, server: "s.whatsapp.net"}
      assert JIDUtil.to_string(jid) == "@s.whatsapp.net"
    end

    test "omits device when 0" do
      jid = %JID{user: "5511999887766", server: "s.whatsapp.net", device: 0}
      assert JIDUtil.to_string(jid) == "5511999887766@s.whatsapp.net"
    end

    test "omits agent when 0" do
      jid = %JID{user: "5511999887766", server: "s.whatsapp.net", agent: 0}
      assert JIDUtil.to_string(jid) == "5511999887766@s.whatsapp.net"
    end
  end

  describe "jid_encode/4" do
    test "encodes user and server" do
      assert JIDUtil.jid_encode("5511999887766", "s.whatsapp.net") ==
               "5511999887766@s.whatsapp.net"
    end

    test "encodes with device" do
      assert JIDUtil.jid_encode("5511999887766", "s.whatsapp.net", 2) ==
               "5511999887766:2@s.whatsapp.net"
    end

    test "encodes with nil user" do
      assert JIDUtil.jid_encode(nil, "s.whatsapp.net") == "@s.whatsapp.net"
    end
  end

  describe "roundtrip parse -> to_string" do
    test "roundtrips user JID" do
      original = "5511999887766@s.whatsapp.net"
      assert original == original |> JIDUtil.parse() |> JIDUtil.to_string()
    end

    test "roundtrips group JID" do
      original = "120363001234567890@g.us"
      assert original == original |> JIDUtil.parse() |> JIDUtil.to_string()
    end

    test "roundtrips JID with device" do
      original = "5511999887766:2@s.whatsapp.net"
      assert original == original |> JIDUtil.parse() |> JIDUtil.to_string()
    end

    test "roundtrips status broadcast" do
      original = "status@broadcast"
      assert original == original |> JIDUtil.parse() |> JIDUtil.to_string()
    end

    test "roundtrips LID" do
      original = "abc123@lid"
      assert original == original |> JIDUtil.parse() |> JIDUtil.to_string()
    end
  end

  describe "type predicates" do
    test "group?" do
      assert JIDUtil.group?(%JID{user: "123", server: "g.us"})
      refute JIDUtil.group?(%JID{user: "123", server: "s.whatsapp.net"})
      assert JIDUtil.group?("123@g.us")
      refute JIDUtil.group?("123@s.whatsapp.net")
    end

    test "user?" do
      assert JIDUtil.user?(%JID{user: "123", server: "s.whatsapp.net"})
      refute JIDUtil.user?(%JID{user: "123", server: "g.us"})
    end

    test "broadcast?" do
      assert JIDUtil.broadcast?(%JID{user: "status", server: "broadcast"})
      refute JIDUtil.broadcast?(%JID{user: "123", server: "s.whatsapp.net"})
    end

    test "newsletter?" do
      assert JIDUtil.newsletter?(%JID{user: "123", server: "newsletter"})
      refute JIDUtil.newsletter?(%JID{user: "123", server: "s.whatsapp.net"})
    end

    test "lid?" do
      assert JIDUtil.lid?(%JID{user: "abc", server: "lid"})
      refute JIDUtil.lid?(%JID{user: "abc", server: "s.whatsapp.net"})
    end

    test "hosted_pn?" do
      assert JIDUtil.hosted_pn?(%JID{user: "123", server: "hosted"})
      refute JIDUtil.hosted_pn?(%JID{user: "123", server: "s.whatsapp.net"})
      assert JIDUtil.hosted_pn?("123@hosted")
      refute JIDUtil.hosted_pn?("123@hosted.lid")
    end

    test "hosted_lid?" do
      assert JIDUtil.hosted_lid?(%JID{user: "123", server: "hosted.lid"})
      refute JIDUtil.hosted_lid?(%JID{user: "123", server: "hosted"})
      assert JIDUtil.hosted_lid?("123@hosted.lid")
      refute JIDUtil.hosted_lid?("123@hosted")
    end

    test "status_broadcast?" do
      assert JIDUtil.status_broadcast?(%JID{user: "status", server: "broadcast"})
      refute JIDUtil.status_broadcast?(%JID{user: "other", server: "broadcast"})
      assert JIDUtil.status_broadcast?("status@broadcast")
      refute JIDUtil.status_broadcast?("other@broadcast")
    end
  end

  describe "addressing_mode/1" do
    test "returns :lid for LID JIDs" do
      assert JIDUtil.addressing_mode(%JID{user: "abc", server: "lid"}) == :lid
    end

    test "returns :pn for non-LID JIDs" do
      assert JIDUtil.addressing_mode(%JID{user: "123", server: "s.whatsapp.net"}) == :pn
      assert JIDUtil.addressing_mode(%JID{user: "123", server: "g.us"}) == :pn
    end
  end

  describe "to_signal_address/1" do
    test "strips device" do
      jid = %JID{user: "123", server: "s.whatsapp.net", device: 2, agent: 1}
      signal = JIDUtil.to_signal_address(jid)
      assert signal.device == nil
      assert signal.agent == nil
      assert signal.user == "123"
      assert signal.server == "s.whatsapp.net"
    end
  end

  describe "normalized_user/1" do
    test "normalizes c.us to s.whatsapp.net" do
      assert JIDUtil.normalized_user("5511999887766@c.us") == "5511999887766@s.whatsapp.net"
    end

    test "strips device" do
      assert JIDUtil.normalized_user("5511999887766:2@s.whatsapp.net") ==
               "5511999887766@s.whatsapp.net"
    end

    test "returns empty string for nil" do
      assert JIDUtil.normalized_user(nil) == ""
    end
  end

  describe "same_user?/2" do
    test "returns true for same user different devices" do
      assert JIDUtil.same_user?("123@s.whatsapp.net", "123:2@s.whatsapp.net")
    end

    test "returns false for different users" do
      refute JIDUtil.same_user?("123@s.whatsapp.net", "456@s.whatsapp.net")
    end

    test "returns false when either is nil" do
      refute JIDUtil.same_user?(nil, "123@s.whatsapp.net")
      refute JIDUtil.same_user?("123@s.whatsapp.net", nil)
    end
  end

  describe "domain_type_for_server/1" do
    test "returns correct domain types" do
      assert JIDUtil.domain_type_for_server("lid") == 1
      assert JIDUtil.domain_type_for_server("hosted") == 128
      assert JIDUtil.domain_type_for_server("hosted.lid") == 129
      assert JIDUtil.domain_type_for_server("s.whatsapp.net") == 0
    end
  end

  describe "server_from_domain_type/2" do
    test "returns correct servers" do
      assert JIDUtil.server_from_domain_type(1, "s.whatsapp.net") == "lid"
      assert JIDUtil.server_from_domain_type(128, "s.whatsapp.net") == "hosted"
      assert JIDUtil.server_from_domain_type(129, "s.whatsapp.net") == "hosted.lid"
      assert JIDUtil.server_from_domain_type(0, "s.whatsapp.net") == "s.whatsapp.net"
    end
  end
end
