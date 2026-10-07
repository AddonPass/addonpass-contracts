// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract AddonPassV1 is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;

    enum Tier {
        Free,
        Pro,
        Studio
    }

    struct Developer {
        address payoutWallet;
        Tier selectedTier;
        uint64 tierPaidThrough;
        bool autoRenewTier;
        bool newSalesEnabled;
        bool renewalsEnabled;
        bool registered;
    }

    struct Plan {
        address developer;
        uint96 price;
        uint32 period;
        bytes32 metadataHash;
        bool newSalesEnabled;
        bool renewalsEnabled;
    }

    struct Subscription {
        uint256 planId;
        address payer;
        bytes32 entitlementHash;
        uint64 paidThrough;
        uint32 remainingCharges;
        bool cancelled;
    }

    struct PermitData {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    uint16 public constant FREE_FEE_BPS = 500;
    uint16 public constant PRO_FEE_BPS = 200;
    uint16 public constant STUDIO_FEE_BPS = 100;
    uint16 public constant BPS_DENOMINATOR = 10_000;
    uint96 public constant FREE_FIXED_FEE = 0.1e6;

    uint96 public constant PRO_PRICE = 12e6;
    uint96 public constant STUDIO_PRICE = 39e6;

    uint32 public constant TIER_PERIOD = 30 days;
    uint32 public constant MONTHLY_PERIOD = 30 days;
    uint32 public constant ANNUAL_PERIOD = 365 days;
    /// A one-time plan takes a single payment and its access does not expire.
    uint32 public constant ONE_TIME_PERIOD = 0;
    /// 9999-12-28 UTC: never lapses, and stays a four-digit-year date even after the
    /// customer grace period is added, so databases and ISO strings can represent it.
    uint64 public constant ONE_TIME_PAID_THROUGH = 253_401_955_200;
    uint32 public constant CUSTOMER_GRACE = 3 days;
    uint32 public constant TIER_RENEWAL_WINDOW = 3 days;
    uint32 public constant ABSOLUTE_MAX_CHARGES = 120;

    address public constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address public constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    uint256 public constant BASE_CHAIN_ID = 8453;
    uint256 public constant BASE_SEPOLIA_CHAIN_ID = 84532;

    IERC20 public immutable usdc;
    uint96 public immutable minPlanPrice;
    uint96 public immutable maxPlanPrice;
    uint32 public immutable maxMonthlyCharges;
    uint32 public immutable maxAnnualCharges;

    address public treasury;
    address public pendingTreasury;
    address public guardian;
    bool public paymentsPaused;

    uint256 public nextPlanId = 1;
    uint256 public nextSubscriptionId = 1;

    mapping(address developer => Developer account) public developers;
    mapping(uint256 planId => Plan plan) public plans;
    mapping(uint256 subscriptionId => Subscription subscription) public subscriptions;
    mapping(bytes32 entitlementHash => uint256 subscriptionId) public subscriptionByEntitlementHash;
    mapping(bytes32 entitlementHash => bool retired) private retiredEntitlementHashes;

    mapping(address developer => uint256 amount) public developerClaimable;
    uint256 public platformClaimable;
    uint256 public totalDeveloperLiability;
    uint256 public totalLiabilities;

    uint256 public lifetimeGrossVolume;
    uint256 public lifetimeTransactionFees;
    uint256 public lifetimeDeveloperSubscriptions;

    mapping(address developer => bool suspended) public developerSalesSuspended;
    mapping(address developer => bool suspended) public developerRenewalsSuspended;

    error AlreadyCancelled();
    error AlreadyRegistered();
    error AuthorizationLimitExceeded();
    error DeveloperNotRegistered();
    error EntitlementAlreadyUsed();
    error Insolvent();
    error InsufficientClaimable();
    error InvalidAddress();
    error InvalidAmount();
    error InvalidConfiguration();
    error InvalidEntitlementHash();
    error InvalidMetadataHash();
    error InvalidPeriod();
    error InvalidPlanPrice();
    error InvalidTier();
    error NotDue();
    error NotPayer();
    error NotPlanDeveloper();
    error NotRenewable();
    error OneTimePurchase();
    error NotResumable();
    error NotTreasury();
    error OutsideGraceWindow();
    error OutsideTierRenewalWindow();
    error OwnershipRenunciationDisabled();
    error PaymentsArePaused();
    error PermitAllowanceMismatch();
    error PlanNotFound();
    error SubscriptionNotFound();
    error SurplusExceeded();
    error TokenIsUSDC();
    error TierDowngradeNotAllowed();
    error UnauthorizedGuardian();
    error UnsupportedUSDC();

    event DeveloperRegistered(address indexed developer, address payoutWallet);
    event PayoutWalletChanged(address indexed developer, address payoutWallet);
    event DeveloperSalesStatusChanged(address indexed developer, bool enabled);
    event DeveloperRenewalStatusChanged(address indexed developer, bool enabled);
    event DeveloperTierAutoRenewChanged(address indexed developer, bool enabled);
    event PlanCreated(
        uint256 indexed planId, address indexed developer, uint96 price, uint32 period
    );
    event PlanSalesStatusChanged(uint256 indexed planId, bool enabled);
    event PlanRenewalStatusChanged(uint256 indexed planId, bool enabled);

    event DeveloperTierActivated(
        address indexed developer, Tier tier, uint64 paidThrough, bool fromBalance
    );
    event DeveloperTierRenewalFailed(address indexed developer, Tier tier);

    event SubscriptionCreated(
        uint256 indexed subscriptionId,
        uint256 indexed planId,
        address indexed payer,
        bytes32 entitlementHash
    );
    event CustomerPaymentSettled(
        uint256 indexed subscriptionId,
        address indexed developer,
        address indexed payer,
        uint256 gross,
        uint256 fee,
        uint256 net,
        Tier tier,
        uint16 feeBps,
        uint64 paidThrough
    );
    event CustomerChargeFailed(uint256 indexed subscriptionId);
    event SubscriptionCancelled(uint256 indexed subscriptionId, uint64 paidThrough);
    event SubscriptionResumed(
        uint256 indexed subscriptionId, uint64 paidThrough, uint32 remainingCharges
    );
    event EntitlementRotated(uint256 indexed subscriptionId, bytes32 oldHash, bytes32 newHash);

    event DeveloperWithdrawal(
        address indexed developer, address indexed payoutWallet, uint256 amount
    );
    event PlatformWithdrawal(address indexed treasury, uint256 amount);
    event TreasuryTransferStarted(address indexed currentTreasury, address indexed pendingTreasury);
    event TreasuryTransferred(address indexed previousTreasury, address indexed newTreasury);
    event GuardianChanged(address indexed previousGuardian, address indexed newGuardian);
    event PaymentsPauseChanged(bool paused, address indexed actor);
    event DeveloperSuspensionChanged(
        address indexed developer, bool salesSuspended, bool renewalsSuspended
    );
    event NonUsdcTokenRescued(address indexed token, uint256 amount);
    event SurplusSwept(uint256 amount);

    constructor(
        IERC20 usdc_,
        address initialOwner,
        address initialTreasury,
        address initialGuardian,
        uint96 minPlanPrice_,
        uint96 maxPlanPrice_,
        uint32 maxMonthlyCharges_,
        uint32 maxAnnualCharges_
    ) Ownable(initialOwner) {
        if (
            address(usdc_) == address(0) || initialTreasury == address(0)
                || initialGuardian == address(0)
        ) {
            revert InvalidAddress();
        }
        if (
            minPlanPrice_ == 0 || minPlanPrice_ > maxPlanPrice_ || maxMonthlyCharges_ == 0
                || maxAnnualCharges_ == 0 || maxMonthlyCharges_ > ABSOLUTE_MAX_CHARGES
                || maxAnnualCharges_ > ABSOLUTE_MAX_CHARGES
                || _feeFor(Tier.Free, minPlanPrice_) >= minPlanPrice_
        ) {
            revert InvalidConfiguration();
        }
        if (
            (block.chainid == BASE_CHAIN_ID && address(usdc_) != BASE_USDC)
                || (block.chainid == BASE_SEPOLIA_CHAIN_ID && address(usdc_) != BASE_SEPOLIA_USDC)
        ) {
            revert UnsupportedUSDC();
        }
        if (IERC20Metadata(address(usdc_)).decimals() != 6) revert UnsupportedUSDC();

        usdc = usdc_;
        treasury = initialTreasury;
        guardian = initialGuardian;
        minPlanPrice = minPlanPrice_;
        maxPlanPrice = maxPlanPrice_;
        maxMonthlyCharges = maxMonthlyCharges_;
        maxAnnualCharges = maxAnnualCharges_;
    }

    function registerDeveloper(address payoutWallet) external {
        if (payoutWallet == address(0)) revert InvalidAddress();
        Developer storage account = developers[msg.sender];
        if (account.registered) revert AlreadyRegistered();

        account.payoutWallet = payoutWallet;
        account.newSalesEnabled = true;
        account.renewalsEnabled = true;
        account.registered = true;

        emit DeveloperRegistered(msg.sender, payoutWallet);
    }

    function setPayoutWallet(address payoutWallet) external {
        if (payoutWallet == address(0)) revert InvalidAddress();
        Developer storage account = _registeredDeveloper(msg.sender);
        account.payoutWallet = payoutWallet;
        emit PayoutWalletChanged(msg.sender, payoutWallet);
    }

    function setDeveloperSalesEnabled(bool enabled) external {
        Developer storage account = _registeredDeveloper(msg.sender);
        account.newSalesEnabled = enabled;
        emit DeveloperSalesStatusChanged(msg.sender, enabled);
    }

    function setDeveloperRenewalsEnabled(bool enabled) external {
        Developer storage account = _registeredDeveloper(msg.sender);
        account.renewalsEnabled = enabled;
        emit DeveloperRenewalStatusChanged(msg.sender, enabled);
    }

    function createPlan(uint96 price, uint32 period, bytes32 metadataHash)
        external
        returns (uint256 planId)
    {
        _registeredDeveloper(msg.sender);
        if (price < minPlanPrice || price > maxPlanPrice) revert InvalidPlanPrice();
        if (period != MONTHLY_PERIOD && period != ANNUAL_PERIOD && period != ONE_TIME_PERIOD) {
            revert InvalidPeriod();
        }
        if (metadataHash == bytes32(0)) revert InvalidMetadataHash();

        planId = nextPlanId++;
        plans[planId] = Plan({
            developer: msg.sender,
            price: price,
            period: period,
            metadataHash: metadataHash,
            newSalesEnabled: true,
            renewalsEnabled: true
        });

        emit PlanCreated(planId, msg.sender, price, period);
    }

    function setPlanSalesEnabled(uint256 planId, bool enabled) external {
        Plan storage plan = _ownedPlan(planId, msg.sender);
        plan.newSalesEnabled = enabled;
        emit PlanSalesStatusChanged(planId, enabled);
    }

    function setPlanRenewalsEnabled(uint256 planId, bool enabled) external {
        Plan storage plan = _ownedPlan(planId, msg.sender);
        plan.renewalsEnabled = enabled;
        emit PlanRenewalStatusChanged(planId, enabled);
    }

    function effectiveTier(address developer) public view returns (Tier) {
        Developer storage account = developers[developer];
        if (account.tierPaidThrough < block.timestamp) return Tier.Free;
        return account.selectedTier;
    }

    function feeBpsFor(address developer) public view returns (uint16) {
        Tier tier = effectiveTier(developer);
        if (tier == Tier.Pro) return PRO_FEE_BPS;
        if (tier == Tier.Studio) return STUDIO_FEE_BPS;
        return FREE_FEE_BPS;
    }

    function activateTierFromWallet(Tier tier) external nonReentrant {
        _requirePaymentsActive();
        Developer storage account = _registeredDeveloper(msg.sender);
        uint256 price = _tierPrice(tier);
        _validateTierTransition(account, tier);

        usdc.safeTransferFrom(msg.sender, address(this), price);

        platformClaimable += price;
        totalLiabilities += price;
        lifetimeDeveloperSubscriptions += price;
        _activateTier(account, msg.sender, tier, false);
        _assertSolvent();
    }

    function activateTierFromOperatingBalance(Tier tier) external {
        _requirePaymentsActive();
        Developer storage account = _registeredDeveloper(msg.sender);
        uint256 price = _tierPrice(tier);
        _validateTierTransition(account, tier);
        uint256 claimable = developerClaimable[msg.sender];
        if (claimable < price) revert InsufficientClaimable();

        developerClaimable[msg.sender] = claimable - price;
        totalDeveloperLiability -= price;
        platformClaimable += price;
        lifetimeDeveloperSubscriptions += price;
        _activateTier(account, msg.sender, tier, true);
    }

    function setTierAutoRenew(bool enabled) external {
        Developer storage account = _registeredDeveloper(msg.sender);
        account.autoRenewTier = enabled;
        emit DeveloperTierAutoRenewChanged(msg.sender, enabled);
    }

    function renewDeveloperTier(address developer) external returns (bool renewed) {
        _requirePaymentsActive();
        Developer storage account = _registeredDeveloper(developer);
        Tier tier = account.selectedTier;
        if (tier == Tier.Free || !account.autoRenewTier) revert NotRenewable();

        uint256 paidThrough = account.tierPaidThrough;
        if (block.timestamp > paidThrough || block.timestamp + TIER_RENEWAL_WINDOW < paidThrough) {
            revert OutsideTierRenewalWindow();
        }

        uint256 price = _tierPrice(tier);
        uint256 claimable = developerClaimable[developer];
        if (claimable < price) {
            emit DeveloperTierRenewalFailed(developer, tier);
            return false;
        }

        developerClaimable[developer] = claimable - price;
        totalDeveloperLiability -= price;
        platformClaimable += price;
        lifetimeDeveloperSubscriptions += price;
        account.tierPaidThrough = (paidThrough + TIER_PERIOD).toUint64();

        emit DeveloperTierActivated(developer, tier, account.tierPaidThrough, true);
        return true;
    }

    function subscribe(uint256 planId, bytes32 entitlementHash, uint32 maxCharges)
        external
        nonReentrant
        returns (uint256 subscriptionId)
    {
        _requirePaymentsActive();
        return _subscribe(msg.sender, planId, entitlementHash, maxCharges);
    }

    function subscribeWithPermit(
        uint256 planId,
        bytes32 entitlementHash,
        uint32 maxCharges,
        PermitData calldata permit
    ) external nonReentrant returns (uint256 subscriptionId) {
        _requirePaymentsActive();
        Plan storage plan = _plan(planId);
        _validateChargeCount(plan.period, maxCharges);
        uint256 expectedValue = uint256(plan.price) * uint256(maxCharges);
        if (permit.value != expectedValue) revert PermitAllowanceMismatch();

        try IERC20Permit(address(usdc))
            .permit(
                msg.sender,
                address(this),
                permit.value,
                permit.deadline,
                permit.v,
                permit.r,
                permit.s
            ) { }
        catch {
            if (usdc.allowance(msg.sender, address(this)) != expectedValue) {
                revert PermitAllowanceMismatch();
            }
        }

        if (usdc.allowance(msg.sender, address(this)) != expectedValue) {
            revert PermitAllowanceMismatch();
        }

        return _subscribe(msg.sender, planId, entitlementHash, maxCharges);
    }

    function tryCharge(uint256 subscriptionId) external nonReentrant returns (bool paid) {
        _requirePaymentsActive();
        Subscription storage subscription = _subscription(subscriptionId);
        if (subscription.cancelled) revert AlreadyCancelled();
        if (subscription.remainingCharges == 0) revert AuthorizationLimitExceeded();
        if (block.timestamp < subscription.paidThrough) revert NotDue();
        if (block.timestamp > uint256(subscription.paidThrough) + CUSTOMER_GRACE) {
            revert OutsideGraceWindow();
        }

        Plan storage plan = _plan(subscription.planId);
        _requireRenewalsEnabled(plan);

        Tier tier = effectiveTier(plan.developer);
        uint16 feeBps = _feeBps(tier);
        if (!_tryTransferFrom(subscription.payer, plan.price)) {
            emit CustomerChargeFailed(subscriptionId);
            return false;
        }

        subscription.paidThrough = (uint256(subscription.paidThrough) + plan.period).toUint64();
        subscription.remainingCharges -= 1;
        _allocateCustomerPayment(
            subscriptionId,
            plan.developer,
            subscription.payer,
            plan.price,
            tier,
            feeBps,
            subscription.paidThrough
        );
        _assertSolvent();
        return true;
    }

    function cancel(uint256 subscriptionId) external {
        Subscription storage subscription = _subscription(subscriptionId);
        if (subscription.payer != msg.sender) revert NotPayer();
        if (subscription.cancelled) revert AlreadyCancelled();
        if (plans[subscription.planId].period == ONE_TIME_PERIOD) revert OneTimePurchase();
        subscription.cancelled = true;
        emit SubscriptionCancelled(subscriptionId, subscription.paidThrough);
    }

    function resume(uint256 subscriptionId, uint32 maxCharges) external nonReentrant {
        _requirePaymentsActive();
        Subscription storage subscription = _subscription(subscriptionId);
        if (subscription.payer != msg.sender) revert NotPayer();
        if (plans[subscription.planId].period == ONE_TIME_PERIOD) revert OneTimePurchase();

        // An exhausted authorization can be extended at any time so access never has to lapse.
        bool exhausted = !subscription.cancelled && subscription.remainingCharges == 0;
        uint256 resumableAt = subscription.cancelled
            ? subscription.paidThrough
            : uint256(subscription.paidThrough) + CUSTOMER_GRACE;
        if (!exhausted && block.timestamp <= resumableAt) revert NotResumable();

        Plan storage plan = _plan(subscription.planId);
        _requireRenewalsEnabled(plan);
        _validateChargeCount(plan.period, maxCharges);

        Tier tier = effectiveTier(plan.developer);
        uint16 feeBps = _feeBps(tier);
        usdc.safeTransferFrom(msg.sender, address(this), plan.price);

        uint256 periodStart =
            block.timestamp > subscription.paidThrough ? block.timestamp : subscription.paidThrough;
        subscription.paidThrough = (periodStart + plan.period).toUint64();
        subscription.remainingCharges = maxCharges - 1;
        subscription.cancelled = false;

        _allocateCustomerPayment(
            subscriptionId,
            plan.developer,
            msg.sender,
            plan.price,
            tier,
            feeBps,
            subscription.paidThrough
        );
        emit SubscriptionResumed(
            subscriptionId, subscription.paidThrough, subscription.remainingCharges
        );
        _assertSolvent();
    }

    function entitlementStatus(bytes32 entitlementHash)
        external
        view
        returns (
            bool entitled,
            uint64 paidThrough,
            uint64 graceEnds,
            uint256 subscriptionId,
            address developer
        )
    {
        subscriptionId = subscriptionByEntitlementHash[entitlementHash];
        if (subscriptionId == 0) {
            return (entitled, paidThrough, graceEnds, subscriptionId, developer);
        }

        Subscription storage subscription = subscriptions[subscriptionId];
        Plan storage plan = plans[subscription.planId];
        paidThrough = subscription.paidThrough;
        graceEnds = (uint256(paidThrough) + CUSTOMER_GRACE).toUint64();
        developer = plan.developer;

        if (block.timestamp <= paidThrough) {
            entitled = true;
        } else if (block.timestamp <= graceEnds) {
            Developer storage account = developers[developer];
            entitled = !subscription.cancelled && subscription.remainingCharges > 0
                && plan.renewalsEnabled && account.renewalsEnabled
                && !developerRenewalsSuspended[developer];
        }
    }

    function rotateEntitlement(uint256 subscriptionId, bytes32 newEntitlementHash) external {
        if (newEntitlementHash == bytes32(0)) revert InvalidEntitlementHash();
        if (
            subscriptionByEntitlementHash[newEntitlementHash] != 0
                || retiredEntitlementHashes[newEntitlementHash]
        ) {
            revert EntitlementAlreadyUsed();
        }

        Subscription storage subscription = _subscription(subscriptionId);
        if (subscription.payer != msg.sender) revert NotPayer();

        bytes32 oldHash = subscription.entitlementHash;
        retiredEntitlementHashes[oldHash] = true;
        delete subscriptionByEntitlementHash[oldHash];
        subscription.entitlementHash = newEntitlementHash;
        subscriptionByEntitlementHash[newEntitlementHash] = subscriptionId;

        emit EntitlementRotated(subscriptionId, oldHash, newEntitlementHash);
    }

    function withdrawDeveloper(uint256 amount) external nonReentrant {
        _withdrawDeveloper(msg.sender, amount);
    }

    function withdrawAllDeveloper() external nonReentrant {
        _withdrawDeveloper(msg.sender, developerClaimable[msg.sender]);
    }

    function withdrawPlatform(uint256 amount) external nonReentrant {
        _withdrawPlatform(amount);
    }

    function withdrawAllPlatform() external nonReentrant {
        _withdrawPlatform(platformClaimable);
    }

    function pausePayments() external {
        if (msg.sender != owner() && msg.sender != guardian) revert UnauthorizedGuardian();
        paymentsPaused = true;
        emit PaymentsPauseChanged(true, msg.sender);
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function unpausePayments() external onlyOwner {
        paymentsPaused = false;
        emit PaymentsPauseChanged(false, msg.sender);
    }

    function setGuardian(address newGuardian) external onlyOwner {
        if (newGuardian == address(0)) revert InvalidAddress();
        address previousGuardian = guardian;
        guardian = newGuardian;
        emit GuardianChanged(previousGuardian, newGuardian);
    }

    function setDeveloperSuspension(address developer, bool salesSuspended, bool renewalsSuspended)
        external
        onlyOwner
    {
        _registeredDeveloper(developer);
        developerSalesSuspended[developer] = salesSuspended;
        developerRenewalsSuspended[developer] = renewalsSuspended;
        emit DeveloperSuspensionChanged(developer, salesSuspended, renewalsSuspended);
    }

    function proposeTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        pendingTreasury = newTreasury;
        emit TreasuryTransferStarted(treasury, newTreasury);
    }

    function acceptTreasury() external {
        if (msg.sender != pendingTreasury) revert NotTreasury();
        address previousTreasury = treasury;
        treasury = msg.sender;
        pendingTreasury = address(0);
        emit TreasuryTransferred(previousTreasury, msg.sender);
    }

    function rescueNonUsdcToken(IERC20 token, uint256 amount) external nonReentrant onlyOwner {
        if (address(token) == address(usdc)) revert TokenIsUSDC();
        if (amount == 0) revert InvalidAmount();
        token.safeTransfer(treasury, amount);
        emit NonUsdcTokenRescued(address(token), amount);
    }

    function sweepSurplus(uint256 amount) external nonReentrant onlyOwner {
        if (amount == 0) revert InvalidAmount();
        uint256 balance = usdc.balanceOf(address(this));
        if (balance < totalLiabilities || amount > balance - totalLiabilities) {
            revert SurplusExceeded();
        }
        usdc.safeTransfer(treasury, amount);
        emit SurplusSwept(amount);
        _assertSolvent();
    }

    function surplusUsdc() external view returns (uint256) {
        uint256 balance = usdc.balanceOf(address(this));
        if (balance <= totalLiabilities) return 0;
        return balance - totalLiabilities;
    }

    function maxChargesForPeriod(uint32 period) public view returns (uint32) {
        if (period == MONTHLY_PERIOD) return maxMonthlyCharges;
        if (period == ANNUAL_PERIOD) return maxAnnualCharges;
        if (period == ONE_TIME_PERIOD) return 1;
        revert InvalidPeriod();
    }

    function _subscribe(address payer, uint256 planId, bytes32 entitlementHash, uint32 maxCharges)
        internal
        returns (uint256 subscriptionId)
    {
        if (entitlementHash == bytes32(0)) revert InvalidEntitlementHash();
        if (
            subscriptionByEntitlementHash[entitlementHash] != 0
                || retiredEntitlementHashes[entitlementHash]
        ) {
            revert EntitlementAlreadyUsed();
        }

        Plan storage plan = _plan(planId);
        _requireNewSalesEnabled(plan);
        _validateChargeCount(plan.period, maxCharges);

        Tier tier = effectiveTier(plan.developer);
        uint16 feeBps = _feeBps(tier);
        usdc.safeTransferFrom(payer, address(this), plan.price);

        subscriptionId = nextSubscriptionId++;
        uint64 paidThrough = plan.period == ONE_TIME_PERIOD
            ? ONE_TIME_PAID_THROUGH
            : (block.timestamp + plan.period).toUint64();
        subscriptions[subscriptionId] = Subscription({
            planId: planId,
            payer: payer,
            entitlementHash: entitlementHash,
            paidThrough: paidThrough,
            remainingCharges: maxCharges - 1,
            cancelled: false
        });
        subscriptionByEntitlementHash[entitlementHash] = subscriptionId;

        emit SubscriptionCreated(subscriptionId, planId, payer, entitlementHash);
        _allocateCustomerPayment(
            subscriptionId, plan.developer, payer, plan.price, tier, feeBps, paidThrough
        );
        _assertSolvent();
    }

    function _allocateCustomerPayment(
        uint256 subscriptionId,
        address developer,
        address payer,
        uint256 gross,
        Tier tier,
        uint16 feeBps,
        uint64 paidThrough
    ) internal {
        uint256 fee = _feeFor(tier, gross);
        uint256 net = gross - fee;

        developerClaimable[developer] += net;
        totalDeveloperLiability += net;
        platformClaimable += fee;
        totalLiabilities += gross;
        lifetimeGrossVolume += gross;
        lifetimeTransactionFees += fee;

        emit CustomerPaymentSettled(
            subscriptionId, developer, payer, gross, fee, net, tier, feeBps, paidThrough
        );
    }

    function _activateTier(
        Developer storage account,
        address developer,
        Tier tier,
        bool fromBalance
    ) internal {
        uint256 remaining = account.tierPaidThrough > block.timestamp
            ? account.tierPaidThrough - block.timestamp
            : 0;
        if (account.selectedTier == Tier.Pro && tier == Tier.Studio) {
            remaining = Math.mulDiv(remaining, PRO_PRICE, STUDIO_PRICE);
        }
        account.selectedTier = tier;
        account.tierPaidThrough = (block.timestamp + remaining + TIER_PERIOD).toUint64();
        emit DeveloperTierActivated(developer, tier, account.tierPaidThrough, fromBalance);
    }

    function _withdrawDeveloper(address developer, uint256 amount) internal {
        Developer storage account = _registeredDeveloper(developer);
        uint256 claimable = developerClaimable[developer];
        if (amount == 0) revert InvalidAmount();
        if (amount > claimable) revert InsufficientClaimable();

        developerClaimable[developer] = claimable - amount;
        totalDeveloperLiability -= amount;
        totalLiabilities -= amount;
        usdc.safeTransfer(account.payoutWallet, amount);

        emit DeveloperWithdrawal(developer, account.payoutWallet, amount);
        _assertSolvent();
    }

    function _withdrawPlatform(uint256 amount) internal {
        if (msg.sender != treasury) revert NotTreasury();
        if (amount == 0) revert InvalidAmount();
        if (amount > platformClaimable) revert InsufficientClaimable();

        platformClaimable -= amount;
        totalLiabilities -= amount;
        usdc.safeTransfer(treasury, amount);

        emit PlatformWithdrawal(treasury, amount);
        _assertSolvent();
    }

    function _registeredDeveloper(address developer)
        internal
        view
        returns (Developer storage account)
    {
        account = developers[developer];
        if (!account.registered) revert DeveloperNotRegistered();
    }

    function _plan(uint256 planId) internal view returns (Plan storage plan) {
        plan = plans[planId];
        if (plan.developer == address(0)) revert PlanNotFound();
    }

    function _ownedPlan(uint256 planId, address developer)
        internal
        view
        returns (Plan storage plan)
    {
        plan = _plan(planId);
        if (plan.developer != developer) revert NotPlanDeveloper();
    }

    function _subscription(uint256 subscriptionId)
        internal
        view
        returns (Subscription storage subscription)
    {
        subscription = subscriptions[subscriptionId];
        if (subscription.payer == address(0)) revert SubscriptionNotFound();
    }

    function _requireNewSalesEnabled(Plan storage plan) internal view {
        Developer storage account = developers[plan.developer];
        if (
            !plan.newSalesEnabled || !account.newSalesEnabled
                || developerSalesSuspended[plan.developer]
        ) {
            revert NotRenewable();
        }
    }

    function _requireRenewalsEnabled(Plan storage plan) internal view {
        Developer storage account = developers[plan.developer];
        if (
            !plan.renewalsEnabled || !account.renewalsEnabled
                || developerRenewalsSuspended[plan.developer]
        ) {
            revert NotRenewable();
        }
    }

    function _validateChargeCount(uint32 period, uint32 maxCharges) internal view {
        if (maxCharges == 0 || maxCharges > maxChargesForPeriod(period)) {
            revert AuthorizationLimitExceeded();
        }
    }

    function _tierPrice(Tier tier) internal pure returns (uint256) {
        if (tier == Tier.Pro) return PRO_PRICE;
        if (tier == Tier.Studio) return STUDIO_PRICE;
        revert InvalidTier();
    }

    function _validateTierTransition(Developer storage account, Tier tier) internal view {
        if (
            account.tierPaidThrough >= block.timestamp && account.selectedTier == Tier.Studio
                && tier == Tier.Pro
        ) {
            revert TierDowngradeNotAllowed();
        }
    }

    function _feeFor(Tier tier, uint256 gross) internal pure returns (uint256) {
        uint256 fee = Math.mulDiv(gross, _feeBps(tier), BPS_DENOMINATOR);
        return tier == Tier.Free ? fee + FREE_FIXED_FEE : fee;
    }

    function _feeBps(Tier tier) internal pure returns (uint16) {
        if (tier == Tier.Pro) return PRO_FEE_BPS;
        if (tier == Tier.Studio) return STUDIO_FEE_BPS;
        return FREE_FEE_BPS;
    }

    function _tryTransferFrom(address from, uint256 amount) internal returns (bool) {
        (bool success, bytes memory returnData) =
            address(usdc).call(abi.encodeCall(IERC20.transferFrom, (from, address(this), amount)));
        if (!success) return false;
        if (returnData.length == 0) return true;
        if (returnData.length != 32) return false;
        uint256 returnedValue;
        assembly ("memory-safe") {
            returnedValue := mload(add(returnData, 0x20))
        }
        return returnedValue == 1;
    }

    function _requirePaymentsActive() internal view {
        if (paymentsPaused) revert PaymentsArePaused();
    }

    function _assertSolvent() internal view {
        if (usdc.balanceOf(address(this)) < totalLiabilities) revert Insolvent();
        if (totalLiabilities != totalDeveloperLiability + platformClaimable) {
            revert Insolvent();
        }
    }
}
