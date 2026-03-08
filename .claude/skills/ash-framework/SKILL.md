---
name: ash-framework
description: "Expert on the Ash Framework ecosystem."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

- [ash](references/ash.md)
- [ash_ai](references/ash_ai.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash -p ash_ai
```

## Available Mix Tasks

- `mix ash` - Prints Ash help information
- `mix ash.codegen` - Runs all codegen tasks for any extension on any resource/domain in your application.
- `mix ash.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.gen.base_resource` - Generates a base resource. This is a module that you can use instead of `Ash.Resource`, for consistency.
- `mix ash.gen.change` - Generates a custom change module.
- `mix ash.gen.custom_expression` - Generates a custom expression module.
- `mix ash.gen.domain` - Generates an Ash.Domain
- `mix ash.gen.enum` - Generates an Ash.Type.Enum
- `mix ash.gen.preparation` - Generates a custom preparation module.
- `mix ash.gen.resource` - Generate and configure an Ash.Resource.
- `mix ash.gen.validation` - Generates a custom validation module.
- `mix ash.generate_livebook` - Generates a Livebook for each Ash domain
- `mix ash.generate_policy_charts` - Generates a Mermaid Flow Chart for a given resource's policies.
- `mix ash.generate_resource_diagrams` - Generates Mermaid Resource Diagrams for each Ash domain
- `mix ash.install` - Installs Ash into a project. Should be called with `mix igniter.install ash`
- `mix ash.migrate` - Runs all migration tasks for any extension on any resource/domain in your application.
- `mix ash.patch.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.reset` - Runs all tear down & setup tasks for any extension on any resource/domain in your application.
- `mix ash.rollback` - Runs all rollback tasks for any extension on any resource/domain in your application.
- `mix ash.setup` - Runs all setup tasks for any extension on any resource/domain in your application.
- `mix ash.tear_down` - Runs all tear_down tasks for any extension on any resource/domain in your application.
- `mix ash_ai.gen.chat` - Generates the resources and views for a conversational UI backed by `ash_postgres` and `ash_oban`
- `mix ash_ai.gen.chat.docs`
- `mix ash_ai.gen.mcp` - Sets up an MCP server for your application
- `mix ash_ai.gen.mcp.docs`
- `mix ash_ai.gen.usage_rules`
- `mix ash_ai.gen.usage_rules.docs`
- `mix ash_ai.install` - Installs `AshAi`. Call with `mix igniter.install ash_ai`. Requires igniter to run.
- `mix ash_ai.install.docs`
<!-- usage-rules-skill-end -->
