# Upstream rc14 delta

Official comparison: `v7.0.0-rc13...v7.0.0-rc14`.

Runtime behavior in scope:

1. Default WA version becomes `[2, 3000, 1043857760]`.
2. Query TC-token entries require timestamps and emit `attrs.t`.
3. Profile-picture query tokens move under the `picture` node and retain the
   existing user/non-self/server-property eligibility rules.
4. Presence subscriptions use the same query-token shape.
5. Android browser tuples select Android user-agent/device-props behavior, omit
   web info, and emit an experimental warning.

Explicitly unchanged:

- Direct message relay constructs its own `tctoken` node with empty attributes.
- Type-only TypeScript imports and NPM release automation have no Elixir runtime
  behavior to port.
