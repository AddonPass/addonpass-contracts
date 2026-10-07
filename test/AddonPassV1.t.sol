// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddonPassV1 } from "../src/AddonPassV1.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";

contract AddonPassV1Test is Test {
    uint256 private constant PAYER_KEY = 0xA11CE;
    uint256 private constant SECOND_PAYER_KEY = 0xB0B;

    address private constant OWNER = address(0x1001);
    address private constant TREASURY = address(0x1002);
    address private constant GUARDIAN = address(0x1003);
    address private constant DEVELOPER = address(0x2001);
    address private constant PAYOUT = address(0x2002);
    address private constant OTHER = address(0x3001);

    uint96 private constant MIN_PLAN_PRICE = 1e6;
    uint96 private constant MAX_PLAN_PRICE = 1_000e6;
    uint96 private constant PLAN_PRICE = 5e6;
    uint32 private constant MONTHLY_PERIOD = 30 days;
    bytes32 private constant METADATA_HASH = keccak256("plan-metadata");
    bytes32 private constant ENTITLEMENT_HASH = keccak256("entitlement-one");

    MockUSDC private usdc;
    AddonPassV1 private addonPass;
    address private payer;
    address private secondPayer;

    function setUp() public {
        vm.warp(1_800_000_000);
        payer = vm.addr(PAYER_KEY);
        secondPayer = vm.addr(SECOND_PAYER_KEY);
        usdc = new MockUSDC();
        addonPass = new AddonPassV1(
            IERC20(address(usdc)), OWNER, TREASURY, GUARDIAN, MIN_PLAN_PRICE, MAX_PLAN_PRICE, 12, 1
        );
    }

    function testRegisterDeveloperAndCreateImmutablePlan() public {
        vm.prank(DEVELOPER);
        addonPass.registerDeveloper(PAYOUT);

        (
            address payoutWallet,
            AddonPassV1.Tier selectedTier,
            uint64 tierPaidThrough,
            bool autoRenewTier,
            bool newSalesEnabled,
            bool renewalsEnabled,
            bool registered
        ) = addonPass.developers(DEVELOPER);
        assertEq(payoutWallet, PAYOUT);
        assertEq(uint8(selectedTier), uint8(AddonPassV1.Tier.Free));
        assertEq(tierPaidThrough, 0);
        assertFalse(autoRenewTier);
        assertTrue(newSalesEnabled);
        assertTrue(renewalsEnabled);
        assertTrue(registered);

        vm.prank(DEVELOPER);
        uint256 planId = addonPass.createPlan(PLAN_PRICE, MONTHLY_PERIOD, METADATA_HASH);

        (
            address planDeveloper,
            uint96 price,
            uint32 period,
            bytes32 metadataHash,
            bool planSalesEnabled,
            bool planRenewalsEnabled
        ) = addonPass.plans(planId);
        assertEq(planDeveloper, DEVELOPER);
        assertEq(price, PLAN_PRICE);
        assertEq(period, MONTHLY_PERIOD);
        assertEq(metadataHash, METADATA_HASH);
        assertTrue(planSalesEnabled);
        assertTrue(planRenewalsEnabled);

        vm.expectRevert(AddonPassV1.AlreadyRegistered.selector);
        vm.prank(DEVELOPER);
        addonPass.registerDeveloper(PAYOUT);
    }

    function testRejectsMinimumPriceTheFreeFeeWouldConsume() public {
        vm.expectRevert(AddonPassV1.InvalidConfiguration.selector);
        new AddonPassV1(
            IERC20(address(usdc)), OWNER, TREASURY, GUARDIAN, 0.105e6, MAX_PLAN_PRICE, 12, 1
        );

        new AddonPassV1(
            IERC20(address(usdc)), OWNER, TREASURY, GUARDIAN, 0.106e6, MAX_PLAN_PRICE, 12, 1
        );
    }

    function testPlanValidationAndOwnership() public {
        _registerDeveloper();

        vm.expectRevert(AddonPassV1.InvalidPlanPrice.selector);
        vm.prank(DEVELOPER);
        addonPass.createPlan(MIN_PLAN_PRICE - 1, MONTHLY_PERIOD, METADATA_HASH);

        vm.expectRevert(AddonPassV1.InvalidPeriod.selector);
        vm.prank(DEVELOPER);
        addonPass.createPlan(PLAN_PRICE, 31 days, METADATA_HASH);

        uint256 planId = _createPlan(PLAN_PRICE, MONTHLY_PERIOD);
        vm.expectRevert(AddonPassV1.NotPlanDeveloper.selector);
        vm.prank(OTHER);
        addonPass.setPlanSalesEnabled(planId, false);
    }

    function testAuthorizationCapsAreEnforcedByPeriod() public {
        _registerDeveloper();
        uint256 monthlyPlanId = _createPlan(PLAN_PRICE, MONTHLY_PERIOD);
        uint256 annualPlanId = _createPlan(PLAN_PRICE, 365 days);
        _approve(payer, PLAN_PRICE * 20);

        vm.expectRevert(AddonPassV1.AuthorizationLimitExceeded.selector);
        vm.prank(payer);
        addonPass.subscribe(monthlyPlanId, ENTITLEMENT_HASH, 13);

        vm.expectRevert(AddonPassV1.AuthorizationLimitExceeded.selector);
        vm.prank(payer);
        addonPass.subscribe(annualPlanId, ENTITLEMENT_HASH, 2);
    }

    function testAnnualAuthorizationRequiresAnotherExplicitPurchase() public {
        _registerDeveloper();
        uint256 planId = _createPlan(PLAN_PRICE, 365 days);
        _approve(payer, PLAN_PRICE * 2);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        (,,, uint64 firstPaidThrough, uint32 remainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(remainingCharges, 0);

        vm.warp(firstPaidThrough);
        vm.expectRevert(AddonPassV1.AuthorizationLimitExceeded.selector);
        addonPass.tryCharge(subscriptionId);
        vm.prank(payer);
        addonPass.resume(subscriptionId, 1);
        (,,, uint64 secondPaidThrough, uint32 nextRemainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(secondPaidThrough, firstPaidThrough + 365 days);
        assertEq(nextRemainingCharges, 0);
        assertEq(usdc.balanceOf(payer), 0);
    }

    function testDeveloperPlanControlsStopOnlyFutureSettlement() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(DEVELOPER);
        addonPass.setPlanSalesEnabled(planId, false);

        vm.expectRevert(AddonPassV1.NotRenewable.selector);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);

        vm.prank(DEVELOPER);
        addonPass.setPlanSalesEnabled(planId, true);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 paidThrough,,) = addonPass.subscriptions(subscriptionId);

        vm.prank(DEVELOPER);
        addonPass.setPlanRenewalsEnabled(planId, false);
        vm.warp(paidThrough);
        (bool entitledAtPaidThrough,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitledAtPaidThrough);

        vm.expectRevert(AddonPassV1.NotRenewable.selector);
        addonPass.tryCharge(subscriptionId);
        vm.warp(paidThrough + 1);
        (bool entitledInGrace,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertFalse(entitledInGrace);
    }

    function testOneTimePlanChargesOnceAndNeverExpires() public {
        _registerDeveloper();
        uint256 planId = _createPlan(PLAN_PRICE, addonPass.ONE_TIME_PERIOD());
        _approve(payer, PLAN_PRICE * 2);

        vm.expectRevert(AddonPassV1.AuthorizationLimitExceeded.selector);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 2);

        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        (,,, uint64 paidThrough, uint32 remainingCharges,) = addonPass.subscriptions(subscriptionId);
        assertEq(paidThrough, addonPass.ONE_TIME_PAID_THROUGH());
        assertEq(remainingCharges, 0);
        assertEq(addonPass.developerClaimable(DEVELOPER), 4_650_000);

        vm.warp(block.timestamp + 100 * 365 days);
        (bool entitled,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitled);

        vm.expectRevert(AddonPassV1.AuthorizationLimitExceeded.selector);
        addonPass.tryCharge(subscriptionId);

        vm.startPrank(payer);
        vm.expectRevert(AddonPassV1.OneTimePurchase.selector);
        addonPass.cancel(subscriptionId);
        vm.expectRevert(AddonPassV1.OneTimePurchase.selector);
        addonPass.resume(subscriptionId, 1);
        vm.stopPrank();
        assertEq(usdc.balanceOf(payer), PLAN_PRICE);
    }

    function testSubscribeSettlesFreeTierAndCreatesEntitlement() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);

        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);

        assertEq(subscriptionId, 1);
        assertEq(usdc.balanceOf(address(addonPass)), PLAN_PRICE);
        assertEq(addonPass.developerClaimable(DEVELOPER), 4_650_000);
        assertEq(addonPass.platformClaimable(), 350_000);
        assertEq(addonPass.totalDeveloperLiability(), 4_650_000);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE);
        assertEq(addonPass.lifetimeGrossVolume(), PLAN_PRICE);
        assertEq(addonPass.lifetimeTransactionFees(), 350_000);

        (
            uint256 storedPlanId,
            address storedPayer,
            bytes32 storedEntitlementHash,
            uint64 paidThrough,
            uint32 remainingCharges,
            bool cancelled
        ) = addonPass.subscriptions(subscriptionId);
        assertEq(storedPlanId, planId);
        assertEq(storedPayer, payer);
        assertEq(storedEntitlementHash, ENTITLEMENT_HASH);
        assertEq(paidThrough, block.timestamp + addonPass.MONTHLY_PERIOD());
        assertEq(remainingCharges, 11);
        assertFalse(cancelled);

        (
            bool entitled,
            uint64 entitlementPaidThrough,
            uint64 graceEnds,
            uint256 entitlementSubscriptionId,
            address entitlementDeveloper
        ) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitled);
        assertEq(entitlementPaidThrough, paidThrough);
        assertEq(graceEnds, paidThrough + addonPass.CUSTOMER_GRACE());
        assertEq(entitlementSubscriptionId, subscriptionId);
        assertEq(entitlementDeveloper, DEVELOPER);
    }

    function testRenewalSettlesOncePerPeriod() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 firstPaidThrough,,) = addonPass.subscriptions(subscriptionId);

        vm.warp(firstPaidThrough);
        assertTrue(addonPass.tryCharge(subscriptionId));

        (,,, uint64 renewedPaidThrough, uint32 remainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(renewedPaidThrough, firstPaidThrough + addonPass.MONTHLY_PERIOD());
        assertEq(remainingCharges, 10);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE * 2);

        vm.expectRevert(AddonPassV1.NotDue.selector);
        addonPass.tryCharge(subscriptionId);
    }

    function testRenewalTransferFailureChangesNoFinancialOrEntitlementState() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 paidThrough, uint32 remainingCharges,) = addonPass.subscriptions(subscriptionId);
        uint256 liabilities = addonPass.totalLiabilities();

        vm.warp(paidThrough);
        usdc.setTransferFromShouldFail(true);
        assertFalse(addonPass.tryCharge(subscriptionId));

        (,,, uint64 unchangedPaidThrough, uint32 unchangedRemainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(unchangedPaidThrough, paidThrough);
        assertEq(unchangedRemainingCharges, remainingCharges);
        assertEq(addonPass.totalLiabilities(), liabilities);
    }

    function testRenewalRecoversAfterBalanceAndAllowanceAreRestored() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 paidThrough, uint32 remainingCharges,) = addonPass.subscriptions(subscriptionId);
        uint256 liabilities = addonPass.totalLiabilities();
        uint256 balance = usdc.balanceOf(payer);
        vm.prank(payer);
        usdc.transfer(OTHER, balance);

        vm.warp(paidThrough);
        assertFalse(addonPass.tryCharge(subscriptionId));
        usdc.mint(payer, PLAN_PRICE);
        vm.prank(payer);
        usdc.approve(address(addonPass), 0);
        assertFalse(addonPass.tryCharge(subscriptionId));

        (,,, uint64 unchangedPaidThrough, uint32 unchangedRemainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(unchangedPaidThrough, paidThrough);
        assertEq(unchangedRemainingCharges, remainingCharges);
        assertEq(addonPass.totalLiabilities(), liabilities);

        vm.prank(payer);
        usdc.approve(address(addonPass), PLAN_PRICE);
        assertTrue(addonPass.tryCharge(subscriptionId));
        (,,, uint64 renewedPaidThrough, uint32 renewedRemainingCharges,) =
            addonPass.subscriptions(subscriptionId);
        assertEq(renewedPaidThrough, paidThrough + MONTHLY_PERIOD);
        assertEq(renewedRemainingCharges, remainingCharges - 1);
        assertEq(addonPass.totalLiabilities(), liabilities + PLAN_PRICE);
    }

    function testCancellationStopsChargesButPreservesPaidAccess() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 paidThrough,,) = addonPass.subscriptions(subscriptionId);

        vm.prank(payer);
        addonPass.cancel(subscriptionId);
        vm.warp(paidThrough);
        (bool entitledAtPaidThrough,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitledAtPaidThrough);

        vm.warp(paidThrough + 1);
        (bool entitledInUnpaidGrace,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertFalse(entitledInUnpaidGrace);

        vm.expectRevert(AddonPassV1.AlreadyCancelled.selector);
        addonPass.tryCharge(subscriptionId);
    }

    function testExpiredSubscriptionCanResumeWithoutBackBilling() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        (,,, uint64 originalPaidThrough,,) = addonPass.subscriptions(subscriptionId);
        vm.warp(originalPaidThrough + addonPass.CUSTOMER_GRACE() + 1);

        usdc.mint(payer, PLAN_PRICE);
        vm.prank(payer);
        usdc.approve(address(addonPass), PLAN_PRICE * 3);
        uint256 resumeTime = block.timestamp;
        vm.prank(payer);
        addonPass.resume(subscriptionId, 3);

        (,, bytes32 entitlementHash, uint64 paidThrough, uint32 remainingCharges, bool cancelled) =
            addonPass.subscriptions(subscriptionId);
        assertEq(entitlementHash, ENTITLEMENT_HASH);
        assertEq(paidThrough, resumeTime + addonPass.MONTHLY_PERIOD());
        assertEq(remainingCharges, 2);
        assertFalse(cancelled);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE * 2);
    }

    function testExhaustedSubscriptionCanExtendBeforeExpiry() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        (,,, uint64 originalPaidThrough,,) = addonPass.subscriptions(subscriptionId);
        vm.warp(originalPaidThrough - 1 days);

        usdc.mint(payer, PLAN_PRICE);
        vm.prank(payer);
        usdc.approve(address(addonPass), PLAN_PRICE * 3);
        vm.prank(payer);
        addonPass.resume(subscriptionId, 3);

        (,,, uint64 paidThrough, uint32 remainingCharges, bool cancelled) =
            addonPass.subscriptions(subscriptionId);
        assertEq(paidThrough, originalPaidThrough + addonPass.MONTHLY_PERIOD());
        assertEq(remainingCharges, 2);
        assertFalse(cancelled);
        (bool entitled,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitled);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE * 2);
    }

    function testExhaustedSubscriptionResumedInGraceStartsNow() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        (,,, uint64 originalPaidThrough,,) = addonPass.subscriptions(subscriptionId);
        vm.warp(originalPaidThrough + 1 days);

        usdc.mint(payer, PLAN_PRICE);
        vm.prank(payer);
        usdc.approve(address(addonPass), PLAN_PRICE);
        vm.prank(payer);
        addonPass.resume(subscriptionId, 1);

        (,,, uint64 paidThrough,,) = addonPass.subscriptions(subscriptionId);
        assertEq(paidThrough, block.timestamp + addonPass.MONTHLY_PERIOD());
    }

    function testSubscriptionWithRemainingChargesCannotResumeEarly() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 2);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 2);
        (,,, uint64 paidThrough,,) = addonPass.subscriptions(subscriptionId);
        vm.warp(paidThrough + addonPass.CUSTOMER_GRACE());

        vm.prank(payer);
        vm.expectRevert(AddonPassV1.NotResumable.selector);
        addonPass.resume(subscriptionId, 2);
    }

    function testPayerCanRotateEntitlementAtomically() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        bytes32 replacementHash = keccak256("replacement");

        vm.prank(payer);
        addonPass.rotateEntitlement(subscriptionId, replacementHash);

        assertEq(addonPass.subscriptionByEntitlementHash(ENTITLEMENT_HASH), 0);
        assertEq(addonPass.subscriptionByEntitlementHash(replacementHash), subscriptionId);
        (bool oldEntitled,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        (bool replacementEntitled,,,,) = addonPass.entitlementStatus(replacementHash);
        assertFalse(oldEntitled);
        assertTrue(replacementEntitled);
    }

    function testTierSnapshotAffectsOnlyLaterPayments() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 2);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        uint256 freeClaimable = addonPass.developerClaimable(DEVELOPER);

        uint256 proPrice = addonPass.PRO_PRICE();
        usdc.mint(DEVELOPER, proPrice);
        vm.prank(DEVELOPER);
        usdc.approve(address(addonPass), proPrice);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);

        _approve(secondPayer, PLAN_PRICE);
        vm.prank(secondPayer);
        addonPass.subscribe(planId, keccak256("entitlement-two"), 1);

        assertEq(freeClaimable, 4_650_000);
        assertEq(addonPass.developerClaimable(DEVELOPER), freeClaimable + 4_900_000);
        assertEq(addonPass.platformClaimable(), 350_000 + addonPass.PRO_PRICE() + 100_000);
    }

    function testRetiredEntitlementsCannotBeReused() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 3);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        bytes32 replacementHash = keccak256("replacement");
        vm.prank(payer);
        addonPass.rotateEntitlement(subscriptionId, replacementHash);

        vm.expectRevert(AddonPassV1.EntitlementAlreadyUsed.selector);
        vm.prank(payer);
        addonPass.rotateEntitlement(subscriptionId, ENTITLEMENT_HASH);
        _approve(secondPayer, PLAN_PRICE);
        vm.expectRevert(AddonPassV1.EntitlementAlreadyUsed.selector);
        vm.prank(secondPayer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);

        AddonPassV1.PermitData memory permit = _permit(SECOND_PAYER_KEY, PLAN_PRICE, 1 hours);
        vm.expectRevert(AddonPassV1.EntitlementAlreadyUsed.selector);
        vm.prank(secondPayer);
        addonPass.subscribeWithPermit(planId, ENTITLEMENT_HASH, 1, permit);
        assertEq(usdc.nonces(secondPayer), 0);

        vm.prank(payer);
        addonPass.rotateEntitlement(subscriptionId, keccak256("third"));
        vm.expectRevert(AddonPassV1.EntitlementAlreadyUsed.selector);
        vm.prank(payer);
        addonPass.subscribe(planId, replacementHash, 1);
        assertEq(addonPass.subscriptionByEntitlementHash(ENTITLEMENT_HASH), 0);
        assertEq(addonPass.subscriptionByEntitlementHash(replacementHash), 0);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE);
    }

    function testUnauthorizedRotationDoesNotRetireOrReserveHashes() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 2);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        bytes32 replacementHash = keccak256("replacement");
        vm.expectRevert(AddonPassV1.NotPayer.selector);
        vm.prank(OTHER);
        addonPass.rotateEntitlement(subscriptionId, replacementHash);
        assertEq(addonPass.subscriptionByEntitlementHash(ENTITLEMENT_HASH), subscriptionId);
        vm.prank(payer);
        addonPass.subscribe(planId, replacementHash, 1);
    }

    function testFuzzProUpgradeConvertsUnusedValue(
        uint8 rawMonths,
        uint32 rawElapsed,
        bool fromBalance
    ) public {
        uint256 months = bound(rawMonths, 1, 12);
        uint256 elapsed = bound(rawElapsed, 0, (months + 1) * 30 days);
        _registerDeveloper();
        uint256 planId = _createPlan(MAX_PLAN_PRICE, MONTHLY_PERIOD);
        _approve(payer, MAX_PLAN_PRICE);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        _approve(DEVELOPER, months * addonPass.PRO_PRICE() + addonPass.STUDIO_PRICE());
        for (uint256 i; i < months; ++i) {
            vm.prank(DEVELOPER);
            addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);
        }
        (,, uint64 previousPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        vm.warp(block.timestamp + elapsed);
        uint256 remaining =
            previousPaidThrough > block.timestamp ? previousPaidThrough - block.timestamp : 0;
        uint256 liabilitiesBefore = addonPass.totalLiabilities();
        uint256 developerBefore = addonPass.developerClaimable(DEVELOPER);
        uint256 platformBefore = addonPass.platformClaimable();
        uint256 walletBefore = usdc.balanceOf(DEVELOPER);
        vm.prank(DEVELOPER);
        if (fromBalance) {
            addonPass.activateTierFromOperatingBalance(AddonPassV1.Tier.Studio);
        } else {
            addonPass.activateTierFromWallet(AddonPassV1.Tier.Studio);
        }
        (, AddonPassV1.Tier selectedTier, uint64 paidThrough,,,,) = addonPass.developers(DEVELOPER);
        assertEq(uint8(selectedTier), uint8(AddonPassV1.Tier.Studio));
        assertEq(paidThrough, block.timestamp + 30 days + remaining * 12 / 39);
        assertEq(addonPass.platformClaimable(), platformBefore + 39e6);
        assertEq(addonPass.totalLiabilities(), liabilitiesBefore + (fromBalance ? 0 : 39e6));
        assertEq(
            addonPass.developerClaimable(DEVELOPER), developerBefore - (fromBalance ? 39e6 : 0)
        );
        assertEq(usdc.balanceOf(DEVELOPER), walletBefore - (fromBalance ? 0 : 39e6));
    }

    function testSameTierPurchasePreservesAllUnusedTime() public {
        _registerDeveloper();
        _approve(DEVELOPER, 78e6);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Studio);
        (,, uint64 previousPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        vm.warp(block.timestamp + 7 days);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Studio);
        (,, uint64 paidThrough,,,,) = addonPass.developers(DEVELOPER);
        assertEq(paidThrough, previousPaidThrough + 30 days);
    }

    function testStudioDowngradeAllowedOnlyAfterExpiry() public {
        _registerDeveloper();
        _approve(DEVELOPER, 51e6);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Studio);
        (,, uint64 previousPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        vm.warp(previousPaidThrough);
        vm.expectRevert(AddonPassV1.TierDowngradeNotAllowed.selector);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);
        vm.warp(previousPaidThrough + 1);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);
        (,, uint64 paidThrough,,,,) = addonPass.developers(DEVELOPER);
        assertEq(paidThrough, block.timestamp + 30 days);
    }

    function testTierActivationFromOperatingBalanceDoesNotChangeTotalLiabilities() public {
        uint96 price = 100e6;
        _registerDeveloper();
        uint256 planId = _createPlan(price, addonPass.MONTHLY_PERIOD());
        _approve(payer, price);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        uint256 liabilitiesBefore = addonPass.totalLiabilities();
        uint256 platformBefore = addonPass.platformClaimable();

        vm.prank(DEVELOPER);
        addonPass.activateTierFromOperatingBalance(AddonPassV1.Tier.Pro);

        assertEq(addonPass.totalLiabilities(), liabilitiesBefore);
        assertEq(addonPass.platformClaimable(), platformBefore + addonPass.PRO_PRICE());
        assertEq(addonPass.developerClaimable(DEVELOPER), 94.9e6 - addonPass.PRO_PRICE());
        assertEq(addonPass.totalDeveloperLiability(), 94.9e6 - addonPass.PRO_PRICE());
    }

    function testTierAutoRenewMovesOnlyExistingLiability() public {
        uint96 price = 100e6;
        _registerDeveloper();
        uint256 planId = _createPlan(price, addonPass.MONTHLY_PERIOD());
        _approve(payer, price);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromOperatingBalance(AddonPassV1.Tier.Pro);
        vm.prank(DEVELOPER);
        addonPass.setTierAutoRenew(true);
        (,, uint64 firstPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        uint256 liabilitiesBefore = addonPass.totalLiabilities();

        vm.warp(firstPaidThrough - addonPass.TIER_RENEWAL_WINDOW());
        assertTrue(addonPass.renewDeveloperTier(DEVELOPER));

        (,, uint64 renewedPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        assertEq(renewedPaidThrough, firstPaidThrough + addonPass.TIER_PERIOD());
        assertEq(addonPass.totalLiabilities(), liabilitiesBefore);
    }

    function testTierRenewalFailureDoesNotChangeFinancialState() public {
        _registerDeveloper();
        uint256 proPrice = addonPass.PRO_PRICE();
        usdc.mint(DEVELOPER, proPrice);
        vm.prank(DEVELOPER);
        usdc.approve(address(addonPass), proPrice);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);
        vm.prank(DEVELOPER);
        addonPass.setTierAutoRenew(true);
        (,, uint64 paidThrough,,,,) = addonPass.developers(DEVELOPER);
        uint256 liabilitiesBefore = addonPass.totalLiabilities();

        vm.warp(paidThrough - addonPass.TIER_RENEWAL_WINDOW());
        assertFalse(addonPass.renewDeveloperTier(DEVELOPER));

        (,, uint64 unchangedPaidThrough,,,,) = addonPass.developers(DEVELOPER);
        assertEq(unchangedPaidThrough, paidThrough);
        assertEq(addonPass.totalLiabilities(), liabilitiesBefore);
    }

    function testActiveStudioTierCannotDowngradeToPro() public {
        _registerDeveloper();
        uint256 studioPrice = addonPass.STUDIO_PRICE();
        uint256 proPrice = addonPass.PRO_PRICE();
        usdc.mint(DEVELOPER, studioPrice + proPrice);
        vm.prank(DEVELOPER);
        usdc.approve(address(addonPass), studioPrice + proPrice);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Studio);

        vm.expectRevert(AddonPassV1.TierDowngradeNotAllowed.selector);
        vm.prank(DEVELOPER);
        addonPass.activateTierFromWallet(AddonPassV1.Tier.Pro);
    }

    function testSubscribeWithPermitUsesExactBoundedAllowance() public {
        _registerDeveloper();
        uint256 planId = _createPlan(PLAN_PRICE, addonPass.MONTHLY_PERIOD());
        usdc.mint(payer, PLAN_PRICE * 12);
        AddonPassV1.PermitData memory permit = _permit(PAYER_KEY, PLAN_PRICE * 12, 1 hours);

        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribeWithPermit(planId, ENTITLEMENT_HASH, 12, permit);

        assertEq(subscriptionId, 1);
        assertEq(usdc.allowance(payer, address(addonPass)), PLAN_PRICE * 11);
        assertEq(addonPass.totalLiabilities(), PLAN_PRICE);
    }

    function testSubscribeWithAlreadySubmittedExactPermit() public {
        _registerDeveloper();
        uint256 planId = _createPlan(PLAN_PRICE, addonPass.MONTHLY_PERIOD());
        usdc.mint(payer, PLAN_PRICE * 12);
        AddonPassV1.PermitData memory permit = _permit(PAYER_KEY, PLAN_PRICE * 12, 1 hours);

        usdc.permit(
            payer, address(addonPass), permit.value, permit.deadline, permit.v, permit.r, permit.s
        );
        vm.prank(payer);
        addonPass.subscribeWithPermit(planId, ENTITLEMENT_HASH, 12, permit);

        assertEq(addonPass.totalLiabilities(), PLAN_PRICE);
    }

    function testPermitFallbackRejectsDifferentExistingAllowance() public {
        _registerDeveloper();
        uint256 planId = _createPlan(PLAN_PRICE, addonPass.MONTHLY_PERIOD());
        usdc.mint(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        usdc.approve(address(addonPass), PLAN_PRICE * 12 + 1);
        AddonPassV1.PermitData memory invalidPermit = AddonPassV1.PermitData({
            value: PLAN_PRICE * 12,
            deadline: block.timestamp + 1 hours,
            v: 27,
            r: bytes32(0),
            s: bytes32(0)
        });

        vm.expectRevert(AddonPassV1.PermitAllowanceMismatch.selector);
        vm.prank(payer);
        addonPass.subscribeWithPermit(planId, ENTITLEMENT_HASH, 12, invalidPermit);
    }

    function testDeveloperAndPlatformWithdrawalsStaySegregated() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);

        vm.prank(DEVELOPER);
        addonPass.withdrawDeveloper(1_000_000);
        assertEq(usdc.balanceOf(PAYOUT), 1_000_000);
        assertEq(addonPass.developerClaimable(DEVELOPER), 3_650_000);
        assertEq(addonPass.platformClaimable(), 350_000);

        vm.prank(TREASURY);
        addonPass.withdrawAllPlatform();
        assertEq(usdc.balanceOf(TREASURY), 350_000);
        assertEq(addonPass.developerClaimable(DEVELOPER), 3_650_000);
        assertEq(addonPass.totalLiabilities(), 3_650_000);
    }

    function testPaymentPauseLeavesCancellationAndWithdrawalsAvailable() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);

        vm.prank(GUARDIAN);
        addonPass.pausePayments();
        vm.prank(payer);
        addonPass.cancel(subscriptionId);
        vm.prank(DEVELOPER);
        addonPass.withdrawAllDeveloper();

        assertEq(addonPass.developerClaimable(DEVELOPER), 0);
        vm.expectRevert(AddonPassV1.PaymentsArePaused.selector);
        vm.prank(secondPayer);
        addonPass.subscribe(planId, keccak256("blocked"), 1);
    }

    function testOwnerSuspensionStopsSalesAndRenewalsWithoutRemovingPaidAccess() public {
        uint256 planId = _registerCreateAndApprove(payer, PLAN_PRICE * 12);
        vm.prank(payer);
        uint256 subscriptionId = addonPass.subscribe(planId, ENTITLEMENT_HASH, 12);
        (,,, uint64 paidThrough,,) = addonPass.subscriptions(subscriptionId);

        vm.prank(OWNER);
        addonPass.setDeveloperSuspension(DEVELOPER, true, true);
        _approve(secondPayer, PLAN_PRICE);
        vm.expectRevert(AddonPassV1.NotRenewable.selector);
        vm.prank(secondPayer);
        addonPass.subscribe(planId, keccak256("suspended-sale"), 1);

        vm.warp(paidThrough);
        (bool entitledAtPaidThrough,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitledAtPaidThrough);
        vm.expectRevert(AddonPassV1.NotRenewable.selector);
        addonPass.tryCharge(subscriptionId);

        vm.warp(uint256(paidThrough) + 1);
        (bool entitledWhileSuspended,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertFalse(entitledWhileSuspended);

        vm.prank(OWNER);
        addonPass.setDeveloperSuspension(DEVELOPER, true, false);
        (bool entitledAfterRenewalRestored,,,,) = addonPass.entitlementStatus(ENTITLEMENT_HASH);
        assertTrue(entitledAfterRenewalRestored);
    }

    function testOwnershipCannotBeRenounced() public {
        vm.expectRevert(AddonPassV1.OwnershipRenunciationDisabled.selector);
        vm.prank(OWNER);
        addonPass.renounceOwnership();
    }

    function testTreasuryChangeRequiresAcceptance() public {
        vm.prank(OWNER);
        addonPass.proposeTreasury(OTHER);
        assertEq(addonPass.treasury(), TREASURY);
        assertEq(addonPass.pendingTreasury(), OTHER);

        vm.expectRevert(AddonPassV1.NotTreasury.selector);
        vm.prank(TREASURY);
        addonPass.acceptTreasury();

        vm.prank(OTHER);
        addonPass.acceptTreasury();
        assertEq(addonPass.treasury(), OTHER);
        assertEq(addonPass.pendingTreasury(), address(0));
    }

    function testOwnerCanSweepOnlyProvableSurplus() public {
        usdc.mint(address(addonPass), PLAN_PRICE);
        vm.prank(OWNER);
        addonPass.sweepSurplus(PLAN_PRICE);
        assertEq(usdc.balanceOf(TREASURY), PLAN_PRICE);

        vm.expectRevert(AddonPassV1.SurplusExceeded.selector);
        vm.prank(OWNER);
        addonPass.sweepSurplus(1);
    }

    function testOwnerCanRescueOnlyNonUsdcTokens() public {
        MockUSDC otherToken = new MockUSDC();
        otherToken.mint(address(addonPass), PLAN_PRICE);
        vm.prank(OWNER);
        addonPass.rescueNonUsdcToken(IERC20(address(otherToken)), PLAN_PRICE);
        assertEq(otherToken.balanceOf(TREASURY), PLAN_PRICE);

        vm.expectRevert(AddonPassV1.TokenIsUSDC.selector);
        vm.prank(OWNER);
        addonPass.rescueNonUsdcToken(IERC20(address(usdc)), 1);
    }

    function testFuzzSettlementFeeUsesExactTierSnapshot(uint96 rawPrice, uint8 rawTier) public {
        uint96 price = uint96(bound(rawPrice, MIN_PLAN_PRICE, MAX_PLAN_PRICE));
        AddonPassV1.Tier tier = AddonPassV1.Tier(bound(rawTier, 0, 2));
        _registerDeveloper();
        uint256 planId = _createPlan(price, addonPass.MONTHLY_PERIOD());

        if (tier != AddonPassV1.Tier.Free) {
            uint256 tierPrice =
                tier == AddonPassV1.Tier.Pro ? addonPass.PRO_PRICE() : addonPass.STUDIO_PRICE();
            usdc.mint(DEVELOPER, tierPrice);
            vm.prank(DEVELOPER);
            usdc.approve(address(addonPass), tierPrice);
            vm.prank(DEVELOPER);
            addonPass.activateTierFromWallet(tier);
        }

        _approve(payer, price);
        vm.prank(payer);
        addonPass.subscribe(planId, ENTITLEMENT_HASH, 1);

        uint256 feeBps = tier == AddonPassV1.Tier.Free
            ? addonPass.FREE_FEE_BPS()
            : tier == AddonPassV1.Tier.Pro ? addonPass.PRO_FEE_BPS() : addonPass.STUDIO_FEE_BPS();
        uint256 expectedFee = uint256(price) * feeBps / addonPass.BPS_DENOMINATOR()
            + (tier == AddonPassV1.Tier.Free ? addonPass.FREE_FIXED_FEE() : 0);
        uint256 tierRevenue = tier == AddonPassV1.Tier.Free
            ? 0
            : tier == AddonPassV1.Tier.Pro ? addonPass.PRO_PRICE() : addonPass.STUDIO_PRICE();
        assertEq(addonPass.platformClaimable(), tierRevenue + expectedFee);
        assertEq(addonPass.developerClaimable(DEVELOPER), uint256(price) - expectedFee);
    }

    function _registerDeveloper() private {
        vm.prank(DEVELOPER);
        addonPass.registerDeveloper(PAYOUT);
    }

    function _createPlan(uint96 price, uint32 period) private returns (uint256) {
        vm.prank(DEVELOPER);
        return addonPass.createPlan(price, period, METADATA_HASH);
    }

    function _registerCreateAndApprove(address account, uint256 allowance)
        private
        returns (uint256 planId)
    {
        _registerDeveloper();
        planId = _createPlan(PLAN_PRICE, addonPass.MONTHLY_PERIOD());
        _approve(account, allowance);
    }

    function _approve(address account, uint256 amount) private {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(address(addonPass), amount);
    }

    function _permit(uint256 signerKey, uint256 value, uint256 lifetime)
        private
        view
        returns (AddonPassV1.PermitData memory permit)
    {
        address signer = vm.addr(signerKey);
        uint256 deadline = block.timestamp + lifetime;
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
                ),
                signer,
                address(addonPass),
                value,
                usdc.nonces(signer),
                deadline
            )
        );
        bytes32 digest =
            keccak256(abi.encodePacked("\x19\x01", usdc.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, digest);
        return AddonPassV1.PermitData({ value: value, deadline: deadline, v: v, r: r, s: s });
    }
}
