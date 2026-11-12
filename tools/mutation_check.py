"""Mutation check: inject one known bug at a time and confirm the test suite fails.

A green test suite only means something if it goes red when the code is wrong. Each entry below is a
bug of a kind that has caused real losses in tokenized-asset systems. The script applies it, runs
`forge test --fail-fast`, records which test caught it, and restores the file.

Usage:  python tools/mutation_check.py            (all mutations)
        python tools/mutation_check.py M03 M07    (selected ones)
Writes docs/MUTATION-RESULTS.md.
"""
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent

# id, file, what the bug is, original text, mutated text
MUTATIONS = [
    ("M01", "src/vault/FundVault.sol", "Settle at a NAV valued before the cut-off (NAV free look)",
     "if (navAsOf <= e.closedAt) revert NavNotAfterCutoff(navAsOf, e.closedAt);", ""),
    ("M02", "src/token/FundShareToken.sol", "Transfers skip the receiver identity check",
     "if (!isSystem[to] && !identityRegistry.isVerified(to)) revert ReceiverNotVerified(to);", ""),
    ("M03", "src/actions/CorporateActions.sol", "Split changes the multiplier but not the NAV",
     "oracle.rescaleForSplit(numerator, denominator);", ""),
    ("M04", "src/vault/FundVault.sol", "A frozen investor can withdraw redemption cash",
     "if (share.frozen(controller)) revert ControllerFrozen(controller);", ""),
    ("M05", "src/vault/FundVault.sol", "Redemption proceeds rounded up by one unit",
     "uint256 paid = Math.mulDiv(Math.mulDiv(filled, mult, ONE), nav, ONE) / assetScale;",
     "uint256 paid = Math.mulDiv(Math.mulDiv(filled, mult, ONE), nav, ONE) / assetScale + 1;"),
    ("M06", "src/vault/FundVault.sol", "Subscription shares rounded up by one",
     "uint256 minted = Math.mulDiv(Math.mulDiv(e.depositAssets * assetScale, ONE, nav), ONE, mult);",
     "uint256 minted = Math.mulDiv(Math.mulDiv(e.depositAssets * assetScale, ONE, nav), ONE, mult) + 1;"),
    ("M07", "src/actions/DistributionModule.sol", "Eligible share count not reduced when shares leave",
     "        _debt[account] = _debtFor(balanceNow);\n        eligibleShares -= shares;",
     "        _debt[account] = _debtFor(balanceNow);"),
    ("M08", "src/actions/DistributionModule.sol", "New shares earn distributions declared before they existed",
     "        _debt[account] = _debtFor(balanceNow);\n        eligibleShares += shares;",
     "        eligibleShares += shares;"),
    ("M09", "src/compliance/modules/MaxHoldersModule.sol", "Self-transfer double-counts a holder",
     "        if (shares == 0 || from == to) return;\n        _left(from);",
     "        if (shares == 0) return;\n        _left(from);"),
    ("M10", "src/vault/FundVault.sol", "Partly filled redemption returns all shares as well as the cash",
     "Math.mulDiv(req, e.redeemShares - e.redeemSharesFilled, e.redeemShares);",
     "Math.mulDiv(req, e.redeemShares, e.redeemShares);"),
    ("M11", "src/token/FundShareToken.sol", "Forced transfer can deliver to an unverified wallet",
     "    function forcedTransfer(address from, address to, uint256 shares) external onlyRole(AGENT_ROLE) {\n        _requireReceiverIdentity(to);",
     "    function forcedTransfer(address from, address to, uint256 shares) external onlyRole(AGENT_ROLE) {"),
    ("M12", "src/oracle/NavOracle.sol", "Deviation band disabled: one poster can reprice the fund",
     "if (deviationBps > maxDeviationBps) {", "if (false) {"),
    ("M13", "src/token/FundShareToken.sol", "Mint skips the compliance modules",
     "if (!compliance.canTransfer(address(0), to, shares)) revert ComplianceRejected(address(0), to, shares);", ""),
    ("M14", "src/vault/FundVault.sol", "Redemption gate not applied",
     "if (filled > gate) filled = gate;", ""),
    ("M15", "src/actions/DistributionModule.sol", "Distribution paid to an unverified holder",
     "if (!token.identityRegistry().isVerified(holder)) revert HolderNotVerified(holder);", ""),
    ("M16", "src/vault/FundVault.sol", "Anyone can claim another investor's shares",
     "    function claimDeposit(address receiver, address controller) external nonReentrant returns (uint256 shares) {\n        _auth(controller);",
     "    function claimDeposit(address receiver, address controller) external nonReentrant returns (uint256 shares) {"),
    ("M17", "src/vault/FundVault.sol", "Distribution guard always reports no epoch awaiting its NAV",
     "return id > 1 && epochs[id - 1].settledAt == 0;", "return false;"),
    ("M18", "src/token/FundShareToken.sol", "Partially frozen shares can be transferred",
     "uint256 available = _shares[from] - frozenShares[from];\n        if (shares > available)",
     "uint256 available = _shares[from];\n        if (shares > available)"),
    ("M19", "src/bridge/CrossChainGateway.sol", "Gateway accepts messages from any sender on a known chain",
     "if (peers[srcChain] == bytes32(0) || peers[srcChain] != srcGateway) {", "if (peers[srcChain] == bytes32(0)) {"),
    ("M20", "src/bridge/CrossChainGateway.sol", "Inbound mint limit not enforced",
     "} else if (shares > _room(inboundLimit, inboundUsed)) {", "} else if (false) {"),
    ("M21", "src/bridge/CrossChainGateway.sol", "Bridging out does not burn the shares",
     "        token.burnShares(shares);\n", ""),
    ("M22", "src/bridge/CrossChainGateway.sol", "Returning parked shares leaves them parked as well",
     "        parked[recipient] = 0;\n        totalParked -= shares;\n        sentTo[dstChain] += shares;",
     "        sentTo[dstChain] += shares;"),
    ("M23", "script/Deploy.s.sol", "Deployer keeps admin rights on the token after deployment",
     "        d.token.renounceRole(adminRole, deployer);", ""),
    ("M24", "src/actions/DistributionModule.sol", "Distribution starting point rounded down (over-promises by dust)",
     "return Math.mulDiv(balance, accPerShare, PRECISION, Math.Rounding.Ceil);",
     "return Math.mulDiv(balance, accPerShare, PRECISION);"),
    ("M25", "src/bridge/CrossChainGateway.sol", "A failed destination mint reverts the message instead of parking",
     "        try token.mintShares(recipient, shares) {\n            return true;\n        } catch {\n            return false;\n        }",
     "        token.mintShares(recipient, shares);\n        return true;"),
]


def forge_test(*extra):
    proc = subprocess.run(
        ["forge", "test", *extra], cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace"
    )
    out = proc.stdout + proc.stderr
    # Greedy on purpose: a fuzz counterexample contains brackets of its own.
    failed = re.findall(r"^\[FAIL.*\]\s+(\w+)\(", out, re.M)
    compile_error = "Compiler run failed" in out or "Error (" in out
    return proc.returncode, failed, compile_error


def run_tests():
    """The exit code decides the verdict. `--fail-fast` is quick but can stop before it prints the name
    of the failing test, so when that happens the suite is run once more in full to get the name."""
    code, failed, compile_error = forge_test("--fail-fast")
    if code != 0 and not failed and not compile_error:
        _, failed, _ = forge_test()
    return code, failed, compile_error


def main():
    wanted = set(sys.argv[1:])
    rows = []
    for mid, rel, desc, original, mutated in MUTATIONS:
        if wanted and mid not in wanted:
            continue
        path = ROOT / rel
        source = path.read_text(encoding="utf-8")
        if source.count(original) != 1:
            rows.append((mid, desc, "NOT APPLIED", "pattern not found exactly once"))
            print(mid, "pattern not found exactly once")
            continue
        try:
            path.write_text(source.replace(original, mutated), encoding="utf-8", newline="\n")
            code, failed, compile_error = run_tests()
        finally:
            path.write_text(source, encoding="utf-8", newline="\n")
        if compile_error:
            verdict, by = "COMPILE ERROR", ""
        elif code != 0:
            verdict, by = "CAUGHT", failed[0] if failed else "(name not captured)"
        else:
            verdict, by = "SURVIVED", ""
        rows.append((mid, desc, verdict, by))
        print(mid, verdict, by, flush=True)

    caught = sum(1 for r in rows if r[2] == "CAUGHT")
    lines = [
        "# Mutation check results",
        "",
        "Each row is a bug injected into the contracts on purpose. CAUGHT means the test suite failed, and",
        "names the first test that failed. Regenerate with `python tools/mutation_check.py`.",
        "",
        f"**{caught} of {len(rows)} injected bugs caught.**",
        "",
        "| Id | Injected bug | Result | First failing test |",
        "|---|---|---|---|",
    ]
    lines += [f"| {m} | {d} | {v} | `{b}` |" if b else f"| {m} | {d} | {v} | |" for m, d, v, b in rows]
    if not wanted:
        (ROOT / "docs" / "MUTATION-RESULTS.md").write_text("\n".join(lines) + "\n", encoding="utf-8", newline="\n")
    return 0 if caught == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main())
