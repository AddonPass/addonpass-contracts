// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Test } from "forge-std/Test.sol";

import { DeployAddonPassV1 } from "../script/DeployAddonPassV1.s.sol";
import { AddonPassV1 } from "../src/AddonPassV1.sol";
import { MockUSDC } from "./mocks/MockUSDC.sol";

contract DeploymentConfigurationTest is Test {
    address private constant OWNER = address(0x1001);
    address private constant GUARDIAN = address(0x1003);
    address private constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    DeployAddonPassV1 private deployer;

    function setUp() public {
        vm.chainId(8453);
        deployer = new DeployAddonPassV1();
        MockUSDC token = new MockUSDC();
        vm.etch(USDC, address(token).code);
        // Only contract presence is checked here; Safe identity and threshold
        // require separate deployed acceptance with the approved addresses.
        vm.etch(OWNER, hex"00");
        vm.setEnv("USDC_ADDRESS", vm.toString(USDC));
        vm.setEnv("CONTRACT_OWNER", vm.toString(OWNER));
        vm.setEnv("TREASURY_ADDRESS", vm.toString(OWNER));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(GUARDIAN));
        vm.setEnv("MIN_PLAN_PRICE_ATOMIC", "500000");
        vm.setEnv("MAX_PLAN_PRICE_ATOMIC", "10000000000");
        vm.setEnv("MAX_MONTHLY_CHARGES", "12");
        vm.setEnv("MAX_ANNUAL_CHARGES", "1");
    }

    // Environment cheatcodes are process-wide, so exercise mutations serially.
    function testMainnetConfigurationChecksBeforeBroadcast() public {
        _rejectChangedBounds();
        _requireSharedOwnerTreasuryAndSeparateGuardian();
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(GUARDIAN));
        vm.etch(OWNER, hex"");
        vm.expectRevert(DeployAddonPassV1.UnapprovedMainnetConfiguration.selector);
        deployer.run();
        vm.etch(OWNER, hex"00");
        AddonPassV1 deployment = deployer.run();
        assertEq(deployment.minPlanPrice(), 0.5e6);
        assertEq(deployment.maxPlanPrice(), 10_000e6);
        assertEq(deployment.maxMonthlyCharges(), 12);
        assertEq(deployment.maxAnnualCharges(), 1);
        assertEq(deployment.owner(), OWNER);
        assertEq(deployment.treasury(), OWNER);
        assertEq(deployment.guardian(), GUARDIAN);
    }

    function _rejectChangedBounds() private {
        string[4] memory names = [
            "MIN_PLAN_PRICE_ATOMIC",
            "MAX_PLAN_PRICE_ATOMIC",
            "MAX_MONTHLY_CHARGES",
            "MAX_ANNUAL_CHARGES"
        ];
        string[4] memory invalid = ["499999", "10000000001", "13", "2"];
        string[4] memory approved = ["500000", "10000000000", "12", "1"];
        for (uint256 i; i < names.length; ++i) {
            vm.setEnv(names[i], invalid[i]);
            vm.expectRevert(DeployAddonPassV1.UnapprovedMainnetConfiguration.selector);
            deployer.run();
            vm.setEnv(names[i], approved[i]);
        }
    }

    function _requireSharedOwnerTreasuryAndSeparateGuardian() private {
        vm.setEnv("TREASURY_ADDRESS", vm.toString(GUARDIAN));
        vm.expectRevert(DeployAddonPassV1.UnapprovedMainnetConfiguration.selector);
        deployer.run();
        vm.setEnv("TREASURY_ADDRESS", vm.toString(OWNER));
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(OWNER));
        vm.expectRevert(DeployAddonPassV1.UnapprovedMainnetConfiguration.selector);
        deployer.run();
        vm.setEnv("GUARDIAN_ADDRESS", vm.toString(address(0)));
        vm.expectRevert(DeployAddonPassV1.UnapprovedMainnetConfiguration.selector);
        deployer.run();
    }
}
