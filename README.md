# rwa-fund-kit

A tokenized fund you can actually launch: permissioned shares, NAV-priced subscriptions and redemptions,
distributions and splits, with a test suite built around the ways real tokenized-asset systems have failed.

> **Status:** reference implementation. 128 tests (118 unit and fuzz, 10 invariants) and a 25-bug mutation
> check pass. It has **not** been independently audited. Read `docs/THREAT-MODEL.md` before using any of it.

**Live demo on Sepolia:** [open the console](https://arashrahmaniii.github.io/rwa-fund-kit/console/) and
run a dealing day yourself (a browser wallet with a little Sepolia ETH is all you need). Every contract's
source is verified on [Sourcify](https://repo.sourcify.dev/11155111/0x1Ed7A2ac9051E705B9bFA4808af12138Af22e053);
addresses are [below](#sepolia-deployment).

## What is in the box

| Contract | What it does |
|---|---|
| `token/FundShareToken.sol` | Permissioned share token in the ERC-3643 model: receiver must be verified, freeze (whole wallet or part of a balance), forced transfer, lost-wallet recovery, pause. Balances are stored as base shares and shown through a multiplier, so a split cannot move value. |
| `identity/IdentityRegistry.sol` | The on-chain copy of the investor register: wallet, country, class, KYC expiry. |
| `compliance/ModularCompliance.sol` | Runs the rule modules before every share movement and notifies them after it. |
| `compliance/modules/CountryRestrictModule.sol` | Blocks delivery to investors from listed countries. |
| `compliance/modules/MaxHoldersModule.sol` | Caps the number of investors. |
| `oracle/NavOracle.sol` | NAV per share with a valuation time, a deviation band that needs a second signer, and a staleness limit. |
| `vault/FundVault.sol` | ERC-7540-style asynchronous vault: request, cut-off, settlement at a NAV struck after the cut-off, claim. Nets cash with the custodian. Redemption gate and partial fills. |
| `actions/DistributionModule.sol` | Dividends and coupons, pro rata, pull-based. |
| `actions/CorporateActions.sol` | Share splits: multiplier and NAV change together or not at all. |
| `bridge/CrossChainGateway.sol` | Burn-and-mint bridge that checks eligibility where the shares land, parks them if the recipient is not eligible there, and caps what a compromised transport could mint. |
| `script/Deploy.s.sol` | Deploys and wires everything, and leaves the deployer with no rights. Tested like the contracts. |

```
                 ┌────────────────┐      verifies      ┌──────────────────┐
   investor ───► │   FundVault    │ ─────────────────► │ IdentityRegistry │
  (USDC, shares) │ request/settle │                    └──────────────────┘
                 │     /claim     │   mint, burn,               ▲
                 └───┬────────┬───┘   transferShares            │ isVerified
        net cash     │        │                                 │
                     ▼        ▼                        ┌────────┴─────────┐   canTransfer    ┌───────────────────┐
              ┌───────────┐ ┌───────────┐  multiplier  │  FundShareToken  │ ───────────────► │ ModularCompliance │
              │ Custodian │ │ NavOracle │ ◄──────────► │  (base shares ×  │   transferred /  │  Country · Max    │
              └───────────┘ └─────▲─────┘   rescale    │    multiplier)   │   created /      │  Holders ·        │
                                  │                    └────────▲─────────┘   destroyed      │  Distributions    │
                                  │      split()                │                            └───────────────────┘
                           ┌──────┴───────────┐                 │
                           │ CorporateActions │ ────────────────┘
                           └──────────────────┘
```

## The life of an epoch

1. **Open.** Investors call `requestDeposit` or `requestRedeem`. Cash and shares wait in the vault. A
   request can be cancelled.
2. **Cut-off.** The manager calls `closeEpoch`. Requests are locked in.
3. **Valuation.** The administrator posts a NAV whose valuation time is after the cut-off. A large move
   waits for the guardian.
4. **Settlement.** `settleEpoch` prices every request at that NAV, mints and burns shares, and moves only
   the net cash to or from the custodian. If liquidity is short, redemptions are filled pro rata and the
   rest comes back as shares.
5. **Claim.** Investors collect shares or cash whenever they like.

## Invariants, and the incidents behind them

The invariant suite (`test/invariant/`) drives the whole system with random investor, agent, manager and
attacker actions, then checks these properties. Each one exists because the opposite has happened somewhere.

| Property | The failure it guards against |
|---|---|
| The chain always equals the transfer agent's ledger | Issuer books and on-chain supply drifting apart |
| No unverified wallet ever holds a share, by any path | A side entrance that skips the KYC or blocklist check (seen in a live NAV-priced vault, 2026 review) |
| An epoch never settles at a NAV valued before its cut-off | The NAV free look: depositing just before a known price update and leaving just after |
| A split never changes the value of a share or the supply | Multiplier and rate switches that revalue balances (the class behind several rewards-token accounting bugs) |
| The vault holds exactly what it owes, in cash and in shares | Withdrawal queues that pay more than was escrowed, or pay twice |
| A correctly valued epoch can always be settled, whatever parameters changed | Epoch queues bricked by a parameter change made while requests were pending |
| Distributions never promise more than was funded | Reward accounting that lets claims exceed deposits |
| One investor who cannot receive the payment token blocks only themselves | Gavel Protocol KI-3: a USDC-blocklisted party made a shared repayment path revert |
| A frozen investor cannot take cash out | Sanctions controls that cover transfers but not redemptions |
| The holder counter is exact; frozen shares never exceed the balance | Compliance counters drifting through self-transfers and forced moves |
| Shares across all chains, plus parked shares, stay constant; an ineligible wallet is never credited on arrival | Bridges that mint on the destination without re-checking the investor, or strand value when the mint fails |

## What the tests found in this kit

The first version of `DistributionModule` passed all of its unit tests. The invariant campaign then
reported `over-promised: 68005849351 > 68005849350`: after enough balance changes, investors were owed one
unit more than had been funded. The cause was a starting point rounded down where it had to be rounded up.
It is fixed, explained in a comment at `_debtFor`, pinned by `testFuzz_manyBalanceChanges_neverOverPromise`,
and listed as mutation M24. One unit of USDC is not a loss, but it is the same shape as the reward-accounting
bugs that have been, and it is the kind of error only a stateful campaign finds.

## Does the test suite bite? The mutation check

A green suite proves little unless it goes red when the code is wrong. `tools/mutation_check.py` injects
25 specific bugs, one at a time (skip the identity check, settle at an old NAV, round a payout up by one
unit, split without rescaling the NAV, and so on), and runs the tests against each.

**Result: 25 of 25 injected bugs are caught.** The first run of this check caught 15 of 18; the three that
survived each pointed at a missing test, which is what the check is for.

Full table: `docs/MUTATION-RESULTS.md`.

## Quick start

```bash
forge build
forge test                        # 128 tests
forge test --match-path "test/invariant/*" -vv   # invariants, with a per-run activity summary
python tools/mutation_check.py    # 25 injected bugs, ~15 minutes
```

Requires Foundry. OpenZeppelin Contracts 5.1 and forge-std are vendored under `lib/`. The fuzz seed is
fixed in `foundry.toml` so results are reproducible; change it to explore other paths.

## The console

`docs/console/index.html` is a single page with no build step. It shows the fund's live state (NAV, supply,
the open epoch, the queue), runs the daily reconciliation checks from the issuer checklist, and has a panel
for each role: investor, transfer agent, manager, administrator and issuer. Contract errors are decoded
into their names, so a rejected call says `NavNotAfterCutoff` instead of a hex string.

Try it against a local node, with no wallet extension needed:

```bash
anvil --block-time 1
forge script script/DeployDemo.s.sol --sig "runDemo()" --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
python -m http.server 8765 --directory docs/console
# open http://localhost:8765/?rpc=http://127.0.0.1:8545
```

`DeployDemo.s.sol` adds a test-only `DemoOperator` that plays transfer agent, manager, administrator and
custodian at once, so one visitor can run a whole dealing day. It is the opposite of the role separation
the threat model asks for, and it is only for testnets.

## Deploying

`script/Deploy.s.sol` deploys and wires everything, grants every role to the addresses you give it, and
drops the deployer's own admin rights at the end. Try it against a local node first:

```bash
anvil &
forge script script/Deploy.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --private-key <anvil key>
```

Then work through `docs/ISSUER-CHECKLIST.md`.

**Deploying to Sepolia today:** Sepolia now charges far more gas to create contracts than the Cancun rules
Foundry simulates locally. FundVault needs about 21.9M gas on Sepolia against about 3.1M in the local
simulation, and the whole kit used 80.8M against an estimate of 16.4M. Give the script headroom, and pin the
simulation a few blocks behind the head so a load-balanced public RPC cannot answer "block not found":

```bash
B=$(( $(cast block-number --rpc-url $RPC) - 6 ))
forge script script/DeployDemo.s.sol --sig "runDemo()" --rpc-url $RPC --fork-block-number $B \
  --broadcast --slow --gas-estimate-multiplier 1500 --private-key <key>
```

Unused gas is not charged, so the multiplier costs nothing extra.

## Sepolia deployment

Deployed 2026-11-13 with `DeployDemo.s.sol` (testnet only: the `DemoOperator` holds operating roles so
visitors can run a dealing day). All 30 deployment transactions succeeded, and one full dealing day has been
run on-chain: 10,000 test USDC subscribed at NAV 1.0025 for 9,975.062344 shares. Source for every contract
is verified on Sourcify.

| Contract | Address |
|---|---|
| FundShareToken | [`0x7fb1A3eE5AB7e0A2E84ACaC22E3c0B1EAC09E35a`](https://sepolia.etherscan.io/address/0x7fb1A3eE5AB7e0A2E84ACaC22E3c0B1EAC09E35a) |
| FundVault | [`0x1Ed7A2ac9051E705B9bFA4808af12138Af22e053`](https://sepolia.etherscan.io/address/0x1Ed7A2ac9051E705B9bFA4808af12138Af22e053) |
| NavOracle | [`0x60D062b809ff2533fE2A124eEBCcA94274EaaE96`](https://sepolia.etherscan.io/address/0x60D062b809ff2533fE2A124eEBCcA94274EaaE96) |
| IdentityRegistry | [`0xFB84966bD0Fe5dFf382FF2a7C32EBd48fe1389FC`](https://sepolia.etherscan.io/address/0xFB84966bD0Fe5dFf382FF2a7C32EBd48fe1389FC) |
| ModularCompliance | [`0xC43c0bb2b4dB54578342D56a83856B4a52b875De`](https://sepolia.etherscan.io/address/0xC43c0bb2b4dB54578342D56a83856B4a52b875De) |
| CountryRestrictModule | [`0x4575739bf5502C830CC7d0d54e91D69eAB6651dA`](https://sepolia.etherscan.io/address/0x4575739bf5502C830CC7d0d54e91D69eAB6651dA) |
| MaxHoldersModule | [`0xB2cb0f61f0f1ca6cC527C7Ebc47fB6eE815362c6`](https://sepolia.etherscan.io/address/0xB2cb0f61f0f1ca6cC527C7Ebc47fB6eE815362c6) |
| DistributionModule | [`0x98cBcc64616C32337d8B7d75019E35F1F1Eca401`](https://sepolia.etherscan.io/address/0x98cBcc64616C32337d8B7d75019E35F1F1Eca401) |
| CorporateActions | [`0x60F014D5D1c2169DfA6A4D2755935A9aD22c9bE9`](https://sepolia.etherscan.io/address/0x60F014D5D1c2169DfA6A4D2755935A9aD22c9bE9) |
| MockUSDC (test payment token) | [`0xD79f9C60Eb928f4a428c66821fF852b5cD476a30`](https://sepolia.etherscan.io/address/0xD79f9C60Eb928f4a428c66821fF852b5cD476a30) |
| DemoOperator (testnet only) | [`0x32D06546774E0788BE7E792652D3c26f9821749c`](https://sepolia.etherscan.io/address/0x32D06546774E0788BE7E792652D3c26f9821749c) |

The machine-readable list the console loads is `docs/console/deployments/11155111.json`.

## What this kit is not

- **Not a full ERC-3643 (T-REX) implementation.** It follows the same model and function names (identity
  registry, modular compliance, freeze, forced transfer, recovery), but the registry is a direct
  attestation list. A production T-REX deployment verifies ONCHAINID claims from trusted issuers. The token
  only depends on `IIdentityRegistry`, so a claim-based registry can be swapped in.
- **Not a complete ERC-7540 vault.** It implements the request, claim and operator flows with aggregated
  requests (requestId 0) and the standard events. The `mint` and `withdraw` claim variants are left out.
- **No production bridge adapter.** `CrossChainGateway` talks to an `IMessenger` interface. The repository
  ships a mock transport for tests; a LayerZero or CCIP adapter still has to be written and reviewed.
- **No fees.** Management and performance fees are fund-specific and are not included.
- **No upgradeability.** See the threat model for why that is a decision, not an omission.
- **No legal opinion.** Whether a token built this way meets your regulator's rules is for your counsel.

## Roadmap

- LayerZero and CCIP adapters for the gateway.
- Fee module (management fee accrual by share dilution).

## Licence

MIT.
