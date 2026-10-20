# idm (IDM) — custom token launch

A fixed-supply ERC-20 for the IMD custom-token launch `idm-16` on Robinhood Chain (chain id 4663).
Project page: x.com/theidmfun

| Item | Value |
| --- | --- |
| Solidity contract name | `IDMToken` (`src/IDMToken.sol`) |
| `name()` | `idm` |
| `symbol()` | `IDM` |
| `decimals()` | 18 |
| Total supply | 1,000,000,000 IDM = `1000000000000000000000000000` minor units (1e27) |
| Constructor arguments | none |
| Owner / admin | none |
| Standards | ERC-20, ERC-2612 `permit`, ERC-5267 `eip712Domain` |

## What it does

The constructor mints the whole supply once to `msg.sender` and nothing else ever changes the
supply upward. Under the launch, `msg.sender` is IMD's ProjectFactory, which then pays the supply
out: 10% to the launch's MerkleDistributor, 50% into the Uniswap v4 pool paired with IMD, and the
remaining 40% to the requester's `economics.remainderTo` address. Transfers are plain: no tax, no
burn on transfer, no reflections, no blacklist, no pause, no freeze. The token has no exemption
list because there is nothing to exempt from.

Holders can additionally approve by signature (`permit`). That is ordinary ERC-20 allowance state
set by the holder's own signature; it gives no third party any power over a balance.

## Design decisions and assumptions

- **No owner.** The brief asks for a plain token, so the contract inherits nothing ownable and
  exposes no privileged function. There is nothing to transfer to the launch owner and nothing the
  factory could keep. This is deliberate: the launch floor refuses any privileged call that can
  move or freeze a holder's balance, and the simplest way to pass is to have none.
- **No constructor arguments.** The token does not need `$factory`, `$poolManager` or
  `$launchNumber` because it applies no transfer rules. The constructor calls no other contract, so
  it runs on an empty chain.
- **Supply is a constant.** `TOTAL_SUPPLY = 1_000_000_000 * 10 ** 18` is minted exactly once. The
  manifest's `token.totalSupply` must be `1000000000000000000000000000`.
- **Library code is inlined.** Everything the token calls from OpenZeppelin is `internal`, so the
  built bytecode has no link placeholders and the launch can hash and deploy it as built.
- **Bytecode is reproducible.** `foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`,
  `optimizer = true` with 200 runs and `bytecode_hash = "none"`. `ffi` is off and there are no
  filesystem permissions.
- **Burns.** There is no `burn` function. Holders who want to burn can send to a dead address, which
  the floor allows; the supply figure then stays at 1e27 while circulating supply shrinks.

## Deployment parameters

The production deployment is performed by IMD's deployer through the ProjectFactory from the
attested bytecode. Nobody runs a script or holds a key for it in this repository.

Values the manifest step uses (recorded here for review only; this repository does not contain a
`launch.json`):

| Manifest field | Value |
| --- | --- |
| `token.contract` | `IDMToken` |
| `token.name` | `idm` |
| `token.symbol` | `IDM` |
| `token.decimals` | `18` |
| `token.constructorArgs` | `[]` |
| `token.totalSupply` | `1000000000000000000000000000` |
| `contracts` | `[]` (no application contracts) |
| `pool.pairedCurrency` | `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127` (IMD on Robinhood Chain) |
| `pool.fee` | `12500` |
| `pool.tickSpacing` | `60` |
| `pool.initialPrice` | `79228162514264337593543950336` (provenance only; the deployer derives the opening price) |
| `economics` | `{"poolBps":5000,"initialMarketCapWei":"2500000000000000000000","remainderTo":"0xee2aaa315cf7ed169f93148d30d24af9318dbb66"}` |

### Local or test-network deployment

`script/DeployIDMToken.s.sol` deploys the token with `new IDMToken()`. Its `deploy()` function takes
no configuration and is what the tests call; `run()` only wraps it in a broadcast. The account that
broadcasts receives the whole supply.

```sh
forge script script/DeployIDMToken.s.sol --rpc-url <rpc> --broadcast
```

## After launch

There is nothing to configure. The token has no owner-settable value, no setter and no external
dependency. The pool, distributor and requester allocations are all performed by the factory in
the launch transaction.

## Operational responsibilities

- **Requester.** Holds and safeguards the `remainderTo` wallet that receives 40% of the supply. No
  key in this repository has any power over the token.
- **IMD deployer.** Attests the source, launches through the factory, and verifies the source on the
  chain's explorer (`forge verify-contract`) after deployment so holders can audit it.
- **Nobody** can pause, mint, freeze, blacklist, upgrade or seize. If a change to the token is ever
  wanted, it requires a new token and a migration, not an admin call.

## Security notes

- The token holds no funds of its own and makes no external calls; there is no reentrancy surface
  and no oracle. `permit` enforces an owner-bound nonce, a deadline and an EIP-712 domain tied to
  the chain id and the contract address, so a signature cannot be replayed or moved across chains.
- The runtime bytecode contains no `DELEGATECALL`, `CALLCODE` or `SELFDESTRUCT`; a test scans for
  them. The runtime is well under the EIP-170 size limit.
- Tests passing are not an audit. Work holding other people's funds needs a separate adversarial
  review by an independent contributor before release.
- Tools run for this delivery: `forge build`, `forge test` (including fuzz with the verifier's seed)
  and `forge fmt --check`. Slither and Mythril were not available in this environment.

## Repository layout

```
foundry.toml                  compiler pins and build settings
remappings.txt                forge-std and @openzeppelin/contracts remappings
src/IDMToken.sol              the token
script/DeployIDMToken.s.sol   local deploy script (deploy() is testable without environment)
test/IDMToken.t.sol           behaviour, failure, launch-flow and bytecode tests
test/DeployIDMToken.t.sol     deploy() test
lib/forge-std                 vendored forge-std v1.9.7 (plain files, no submodule)
lib/openzeppelin-contracts    vendored OpenZeppelin Contracts v5.4.0 (plain files, no submodule)
```

Dependencies are committed as ordinary files so the project builds with no network access.

## Running the checks

```sh
forge build
forge test
forge fmt --check
```
