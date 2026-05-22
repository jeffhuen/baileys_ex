%{
  configs: [
    %{
      name: "default",
      plugins: [{ExSlop, []}],
      checks: %{
        disabled: [
          {ExSlop.Check.Warning.DualKeyAccess, []},
          {ExSlop.Check.Warning.PathExpandPriv, []},
          {ExSlop.Check.Refactor.IdentityPassthrough, []},
          {ExSlop.Check.Refactor.ReduceMapPut, []},
          {ExSlop.Check.Refactor.RedundantEnumJoinSeparator, []},
          {ExSlop.Check.Refactor.WithIdentityElse, []}
        ]
      }
    }
  ]
}
