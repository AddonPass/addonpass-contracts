# Security

## Report a vulnerability

Report it privately through [GitHub vulnerability reporting](https://github.com/AddonPass/addonpass-contracts/security/advisories/new). Do not open a public issue for anything that could put funds at risk.

Include the affected function, what an attacker can do, and a Foundry test or steps that show it.

## Scope

[`src/AddonPassV1.sol`](src/AddonPassV1.sol) as deployed on Base mainnet at `0xc7aE26e865d9cf2Fe239dB37313aAaf4C0b01D0a`.

The contract cannot be upgraded. A fix means deploying a new contract and moving users to it.

Tests, the deployment script and the OpenZeppelin library are out of scope unless the issue affects the deployed contract.
