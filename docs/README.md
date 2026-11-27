# Documentation

Start with the [project README](../README.md) for the security model, requirements and development quickstart.

| I want to…                                 | Start here                                                                  |
| ------------------------------------------ | --------------------------------------------------------------------------- |
| Configure or use an agent                  | [User guides](guides/README.md)                                             |
| Deploy, upgrade or recover an installation | [Deployment guide](deploy/README.md)                                        |
| Understand implementation boundaries       | [Architecture references](architecture/README.md)                           |
| Build the new interface                    | [Design handoff (direction E)](design/README.md)                            |
| Build a release                            | [Release policy](development/releasing.md) and [changelog](../CHANGELOG.md) |
| Find work that remains                     | [Active plans and follow-ups](../plans/README.md)                           |
| Retrieve an earlier design or evaluation   | [Historical records in Git](development/historical-records.md)              |

## Development and package references

- [Gateway and node development/API](development/gateway-and-node.md)
- [Flutter client](../apps/app/README.md)
- [Web client](../apps/web/README.md)
- [First-send live client acceptance](development/first-send-acceptance.md)
- [Nix packaging and module](../nix/README.md)
- [Timeline fixtures](../fixtures/timeline/README.md)

## Where information belongs

- **`guides/`** explains current user-facing behavior and configuration. Use **`deploy/`** for host setup, environment variables and operations.
- **`architecture/`** explains current implementation contracts, trust/storage boundaries and accepted security decisions.
- **`../plans/`** contains unfinished work, deferred decisions and remaining validation. A plan is not authorization to implement or deploy it.
- **Git history** preserves completed plans, implementation diaries and original evaluation evidence; the [historical locator](development/historical-records.md) identifies their snapshots and outcomes.

When work completes, update the owning current guide or contract and remove its implementation diary from the plan. Preserve unresolved checks, accepted limitations and unique decisions before retiring a document. Update links and source comments; keep historical failures, incomplete runs and waived checks distinct from passed validation.
