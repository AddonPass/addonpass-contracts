// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { StdInvariant } from "forge-std/StdInvariant.sol";
import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddonPassV1 } from "../../src/AddonPassV1.sol";
import { MockUSDC } from "../mocks/MockUSDC.sol";

contract AddonPassHandler is Test {
    address internal constant OWNER = address(0x1001);
    address internal constant TREASURY = address(0x1002);
    address internal constant DEVELOPER = address(0x2001);
    address internal constant PAYER = address(0x3001);
    uint96 internal constant PLAN_PRICE = 10e6;

    AddonPassV1 internal immutable addonPass;
    MockUSDC internal immutable usdc;
    uint256 internal immutable planId;
    uint256 internal entitlementNonce;

    constructor(AddonPassV1 addonPass_, MockUSDC usdc_) {
        addonPass = addonPass_;
        usdc = usdc_;

        vm.prank(DEVELOPER);
        addonPass.registerDeveloper(DEVELOPER);
        vm.prank(DEVELOPER);
        planId = addonPass.createPlan(PLAN_PRICE, 30 days, keccak256("invariant-plan"));

        vm.prank(PAYER);
        usdc.approve(address(addonPass), type(uint256).max);
    }

    function subscribe(uint32 rawMaxCharges) external {
        uint32 maxCharges = uint32(bound(rawMaxCharges, 1, 12));
        usdc.mint(PAYER, PLAN_PRICE);
        bytes32 entitlementHash = keccak256(abi.encode("entitlement", ++entitlementNonce));

        vm.prank(PAYER);
        addonPass.subscribe(planId, entitlementHash, maxCharges);
    }

    function renew(uint256 rawSubscriptionId, uint32 rawDelay) external {
        uint256 subscriptionId = _subscriptionId(rawSubscriptionId);
        if (subscriptionId == 0) return;
        (,,, uint64 paidThrough, uint32 remainingCharges, bool cancelled) =
            addonPass.subscriptions(subscriptionId);
        if (cancelled || remainingCharges == 0) return;

        uint256 latestChargeTime = uint256(paidThrough) + addonPass.CUSTOMER_GRACE();
        if (block.timestamp > latestChargeTime) return;
        uint256 chargeTime = uint256(paidThrough) + bound(rawDelay, 0, addonPass.CUSTOMER_GRACE());
        vm.warp(chargeTime);
        usdc.mint(PAYER, PLAN_PRICE);
        addonPass.tryCharge(subscriptionId);
    }

    function cancel(uint256 rawSubscriptionId) external {
        uint256 subscriptionId = _subscriptionId(rawSubscriptionId);
        if (subscriptionId == 0) return;
        (,,,,, bool cancelled) = addonPass.subscriptions(subscriptionId);
        if (cancelled) return;

        vm.prank(PAYER);
        addonPass.cancel(subscriptionId);
    }

    function resume(uint256 rawSubscriptionId, uint32 rawMaxCharges) external {
        uint256 subscriptionId = _subscriptionId(rawSubscriptionId);
        if (subscriptionId == 0) return;
        (,,, uint64 paidThrough,, bool cancelled) = addonPass.subscriptions(subscriptionId);
        uint256 resumableAt =
            cancelled ? paidThrough : uint256(paidThrough) + addonPass.CUSTOMER_GRACE();
        if (block.timestamp <= resumableAt) vm.warp(resumableAt + 1);

        usdc.mint(PAYER, PLAN_PRICE);
        vm.prank(PAYER);
        addonPass.resume(subscriptionId, uint32(bound(rawMaxCharges, 1, 12)));
    }

    function rotate(uint256 rawSubscriptionId) external {
        uint256 subscriptionId = _subscriptionId(rawSubscriptionId);
        if (subscriptionId == 0) return;
        bytes32 replacementHash = keccak256(abi.encode("rotation", ++entitlementNonce));

        vm.prank(PAYER);
        addonPass.rotateEntitlement(subscriptionId, replacementHash);
    }

    function activateTierFromBalance(uint8 rawTier) external {
        AddonPassV1.Tier tier = rawTier % 2 == 0 ? AddonPassV1.Tier.Pro : AddonPassV1.Tier.Studio;
        uint256 price =
            tier == AddonPassV1.Tier.Pro ? addonPass.PRO_PRICE() : addonPass.STUDIO_PRICE();
        if (addonPass.developerClaimable(DEVELOPER) < price) return;

        vm.prank(DEVELOPER);
        addonPass.activateTierFromOperatingBalance(tier);
    }

    function withdrawDeveloper(uint256 rawAmount) external {
        uint256 claimable = addonPass.developerClaimable(DEVELOPER);
        if (claimable == 0) return;

        vm.prank(DEVELOPER);
        addonPass.withdrawDeveloper(bound(rawAmount, 1, claimable));
    }

    function withdrawPlatform(uint256 rawAmount) external {
        uint256 claimable = addonPass.platformClaimable();
        if (claimable == 0) return;

        vm.prank(TREASURY);
        addonPass.withdrawPlatform(bound(rawAmount, 1, claimable));
    }

    function addAndSweepSurplus(uint256 rawAmount) external {
        uint256 amount = bound(rawAmount, 1, 1_000_000e6);
        usdc.mint(address(addonPass), amount);

        vm.prank(OWNER);
        addonPass.sweepSurplus(amount);
    }

    function _subscriptionId(uint256 rawSubscriptionId) private view returns (uint256) {
        uint256 nextSubscriptionId = addonPass.nextSubscriptionId();
        if (nextSubscriptionId == 1) return 0;
        return bound(rawSubscriptionId, 1, nextSubscriptionId - 1);
    }
}

contract AddonPassInvariantTest is StdInvariant, Test {
    address private constant OWNER = address(0x1001);
    address private constant TREASURY = address(0x1002);
    address private constant GUARDIAN = address(0x1003);
    address private constant DEVELOPER = address(0x2001);

    MockUSDC private usdc;
    AddonPassV1 private addonPass;
    AddonPassHandler private handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        usdc = new MockUSDC();
        addonPass = new AddonPassV1(
            IERC20(address(usdc)), OWNER, TREASURY, GUARDIAN, 1e6, 1_000e6, 12, 2
        );
        handler = new AddonPassHandler(addonPass, usdc);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = AddonPassHandler.subscribe.selector;
        selectors[1] = AddonPassHandler.renew.selector;
        selectors[2] = AddonPassHandler.cancel.selector;
        selectors[3] = AddonPassHandler.resume.selector;
        selectors[4] = AddonPassHandler.rotate.selector;
        selectors[5] = AddonPassHandler.activateTierFromBalance.selector;
        selectors[6] = AddonPassHandler.withdrawDeveloper.selector;
        selectors[7] = AddonPassHandler.withdrawPlatform.selector;
        selectors[8] = AddonPassHandler.addAndSweepSurplus.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({ addr: address(handler), selectors: selectors }));
    }

    function invariantBalanceCoversEveryLiability() public view {
        assertGe(usdc.balanceOf(address(addonPass)), addonPass.totalLiabilities());
    }

    function invariantAggregateLiabilitiesRemainSegregated() public view {
        assertEq(
            addonPass.totalLiabilities(),
            addonPass.totalDeveloperLiability() + addonPass.platformClaimable()
        );
        assertEq(addonPass.totalDeveloperLiability(), addonPass.developerClaimable(DEVELOPER));
    }

    function invariantEntitlementHashesResolveToTheirSubscription() public view {
        uint256 nextSubscriptionId = addonPass.nextSubscriptionId();
        for (uint256 subscriptionId = 1; subscriptionId < nextSubscriptionId; ++subscriptionId) {
            (,, bytes32 entitlementHash,,,) = addonPass.subscriptions(subscriptionId);
            assertEq(addonPass.subscriptionByEntitlementHash(entitlementHash), subscriptionId);
        }
    }
}
