// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import { Script } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { AddonPassV1 } from "../src/AddonPassV1.sol";

contract DeployAddonPassV1 is Script {
    uint256 private constant BASE_CHAIN_ID = 8453;
    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;

    error UnsupportedDeploymentChain(uint256 chainId);
    error DeploymentValueOutOfRange(string variableName);
    error UnapprovedMainnetConfiguration();

    function run() external returns (AddonPassV1 deployment) {
        if (
            block.chainid != BASE_CHAIN_ID && block.chainid != BASE_SEPOLIA_CHAIN_ID
                && block.chainid != 31337
        ) {
            revert UnsupportedDeploymentChain(block.chainid);
        }

        IERC20 usdc = IERC20(vm.envAddress("USDC_ADDRESS"));
        address initialOwner = vm.envAddress("CONTRACT_OWNER");
        address treasury = vm.envAddress("TREASURY_ADDRESS");
        address guardian = vm.envAddress("GUARDIAN_ADDRESS");
        uint96 minPlanPrice =
            _toUint96(vm.envUint("MIN_PLAN_PRICE_ATOMIC"), "MIN_PLAN_PRICE_ATOMIC");
        uint96 maxPlanPrice =
            _toUint96(vm.envUint("MAX_PLAN_PRICE_ATOMIC"), "MAX_PLAN_PRICE_ATOMIC");
        uint32 maxMonthlyCharges =
            _toUint32(vm.envUint("MAX_MONTHLY_CHARGES"), "MAX_MONTHLY_CHARGES");
        uint32 maxAnnualCharges = _toUint32(vm.envUint("MAX_ANNUAL_CHARGES"), "MAX_ANNUAL_CHARGES");

        // D33 fixes these values. The operator must separately verify the approved
        // owner address is the intended Base 2-of-3 Safe before broadcasting.
        if (
            block.chainid == BASE_CHAIN_ID
                && (minPlanPrice != 0.5e6
                    || maxPlanPrice != 10_000e6
                    || maxMonthlyCharges != 12
                    || maxAnnualCharges != 1
                    || initialOwner != treasury
                    || initialOwner.code.length == 0
                    || guardian == address(0)
                    || guardian == initialOwner)
        ) revert UnapprovedMainnetConfiguration();

        vm.startBroadcast();
        deployment = new AddonPassV1(
            usdc,
            initialOwner,
            treasury,
            guardian,
            minPlanPrice,
            maxPlanPrice,
            maxMonthlyCharges,
            maxAnnualCharges
        );
        vm.stopBroadcast();
    }

    function _toUint96(uint256 value, string memory variableName) private pure returns (uint96) {
        if (value > type(uint96).max) revert DeploymentValueOutOfRange(variableName);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint96(value);
    }

    function _toUint32(uint256 value, string memory variableName) private pure returns (uint32) {
        if (value > type(uint32).max) revert DeploymentValueOutOfRange(variableName);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(value);
    }
}
