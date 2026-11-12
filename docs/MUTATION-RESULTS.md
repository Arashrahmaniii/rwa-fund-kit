# Mutation check results

Each row is a bug injected into the contracts on purpose. CAUGHT means the test suite failed, and
names the first test that failed. Regenerate with `python tools/mutation_check.py`.

**25 of 25 injected bugs caught.**

| Id | Injected bug | Result | First failing test |
|---|---|---|---|
| M01 | Settle at a NAV valued before the cut-off (NAV free look) | CAUGHT | `test_settle_withNavFromBeforeCutoff_reverts` |
| M02 | Transfers skip the receiver identity check | CAUGHT | `test_registry_removeIdentity_stopsInboundTransfers` |
| M03 | Split changes the multiplier but not the NAV | CAUGHT | `test_split_thenSubscribe_pricesCorrectly` |
| M04 | A frozen investor can withdraw redemption cash | CAUGHT | `test_redeem_frozenControllerCannotTakeCash` |
| M05 | Redemption proceeds rounded up by one unit | CAUGHT | `test_firstEpochEndToEnd` |
| M06 | Subscription shares rounded up by one | CAUGHT | `test_partialFreeze_limitsWhatCanMove` |
| M07 | Eligible share count not reduced when shares leave | CAUGHT | `test_distribute_withNoInvestors_reverts` |
| M08 | New shares earn distributions declared before they existed | CAUGHT | `test_laterBuyer_earnsNothingFromEarlierDistribution` |
| M09 | Self-transfer double-counts a holder | CAUGHT | `test_maxHolders_selfTransferDoesNotDoubleCount` |
| M10 | Partly filled redemption returns all shares as well as the cash | CAUGHT | `test_redeem_partialFill_returnsTheRest` |
| M11 | Forced transfer can deliver to an unverified wallet | CAUGHT | `test_forcedTransfer_toUnverified_reverts` |
| M12 | Deviation band disabled: one poster can reprice the fund | CAUGHT | `test_split_rescalesPendingNavToo` |
| M13 | Mint skips the compliance modules | CAUGHT | `test_bridge_destinationHolderCapAlsoParks` |
| M14 | Redemption gate not applied | CAUGHT | `test_redeem_gateCapsTheFill` |
| M15 | Distribution paid to an unverified holder | CAUGHT | `test_claim_requiresVerifiedUnfrozenHolder` |
| M16 | Anyone can claim another investor's shares | CAUGHT | `test_stranger_cannotActForController` |
| M17 | Distribution guard always reports no epoch awaiting its NAV | CAUGHT | `test_distribute_blockedWhileEpochAwaitsNav` |
| M18 | Partially frozen shares can be transferred | CAUGHT | `test_partialFreeze_limitsWhatCanMove` |
| M19 | Gateway accepts messages from any sender on a known chain | CAUGHT | `test_receive_fromUnknownPeer_reverts` |
| M20 | Inbound mint limit not enforced | CAUGHT | `test_compromisedMessenger_isBoundedByInboundLimit` |
| M21 | Bridging out does not burn the shares | CAUGHT | `test_paused_inboundIsParkedNotLost` |
| M22 | Returning parked shares leaves them parked as well | CAUGHT | `test_parked_agentCanReturnToSource` |
| M23 | Deployer keeps admin rights on the token after deployment | CAUGHT | `test_deployerKeepsNoRights` |
| M24 | Distribution starting point rounded down (over-promises by dust) | CAUGHT | `testFuzz_manyBalanceChanges_neverOverPromise` |
| M25 | A failed destination mint reverts the message instead of parking | CAUGHT | `test_parked_agentCanReturnToSource` |
