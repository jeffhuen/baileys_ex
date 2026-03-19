mode = System.get_env("BAILEYS_EX_PARITY_MODE", "qr")
auth_dir = System.get_env("BAILEYS_EX_PARITY_AUTH_DIR")
test_jid = System.get_env("BAILEYS_EX_PARITY_TEST_JID")
test_phone = System.get_env("BAILEYS_EX_PARITY_TEST_PHONE")
group_jid = System.get_env("BAILEYS_EX_PARITY_GROUP_JID")

errors =
  []
  |> then(fn acc ->
    if mode in ["qr", "phone_code"],
      do: acc,
      else: ["BAILEYS_EX_PARITY_MODE must be qr or phone_code" | acc]
  end)
  |> then(fn acc ->
    if is_binary(auth_dir) and auth_dir != "",
      do: acc,
      else: ["BAILEYS_EX_PARITY_AUTH_DIR is required" | acc]
  end)
  |> then(fn acc ->
    if is_binary(test_jid) and test_jid != "",
      do: acc,
      else: ["BAILEYS_EX_PARITY_TEST_JID is required" | acc]
  end)
  |> then(fn acc ->
    if mode != "phone_code" or (is_binary(test_phone) and test_phone != "") do
      acc
    else
      ["BAILEYS_EX_PARITY_TEST_PHONE is required when BAILEYS_EX_PARITY_MODE=phone_code" | acc]
    end
  end)
  |> Enum.reverse()

if errors != [] do
  IO.puts("Live validation harness is not ready:")

  Enum.each(errors, fn error ->
    IO.puts("  - #{error}")
  end)

  System.halt(1)
end

checklist_path = Path.expand("../parity/live/checklist.md", __DIR__)

IO.puts("""
Manual live validation harness

Mode: #{mode}
Auth dir: #{auth_dir}
Test JID: #{test_jid}
Test phone: #{test_phone || "(not set)"}
Group/community JID: #{group_jid || "(not set)"}

Checklist: #{checklist_path}

This harness is intentionally manual. Run the scenarios in the checklist and
capture exact mismatches with timestamps, emitted events, and wire nodes.
""")
