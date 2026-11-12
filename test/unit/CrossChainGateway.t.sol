// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {ModularCompliance} from "../../src/compliance/ModularCompliance.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {CrossChainGateway, IMessenger} from "../../src/bridge/CrossChainGateway.sol";
import {MockMessenger} from "../../src/mocks/MockMessenger.sol";

/// @notice Chain A is the home chain from `Base` (vault, oracle, investors). Chain B is a second
///         deployment of registry, compliance and token with its own investor register.
contract CrossChainGatewayTest is Base {
    uint32 internal constant CHAIN_A = 1;
    uint32 internal constant CHAIN_B = 2;

    MockMessenger internal messenger;
    CrossChainGateway internal gatewayA;
    CrossChainGateway internal gatewayB;

    IdentityRegistry internal registryB;
    ModularCompliance internal complianceB;
    MaxHoldersModule internal holdersB;
    FundShareToken internal tokenB;

    uint256 internal constant LIMIT = 1_000_000e18;

    function setUp() public override {
        super.setUp();
        messenger = new MockMessenger();

        vm.startPrank(admin);
        registryB = new IdentityRegistry(admin);
        complianceB = new ModularCompliance(admin);
        tokenB = new FundShareToken("Example Treasury Fund", "xTF", admin, registryB, complianceB);
        complianceB.bindToken(address(tokenB));
        holdersB = new MaxHoldersModule(address(complianceB), tokenB, admin, 100);
        complianceB.addModule(holdersB);
        registryB.grantRole(registryB.AGENT_ROLE(), agent);
        tokenB.grantRole(tokenB.AGENT_ROLE(), agent);

        gatewayA = new CrossChainGateway(admin, token, IMessenger(address(messenger)), LIMIT, LIMIT);
        gatewayB = new CrossChainGateway(admin, tokenB, IMessenger(address(messenger)), LIMIT, LIMIT);
        gatewayA.setPeer(CHAIN_B, _b32(address(gatewayB)));
        gatewayB.setPeer(CHAIN_A, _b32(address(gatewayA)));
        gatewayA.grantRole(gatewayA.AGENT_ROLE(), agent);
        gatewayB.grantRole(gatewayB.AGENT_ROLE(), agent);

        token.grantRole(token.MINTER_ROLE(), address(gatewayA));
        token.setSystemAddress(address(gatewayA), true);
        tokenB.grantRole(tokenB.MINTER_ROLE(), address(gatewayB));
        tokenB.setSystemAddress(address(gatewayB), true);
        vm.stopPrank();

        messenger.register(address(gatewayA), CHAIN_A);
        messenger.register(address(gatewayB), CHAIN_B);

        _fund(alice, 10_000 * USDC_UNIT, NAV_ONE);
        _fund(bob, 10_000 * USDC_UNIT, NAV_ONE);
        _verifyB(alice);

        address[3] memory users = [alice, bob, carol];
        for (uint256 i; i < users.length; ++i) {
            vm.startPrank(users[i]);
            token.approve(address(gatewayA), type(uint256).max);
            tokenB.approve(address(gatewayB), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _verifyB(address who) internal {
        vm.prank(agent);
        registryB.registerIdentity(who, DE, 1, uint64(block.timestamp + 365 days));
    }

    function _globalShares() internal view returns (uint256) {
        return token.totalShares() + tokenB.totalShares() + gatewayA.totalParked() + gatewayB.totalParked();
    }

    // ------------------------------------------------------------------ happy path

    function test_bridge_burnsHere_mintsThere() public {
        uint256 before = _globalShares();
        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 4_000e18);

        assertEq(token.balanceOf(alice), 6_000e18);
        assertEq(tokenB.balanceOf(alice), 4_000e18);
        assertEq(token.totalSupply(), 16_000e18);
        assertEq(_globalShares(), before, "supply across chains changed");
    }

    function test_bridge_roundTrip() public {
        vm.startPrank(alice);
        gatewayA.bridge(CHAIN_B, alice, 4_000e18);
        gatewayB.bridge(CHAIN_A, alice, 4_000e18);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 10_000e18);
        assertEq(tokenB.totalSupply(), 0);
    }

    // ------------------------------------------------------------------ compliance on arrival

    /// bob is verified on chain A only. His shares must not appear in his wallet on chain B.
    function test_bridge_toIneligibleRecipient_parksInsteadOfMinting() public {
        uint256 before = _globalShares();
        vm.prank(bob);
        gatewayA.bridge(CHAIN_B, bob, 1_000e18);

        assertEq(tokenB.balanceOf(bob), 0, "unverified wallet received shares on the destination");
        assertEq(gatewayB.parked(bob), 1_000e18);
        assertEq(_globalShares(), before, "value was lost in transit");
    }

    function test_parked_claimableOnceVerified() public {
        vm.prank(bob);
        gatewayA.bridge(CHAIN_B, bob, 1_000e18);

        vm.expectRevert(); // still not eligible
        gatewayB.claimParked(bob);

        _verifyB(bob);
        gatewayB.claimParked(bob); // anyone can trigger it; bob is credited
        assertEq(tokenB.balanceOf(bob), 1_000e18);
        assertEq(gatewayB.parked(bob), 0);
    }

    function test_parked_agentCanReturnToSource() public {
        vm.prank(bob);
        gatewayA.bridge(CHAIN_B, bob, 1_000e18);
        vm.prank(agent);
        gatewayB.returnParked(bob, CHAIN_A, bob);

        assertEq(token.balanceOf(bob), 10_000e18);
        assertEq(gatewayB.totalParked(), 0);
    }

    function test_bridge_destinationHolderCapAlsoParks() public {
        _verifyB(bob);
        vm.prank(admin);
        holdersB.setMaxHolders(1);
        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18); // takes the only slot
        vm.prank(bob);
        gatewayA.bridge(CHAIN_B, bob, 1_000e18);

        assertEq(tokenB.balanceOf(bob), 0);
        assertEq(gatewayB.parked(bob), 1_000e18);
    }

    function test_bridge_frozenHolderCannotLeave() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.WalletFrozen.selector, alice));
        gatewayA.bridge(CHAIN_B, alice, 1_000e18);
    }

    // ------------------------------------------------------------------ split safety

    /// Amounts travel as base shares, so a split applied on one chain first does not change the stake.
    function test_bridge_acrossUnsyncedSplit_keepsTheStake() public {
        vm.prank(issuer);
        actions.split(2, 1); // chain A only
        uint256 sharesBefore = token.sharesOf(alice);

        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 8_000e18); // 8,000 post-split tokens = 4,000 base shares

        assertEq(tokenB.sharesOf(alice), 4_000e18);
        assertEq(token.sharesOf(alice) + tokenB.sharesOf(alice), sharesBefore);
    }

    // ------------------------------------------------------------------ transport is not trusted

    function test_receive_onlyFromMessenger() public {
        vm.prank(mallory);
        vm.expectRevert(CrossChainGateway.OnlyMessenger.selector);
        gatewayB.receiveMessage(CHAIN_A, _b32(address(gatewayA)), abi.encode(mallory, 1e18));
    }

    function test_receive_fromUnknownPeer_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainGateway.UntrustedSender.selector, CHAIN_A, _b32(mallory))
        );
        messenger.forge(address(gatewayB), CHAIN_A, _b32(mallory), abi.encode(alice, 1e18));

        vm.expectRevert(
            abi.encodeWithSelector(CrossChainGateway.UntrustedSender.selector, uint32(99), _b32(address(gatewayA)))
        );
        messenger.forge(address(gatewayB), 99, _b32(address(gatewayA)), abi.encode(alice, 1e18));
    }

    /// A compromised transport forging messages from the real peer can mint at most one window's limit.
    function test_compromisedMessenger_isBoundedByInboundLimit() public {
        bytes32 peer = _b32(address(gatewayA));
        messenger.forge(address(gatewayB), CHAIN_A, peer, abi.encode(alice, LIMIT));
        messenger.forge(address(gatewayB), CHAIN_A, peer, abi.encode(alice, LIMIT));
        messenger.forge(address(gatewayB), CHAIN_A, peer, abi.encode(alice, 5e18));

        assertEq(tokenB.sharesOf(alice), LIMIT, "minted more than the window allows");
        assertEq(gatewayB.parked(alice), LIMIT + 5e18);

        vm.prank(agent);
        gatewayB.pause();
        vm.expectRevert();
        gatewayB.claimParked(alice);
    }

    function test_paused_inboundIsParkedNotLost() public {
        vm.prank(agent);
        gatewayB.pause();
        uint256 before = _globalShares();
        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18);
        assertEq(gatewayB.parked(alice), 1_000e18);
        assertEq(_globalShares(), before);
    }

    function test_outboundLimit() public {
        vm.prank(admin);
        gatewayA.setLimits(1_500e18, LIMIT, 1 days);
        vm.startPrank(alice);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18);
        vm.expectRevert(
            abi.encodeWithSelector(CrossChainGateway.OutboundLimitExceeded.selector, 500e18, 1_000e18)
        );
        gatewayA.bridge(CHAIN_B, alice, 1_000e18);
        skip(1 days);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18); // new window
        vm.stopPrank();
    }

    function test_loweringLimitBelowUsage_doesNotBreakInbound() public {
        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18);
        vm.prank(admin);
        gatewayB.setLimits(LIMIT, 10e18, 1 days); // below the 1,000 already received this window
        vm.prank(alice);
        gatewayA.bridge(CHAIN_B, alice, 1_000e18); // must not revert
        assertEq(gatewayB.parked(alice), 1_000e18);
    }

    function test_bridge_toUnknownChain_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(CrossChainGateway.UnknownPeer.selector, uint32(7)));
        gatewayA.bridge(7, alice, 1e18);
    }

    // ------------------------------------------------------------------ fuzz

    /// Any sequence of bridges in both directions, with recipients gaining and losing eligibility,
    /// leaves the number of shares across both chains (plus parked) unchanged.
    function testFuzz_globalSupplyIsConserved(uint256[12] memory amounts, uint8[12] memory kinds) public {
        address[3] memory users = [alice, bob, carol];
        _fund(carol, 10_000 * USDC_UNIT, NAV_ONE);
        uint256 start = _globalShares();

        for (uint256 i; i < amounts.length; ++i) {
            address who = users[kinds[i] % 3];
            uint8 action = (kinds[i] / 3) % 5;

            // Snapshot chain B before the step: an ineligible wallet's balance there must not grow.
            uint256[3] memory before;
            bool[3] memory eligible;
            for (uint256 u; u < 3; ++u) {
                before[u] = tokenB.sharesOf(users[u]);
                eligible[u] = registryB.isVerified(users[u]);
            }

            if (action == 0) {
                uint256 bal = token.balanceOf(who);
                if (bal == 0) continue;
                vm.prank(who);
                try gatewayA.bridge(CHAIN_B, who, bound(amounts[i], 1, bal)) {} catch {}
            } else if (action == 1) {
                uint256 bal = tokenB.balanceOf(who);
                if (bal == 0) continue;
                vm.prank(who);
                try gatewayB.bridge(CHAIN_A, who, bound(amounts[i], 1, bal)) {} catch {}
            } else if (action == 2) {
                _verifyB(who);
            } else if (action == 3) {
                if (registryB.isVerified(who)) {
                    vm.prank(agent);
                    registryB.removeIdentity(who);
                }
            } else {
                try gatewayB.claimParked(who) {} catch {}
            }

            assertEq(_globalShares(), start, "shares created or destroyed by bridging");
            for (uint256 u; u < 3; ++u) {
                if (!eligible[u]) {
                    assertLe(tokenB.sharesOf(users[u]), before[u], "ineligible wallet was credited on chain B");
                }
            }
        }
    }
}
