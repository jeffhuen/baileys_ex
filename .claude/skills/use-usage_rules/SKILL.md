---
name: use-usage_rules
description: "A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [elixir](references/elixir.md)
- [otp](references/otp.md)
- [usage_rules](references/usage_rules.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p usage_rules
```

## Available Mix Tasks

- `mix usage_rules.docs` - Shows documentation for Elixir modules and functions
- `mix usage_rules.install` - Installs usage_rules
- `mix usage_rules.install.docs`
- `mix usage_rules.search_docs` - Searches hexdocs with human-readable output
- `mix usage_rules.sync` - Sync AGENTS.md and agent skills from project config
- `mix usage_rules.sync.docs`
<!-- usage-rules-skill-end -->
