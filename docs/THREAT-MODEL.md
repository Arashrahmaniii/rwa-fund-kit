# Threat model

This document says who is trusted with what, what an attacker can try, and which test proves each defence.
It covers the contracts in `src/`. It does not cover the off-chain parts of a fund (custody, valuation,
KYC provider, key management), except where a contract depends on them.

## 1. Roles and what each one can do

| Role | Held by (recommended) | Can do | Cannot do |
|---|---|---|---|
| Token `DEFAULT_ADMIN_ROLE` | Issuer multisig behind a timelock | Grant roles, replace the registry or compliance engine, mark system addresses | Move or mint shares directly |
| Token `AGENT_ROLE` | Transfer agent | Freeze wallets or part of a balance, forced transfer, wallet recovery, pause transfers | Mint, change the multiplier, deliver to an unverified wallet |
| Token `MINTER_ROLE` | The vault and the gateway only | Mint to eligible wallets, burn shares it holds | Burn an investor's balance, mint past the compliance modules |
| Token `CORPORATE_ACTIONS_ROLE` | `CorporateActions` only | Change the multiplier | Anything else |
| Registry `AGENT_ROLE` | KYC operations | Add, renew and remove investor records | Touch balances |
| Oracle `ORACLE_ROLE` | Fund administrator | Post a NAV inside the deviation band | Post a NAV outside the band alone, back-date valuation time |
| Oracle `GUARDIAN_ROLE` | A second, independent signer | Confirm or reject a parked NAV | Post a NAV |
| Vault `MANAGER_ROLE` | Fund operations | Close and settle epochs, choose the redemption fill ratio, push settled shares to their owner | Choose the price, settle at an old NAV, pay anyone but the request's controller |
| Vault `DEFAULT_ADMIN_ROLE` | Issuer multisig | Set custodian, gate and minimum, pause new requests | Stop cancels or claims |
| `CorporateActions` `ISSUER_ROLE` | Issuer multisig | Run a split | Change multiplier and NAV separately |
| Distribution owner | Issuer treasury | Fund distributions, reassign an entitlement after recovery | Take back a funded distribution |
| Custodian | Fund treasury wallet | Holds invested cash; approves the vault to pull net redemptions | - |

**What you are trusting, in plain terms.** The administrator and guardian together set the price. The
manager decides when epochs close and how much liquidity redemptions get. The agent can move any
investor's shares to another verified wallet. This is how regulated funds work, and the contracts do not
pretend otherwise; what they do is keep each power narrow, logged, and unable to reach beyond its job.

## 2. Attackers considered

1. **An outsider** with no role and no verified wallet.
2. **A verified investor** acting in their own interest (front-running the NAV, gaming rounding, griefing others).
3. **A single compromised operator key** (poster, manager, or agent, one at a time).
4. **A hostile or broken payment token** (blocklists, reverting transfers).

## 3. Threats and defences

| # | Threat | Defence | Proven by |
|---|---|---|---|
| T1 | Unverified wallet obtains shares through any path: transfer, subscription claim, cancel, returned shares, forced transfer, recovery | Every path that credits a wallet runs the receiver identity check in the token itself, not in the callers | `invariant_unverifiedWalletHoldsNothing`, handler attacker actions, mutations M02, M11 |
| T2 | **NAV free look**: subscribe or redeem at a price that is already public | Requests lock at the cut-off; an epoch settles only at a NAV whose valuation time is after that cut-off; cancels stop at the cut-off | `test_settle_withNavFromBeforeCutoff_reverts`, `test_cancel_onlyBeforeCutoff`, mutation M01 |
| T3 | Wrong price from one compromised or mistaken poster | Moves beyond the deviation band wait for a second role; stale NAVs cannot settle | `test_post_outsideBand_waitsForGuardian`, mutation M12 |
| T4 | **Split creates or destroys value** (multiplier changed, price not) | One contract does both in one transaction and is the only holder of the role; all accounting is in base shares | `testFuzz_split_keepsValuePerBaseShare`, handler `split`, mutation M03 |
| T5 | Rounding leaks value to subscribers or redeemers | Shares minted round down, cash paid rounds down, per-account shares of an epoch round down | handler `_checkSettlement`, mutations M05, M06 |
| T6 | Redemption queue pays more than it holds, or pays twice | `reservedAssets` and `reservedShares` track what is owed; the vault's balances must equal them; unfilled shares are returned, never also paid | `invariant_vaultHoldsExactlyWhatItOwes`, `invariant_individualClaimsAreCovered`, mutation M10 |
| T7 | **Queue bricked by a parameter change** (gate, minimum, split, pause, freeze of another investor) | Settlement depends only on a fresh post-cut-off NAV and custodian liquidity; the handler changes every parameter at random and requires correct settlements to succeed | handler `settle` ("queue bricked" violation) |
| T8 | Run on the fund | Per-epoch gate as a share of supply, plus a manager-set fill ratio; everyone in the epoch gets the same ratio | `test_redeem_gateCapsTheFill`, `test_redeem_partialFill_returnsTheRest`, mutation M14 |
| T9 | Sanctioned investor cashes out | Frozen controllers cannot claim redemption cash or distributions; an expired KYC alone does not trap an investor | `test_redeem_frozenControllerCannotTakeCash`, `test_redeem_expiredKycCanStillLeave`, mutations M04, M15 |
| T10 | **Payment token blocks one investor** and thereby blocks everyone (the Gavel KI-3 class) | Cash leaves by pull, per investor; no loop pays several investors in one call | `test_blocklistedHolder_onlyBlocksItself` |
| T11 | Distribution accounting promises more than was funded, or pays shares that did not exist at the record date | Cumulative per-share accounting settled on every balance change; escrowed shares excluded; no distribution while an epoch awaits its NAV | `invariant_distributionsAreFullyFunded`, mutations M07, M08, M17 |
| T12 | Stranger acts on an investor's request | Controller-or-operator check on every request, cancel and claim | handler `attackerClaimsForInvestor`, mutation M16 |
| T13 | Holder cap or frozen balance bypassed | Module counts by live balances; partial freezes are enforced in the token's own transfer path | `invariant_holderCountIsExact`, mutations M09, M18 |
| T14 | Compliance rule skipped at mint | Mint runs the same module check as a transfer | `test_country_subscriptionFromBlockedCountry_cannotBeDelivered`, mutation M13 |
| T15 | Stateful module added after shares exist and starts from wrong totals | `addModule` reverts once supply is non-zero | `test_engine_cannotAddModuleOnceSharesExist` |
| T16 | Bridge credits a wallet that is not eligible on the destination chain | The destination token runs its own identity and compliance checks at mint; if they fail the shares are parked for that recipient | `test_bridge_toIneligibleRecipient_parksInsteadOfMinting`, `testFuzz_globalSupplyIsConserved`, mutation M13 |
| T17 | Value stranded in transit because the destination mint reverted | An inbound message never reverts for a recipient-side reason; limits are saturating | `test_paused_inboundIsParkedNotLost`, `test_loweringLimitBelowUsage_doesNotBreakInbound`, mutation M25 |
| T18 | Compromised or spoofed transport mints shares | Only the configured messenger may call; the sender must be the registered peer; minting is capped per window and can be paused | `test_receive_fromUnknownPeer_reverts`, `test_compromisedMessenger_isBoundedByInboundLimit`, mutations M19, M20 |
| T19 | Deployment leaves a privileged key behind | The script renounces every deployer role; a test asserts it per contract | `test_deployerKeepsNoRights`, mutation M23 |

## 4. Risks that remain (read before launch)

- **The price is an input.** If the administrator and the guardian both sign a wrong NAV, the vault will
  settle at it. Keep those keys in different organisations.
- **The agent is powerful.** A compromised agent key can move any investor's shares to another verified
  wallet. Use a multisig, and monitor `forcedTransfer` and `RecoverySuccess` events.
- **Custodian liquidity.** A net-redemption epoch can only settle if the custodian has approved and holds
  the cash. The manager can lower the fill ratio; investors get the remainder back as shares.
- **Settled shares wait in the vault until claimed** and earn no distributions there. The manager can
  deliver them with `pushDepositShares` before a distribution.
- **Requests in the open epoch at a distribution.** A redeemer whose request is still open when a
  distribution is funded does not receive it for the shares in the queue. Announce record dates; investors
  can cancel before the cut-off.
- **An investor who loses eligibility after subscribing** cannot receive the settled shares until
  re-verified. Their cash is already in the fund; resolve it operationally.
- **The bridge trusts its transport up to the rate limit.** A compromised messenger that can forge
  messages from the real peer can mint one window's inbound limit before it is paused. Set the limit to
  what you can afford to lose in one window, and alert on `Parked` events.
- **Splits must be applied on every chain.** Bridged amounts are in base shares, so a lag does not move
  value, but displayed balances differ until the split is applied everywhere.
- **Upgradeability is not included.** The contracts are not proxies. If you add upgradeability, the
  upgrade key becomes the most powerful role in the system.
- **Not audited.** This kit has tests and a mutation check, not an independent audit.
