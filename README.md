# AddonPass contracts

The smart contract behind [AddonPass](https://addonpass.com): USDC subscriptions on Base for Stremio addons. This repository holds the exact source deployed on Base mainnet, with its tests, so anyone can review it.

To review it, start with [SPEC.md](SPEC.md). Report findings as described in [SECURITY.md](SECURITY.md).

## Deployment

| Network     | Address                                      | Source                                                                                                      |
| ----------- | -------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| Base (8453) | `0xc7aE26e865d9cf2Fe239dB37313aAaf4C0b01D0a` | [Verified on Blockscout](https://base.blockscout.com/address/0xc7aE26e865d9cf2Fe239dB37313aAaf4C0b01D0a?tab=contract) |

The contract is not upgradeable. Owner and treasury are a 2-of-3 Safe. Constructor values, deployment block and transaction are in [`deployments/base-8453.json`](deployments/base-8453.json).

## What is here

| Path                                                               | Contents                                               |
| ------------------------------------------------------------------ | ------------------------------------------------------ |
| [`src/AddonPassV1.sol`](src/AddonPassV1.sol)                       | The contract                                           |
| [`test/`](test)                                                    | Unit, fuzz and invariant tests                         |
| [`script/DeployAddonPassV1.s.sol`](script/DeployAddonPassV1.s.sol) | The deployment script                                  |
| [`abi/AddonPassV1.json`](abi/AddonPassV1.json)                     | ABI                                                    |
| [`SPEC.md`](SPEC.md)                                               | What the contract does and the invariants it must keep |

## Build and test

You need [Foundry](https://getfoundry.sh). Clone with `--recursive`: the build uses OpenZeppelin Contracts v5.7.0 and forge-std v1.16.2 as submodules, and without OpenZeppelin's own submodules the metadata hash changes.

```sh
git clone --recursive https://github.com/AddonPass/addonpass-contracts.git
cd addonpass-contracts
forge build
forge test
```

## Check it matches mainnet

This build reproduces the deployed bytecode exactly, metadata hash included. Deploy it on a local Base fork with the mainnet constructor values and compare code hashes:

```sh
anvil --fork-url https://mainnet.base.org &

# The private key is anvil's first test account.
forge create src/AddonPassV1.sol:AddonPassV1 --broadcast \
  --rpc-url http://127.0.0.1:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --constructor-args \
    0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
    0xA54f5c0476Df0f9a369F6c3c2912A3bdE79a32E0 \
    0xA54f5c0476Df0f9a369F6c3c2912A3bdE79a32E0 \
    0x38e08518aB900C1974cAf7f4776794FE9AFC8b98 \
    500000 10000000000 12 1

cast codehash <deployed-to-address> --rpc-url http://127.0.0.1:8545
cast codehash 0xc7aE26e865d9cf2Fe239dB37313aAaf4C0b01D0a --rpc-url https://mainnet.base.org
```

Both print `0xe3682bdaa7cbf0415e9a8c42cdff374a919e4e1c94aca27039d746729095cc23`.

## Audit reports

If you write an audit report, open a pull request that adds it under `audits/`.

## License

[MIT](LICENSE)
