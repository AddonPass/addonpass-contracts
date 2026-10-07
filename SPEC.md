# Smart contract

`AddonPassV1` ([`src/AddonPassV1.sol`](src/AddonPassV1.sol)) collects Base USDC for customer subscriptions, snapshots the developer's active tier at each settlement, and keeps segregated claimable balances for developers and the platform. It also stores the entitlement state that developer middleware queries.

## Deployments

| Network | Chain ID | Address |
|---|---:|---|
| Base | 8453 | `0xc7aE26e865d9cf2Fe239dB37313aAaf4C0b01D0a` |

- Non-upgradeable. The USDC address is checked per chain (Base USDC `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913`, six decimals).
- Mainnet owner and treasury are the same 2-of-3 Safe. Ownership uses `Ownable2Step`; renouncing is disabled.
- Plan price bounds, monthly and annual charge limits and the guardian are constructor values. Mainnet: price 0.50 to 10,000 USDC, 12 monthly charges, 1 annual charge. The hard ceiling for either limit is 120.
- Fee percentages, tier prices and periods are constants.
- Successful payments are final and immediately claimable. There is no refund function, settlement delay, reserve or chargeback.

## Constants

| Constant | Value |
|---|---|
| Free fee | 500 bps plus 0.10 USDC fixed per payment |
| Pro fee / price | 200 bps / 12 USDC |
| Studio fee / price | 100 bps / 39 USDC |
| Tier period | 30 days |
| Monthly / annual period | 30 days / 365 days |
| One-time period | 0 (access never expires) |
| Customer grace | 3 days |
| Tier renewal window | final 3 days of the paid tier |

Periods are exact seconds, not calendar months.

## Data model

- `Developer`: payout wallet, selected tier, `tierPaidThrough`, auto-renew flag, sales and renewals flags, registered.
- `Plan`: developer, price, period, metadata hash, sales and renewals flags. Price, period and developer are immutable; a price change is a new plan.
- `Subscription`: plan, payer, entitlement hash, `paidThrough`, remaining charges, cancelled.
- Accounting: `developerClaimable[developer]`, `platformClaimable`, `totalDeveloperLiability`, `totalLiabilities`, and lifetime gross volume, transaction fee and developer-subscription counters (analytics only).

The developer wallet address is the account identifier.

## Developers and plans

- `registerDeveloper(payoutWallet)` is called by the developer wallet and reverts if already registered. `setPayoutWallet` is a direct change by the developer.
- `createPlan(price, period, metadataHash)` requires a registered developer, a supported period (monthly, annual or one-time) and a price within bounds.
- Developer-level and plan-level controls exist for new sales and for renewals. Disabling sales blocks new subscriptions only. Disabling renewals blocks future charges but never shortens paid access.
- The owner can additionally suspend a developer's sales or renewals.

## Developer tiers

`effectiveTier` is the selected tier while `tierPaidThrough` is in the future, otherwise Free. The fee is read at the moment a customer payment settles; tier changes never re-rate credited balances. There is no fee grace after a paid tier expires.

- `activateTierFromWallet(tier)` pulls the price in USDC from the developer (a separate USDC approval is required first). `activateTierFromOperatingBalance(tier)` moves the price from `developerClaimable` to `platformClaimable`.
- A purchase adds 30 days. Same-tier purchases keep unused time. Pro to Studio converts unused time to `floor(remaining * 12 / 39)` Studio seconds and then adds 30 days. Studio cannot be bought down to Pro while Studio is active; let it expire first.
- `setTierAutoRenew(enabled)` opts in to renewal from operating balance. `renewDeveloperTier(developer)` is callable by anyone, only when auto-renew is on and the renewal window is open. It moves the price from developer to platform balance, extends `tierPaidThrough` by 30 days and leaves total liabilities unchanged. With insufficient balance it emits `DeveloperTierRenewalFailed`, moves nothing and returns false.

A wallet purchase adds new USDC to the contract (liabilities increase); an operating-balance purchase only moves an existing liability.

## Customer subscriptions

- `subscribe(planId, entitlementHash, maxCharges)` and `subscribeWithPermit(..., permit)` share one internal `_subscribe`. The first period is charged immediately; `maxCharges` includes it and must not exceed the per-period limit.
- The entitlement hash must be nonzero and never used (active or retired). Only the hash is on-chain; the raw token is generated off-chain.
- `subscribeWithPermit` is an ERC-2612 variant: `msg.sender` is owner and payer, the spender is the contract, `permit.value` must equal `price * maxCharges`, and a mismatching existing allowance reverts.
- One-time plans charge once, set `paidThrough` far in the future, and cannot be cancelled or resumed.

### Renewal

`tryCharge(subscriptionId)` is permissionless and requires: not cancelled, charges remaining, now at or after `paidThrough` and no later than `paidThrough + 3 days`, and renewals enabled. It reads the developer's tier, attempts `transferFrom`, and on failure emits `CustomerChargeFailed` and returns false with no state change. On success it credits `gross - fee` to the developer and `fee` to the platform, advances `paidThrough` by the plan period, decrements remaining charges and emits `CustomerPaymentSettled` (gross, fee, net, tier, fee bps, new paid-through). Advancing `paidThrough` in the same transaction makes settlement idempotent per period. Free-tier fee is `gross * 500 / 10000 + 0.10 USDC`.

### Cancel, expiry, resume

- `cancel` is payer-only, stops future charges immediately, and keeps access until `paidThrough` (no grace).
- After grace, automatic charging is rejected. `resume(subscriptionId, maxCharges)` (payer-only) pays a new period immediately and restarts the charge budget.
- A cancelled subscription is resumable after `paidThrough`; an uncancelled one after grace. An exhausted authorization (no charges left, not cancelled) can resume at any time; the new period starts at the later of now and `paidThrough`.

### Entitlement

`entitlementStatus(hash)` returns entitled, `paidThrough`, `graceEnds`, subscription id and developer. Entitled means: at or before `paidThrough`; or inside grace while not cancelled, with charges remaining and renewals enabled. `rotateEntitlement` (payer-only) permanently retires the old hash and registers the new one atomically.

The contract proves payment status, not provider uptime.

## Withdrawals

- `withdrawDeveloper(amount)` / `withdrawAllDeveloper()`: the caller's claimable balance, paid only to the registered payout wallet.
- `withdrawPlatform(amount)` / `withdrawAllPlatform()`: treasury only, limited to `platformClaimable`.
- Liabilities are reduced before the transfer. Neither path touches the other's balance. Withdrawals work while payments are paused.

## Administration

- `pausePayments()`: owner or guardian. `unpausePayments()`: owner. Pause blocks subscribe, charges, resume and tier purchases, not cancellation or withdrawals.
- `setGuardian`, `setDeveloperSuspension`.
- Treasury change is two-step: `proposeTreasury` by the owner, `acceptTreasury` by the new address.
- `rescueNonUsdcToken` (to treasury) and `sweepSurplus` (only USDC above `totalLiabilities`).

The owner cannot change a plan, re-rate a balance, reverse a payment, touch developer liabilities or upgrade the contract.

## Refunds

A voluntary refund is a direct wallet transfer by the developer, outside the contract. It changes no balance, counter, event or entitlement state.

## Invariants

```text
USDC.balanceOf(contract) >= totalLiabilities
totalLiabilities = totalDeveloperLiability + platformClaimable
gross = fee + net for every settlement
a developer cannot withdraw more than developerClaimable
settled balances never change when a tier changes
a subscription settles at most once per billing period
a cancelled subscription is never charged
an expired subscription outside grace is never charged without the payer
```

## Events

Registration, payout, plan, sales/renewal flags, tier activation/auto-renew/renewal failure, subscription created/cancelled/resumed, `CustomerPaymentSettled`, `CustomerChargeFailed`, `EntitlementRotated`, withdrawals, and administrative changes are all emitted; see [`abi/AddonPassV1.json`](abi/AddonPassV1.json).
