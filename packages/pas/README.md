# Permissioned Asset Standard

This Move package contains the core Permissioned Asset Standard (PAS) modules for
accounts, policies, requests, and approval flows that govern restricted asset
movement on Sui. PAS manages both fungible **balances** and arbitrary `key + store`
**objects** (via transfer-to-object); see the `*_object` functions in `account`,
`send_funds`, and `policy::new_for_object`.

## Docs

See the Sui documentation for the
[Permissioned Asset Standard](https://docs.sui.io/onchain-finance/pas/).

The TypeScript SDK is available as
[`@mysten/pas`](https://www.npmjs.com/package/@mysten/pas).
