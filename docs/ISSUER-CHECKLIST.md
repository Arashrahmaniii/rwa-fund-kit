# Launch checklist for issuers

A working list for a team taking a tokenized fund live with this kit. It is engineering guidance, not
legal advice: your counsel decides what your offering documents and regulators require.

## Before deployment

**Decide the product**
- [ ] Asset the fund takes and pays (for example USDC), and what happens if that token blocklists an investor.
- [ ] Dealing frequency: how often epochs close, and how long valuation takes after the cut-off.
- [ ] Redemption terms: gate per epoch, notice period, minimum subscription.
- [ ] Which countries and investor classes may hold shares; the holder cap, if any.
- [ ] Whether the fund distributes income or accumulates it.

**Assign the keys** (see the role table in `THREAT-MODEL.md`)
- [ ] Admin roles on every contract sit with a multisig, ideally behind a timelock.
- [ ] NAV poster and NAV guardian are different people in different organisations.
- [ ] Transfer agent role is a multisig or an HSM-backed service, not a laptop key.
- [ ] `CorporateActions` is the only holder of `CORPORATE_ACTIONS_ROLE` on the token and the oracle.
- [ ] The vault (and gateway, if used) are the only holders of `MINTER_ROLE`.
- [ ] The deployer key holds nothing after deployment. Check with `hasRole` for every role.

**Set the parameters**
- [ ] `maxDeviationBps`: wide enough for a normal day, tight enough that a typo is caught.
- [ ] `maxStaleness`: longer than your valuation cycle, shorter than two of them.
- [ ] `maxRedeemBpsPerEpoch` and `minDeposit` match the offering documents.
- [ ] Blocked countries loaded into `CountryRestrictModule`.
- [ ] All compliance modules are added **before the first share is minted**. They cannot be added later.

## Deployment
- [ ] Deploy with `script/Deploy.s.sol` on a testnet first and run one full epoch end to end.
- [ ] Verify every contract on the block explorer.
- [ ] Record the deployed bytecode hashes; re-check them against the audited commit before going live.
- [ ] Custodian wallet approves the vault for the payment token.
- [ ] `DistributionModule.setEpochGuard(vault)` is set.

## Every dealing day
1. Investors place and cancel requests until the cut-off.
2. Manager calls `closeEpoch()`.
3. Administrator values the fund **as of a time after the cut-off** and posts the NAV.
4. If the move is outside the band, the guardian reviews and confirms or rejects it.
5. Manager checks custodian liquidity, then calls `settleEpoch(fillBps)`.
6. Investors claim. Optionally the manager pushes settled shares to their owners.

## Reconciliation (daily)
- [ ] `token.totalShares()` equals the transfer agent's ledger total.
- [ ] `usdc.balanceOf(vault) == vault.reservedAssets()` and `token.sharesOf(vault) == vault.reservedShares()`.
- [ ] `holdersModule.holderCount()` equals the number of investors on the ledger with a balance.
- [ ] Distribution contract balance covers every unpaid entitlement.

## Alerts to set up
- [ ] `NavPendingConfirmation` (a NAV outside the band was posted).
- [ ] `forcedTransfer`, `RecoverySuccess`, `AddressFrozen` on the token.
- [ ] Any `RoleGranted` / `RoleRevoked` on any contract.
- [ ] `MultiplierUpdated` without a matching `NavRescaled` in the same transaction.
- [ ] An epoch closed for longer than your valuation cycle without settling.
- [ ] Custodian allowance or balance below the redemptions in the queue.

## Corporate actions
- [ ] **Distribution:** make sure no epoch is awaiting its NAV, push unclaimed settled shares to their
      owners, then call `distribute`. The record date is the block of that call.
- [ ] **Split:** call `CorporateActions.split`. Never grant anyone the right to change the multiplier or
      rescale the NAV on their own.
- [ ] **Wallet recovery:** verify the new wallet, call `recoveryAddress`, then
      `reassignEntitlement` on the distribution module.

## Before mainnet
- [ ] Independent audit of the exact commit you deploy.
- [ ] `forge test` and `python tools/mutation_check.py` both pass on that commit.
- [ ] An incident runbook: who pauses, who freezes, who talks to investors.
