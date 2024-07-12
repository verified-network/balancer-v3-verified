// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IAuthentication } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IAuthentication.sol";
import { IBasePoolFactory } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePoolFactory.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";

import { BaseVaultTest } from "@balancer-labs/v3-vault/test/foundry/utils/BaseVaultTest.sol";
import { PoolMock } from "@balancer-labs/v3-vault/contracts/test/PoolMock.sol";

import { BasePoolFactoryMock } from "../../contracts/test/BasePoolFactoryMock.sol";

contract BasePoolFactoryTest is BaseVaultTest {
    using ArrayHelpers for *;

    BasePoolFactoryMock internal testFactory;

    function setUp() public override {
        BaseVaultTest.setUp();

        testFactory = new BasePoolFactoryMock(IVault(address(vault)), 365 days, type(PoolMock).creationCode);
    }

    function testConstructor() public {
        bytes memory creationCode = type(PoolMock).creationCode;
        uint32 pauseWindowDuration = 365 days;

        BasePoolFactoryMock newFactory = new BasePoolFactoryMock(
            IVault(address(vault)),
            pauseWindowDuration,
            creationCode
        );

        assertEq(newFactory.getPauseWindowDuration(), pauseWindowDuration, "pauseWindowDuration is wrong");
        assertEq(newFactory.getCreationCode(), creationCode, "creationCode is wrong");
        assertEq(address(newFactory.getVault()), address(vault), "Vault is wrong");
    }

    function testDisableNoAuthentication() public {
        vm.expectRevert(IAuthentication.SenderNotAllowed.selector);
        testFactory.disable();
    }

    function testDisable() public {
        authorizer.grantRole(testFactory.getActionId(IBasePoolFactory.disable.selector), admin);

        assertFalse(testFactory.isDisabled(), "Factory is disabled");

        vm.prank(admin);
        testFactory.disable();

        assertTrue(testFactory.isDisabled(), "Factory is enabled");
    }

    function testEnsureEnabled() public {
        authorizer.grantRole(testFactory.getActionId(IBasePoolFactory.disable.selector), admin);

        assertFalse(testFactory.isDisabled(), "Factory is disabled");
        // Should pass, since factory is enabled.
        testFactory.manualEnsureEnabled();

        vm.prank(admin);
        testFactory.disable();

        // Should revert, since factory is disabled.
        vm.expectRevert(IBasePoolFactory.Disabled.selector);
        testFactory.manualEnsureEnabled();
    }

    function testRegisterPoolWithFactoryDisabled() public {
        // Disable factory.
        authorizer.grantRole(testFactory.getActionId(IBasePoolFactory.disable.selector), admin);
        vm.prank(admin);
        testFactory.disable();

        address newPool = address(new PoolMock(IVault(address(vault)), "Test Pool", "TEST"));
        vm.expectRevert(IBasePoolFactory.Disabled.selector);
        testFactory.manualRegisterPoolWithFactory(newPool);
    }

    function testRegisterPoolWithFactory() public {
        address newPool = address(new PoolMock(IVault(address(vault)), "Test Pool", "TEST"));

        assertFalse(testFactory.isPoolFromFactory(newPool), "Pool is already registered with factory");

        testFactory.manualRegisterPoolWithFactory(newPool);

        assertTrue(testFactory.isPoolFromFactory(newPool), "Pool is not registered with factory");
    }

    function testRegisterPoolWithVault() public {
        address newPool = address(new PoolMock(IVault(address(vault)), "Test Pool", "TEST"));
        TokenConfig[] memory newTokens = vault.buildTokenConfig(
            [address(dai), address(usdc)].toMemoryArray().asIERC20()
        );
        uint256 newSwapFeePercentage = 0;
        bool protocolFeeExempt = false;
        PoolRoleAccounts memory roleAccounts;
        address hooksContract = address(0);
        LiquidityManagement memory liquidityManagement;

        assertFalse(vault.isPoolRegistered(newPool), "Pool is already registered with vault");

        testFactory.manualRegisterPoolWithVault(
            newPool,
            newTokens,
            newSwapFeePercentage,
            protocolFeeExempt,
            roleAccounts,
            hooksContract,
            liquidityManagement
        );

        assertTrue(vault.isPoolRegistered(newPool), "Pool is not registered with vault");
    }

    function testCreate() public {
        string memory name = "Test Pool Create";
        string memory symbol = "TEST_CREATE";
        address newPool = testFactory.manualCreate(name, symbol, ZERO_BYTES32);

        assertEq(PoolMock(newPool).name(), name, "Pool name is wrong");
        assertEq(PoolMock(newPool).symbol(), symbol, "Pool symbol is wrong");
        assertTrue(testFactory.isPoolFromFactory(newPool), "Pool is not registered with factory");
    }

    function testGetDeploymentAddress() public {
        string memory name = "Test Deployment Address";
        string memory symbol = "DEPLOYMENT_ADDRESS";
        bytes32 salt = keccak256(abi.encode("abc"));

        address predictedAddress = testFactory.getDeploymentAddress(salt);
        address newPool = testFactory.manualCreate(name, symbol, salt);
        assertEq(newPool, predictedAddress, "predictedAddress is wrong");
    }

    function testGetDefaultPoolHooksContract() public view {
        assertEq(testFactory.getDefaultPoolHooksContract(), address(0), "Wrong hooks contract");
    }

    function testGetDefaultLiquidityManagement() public {
        LiquidityManagement memory liquidityManagement = testFactory.getDefaultLiquidityManagement();

        assertFalse(liquidityManagement.enableDonation, "enableDonation is wrong");
        assertFalse(liquidityManagement.disableUnbalancedLiquidity, "disableUnbalancedLiquidity is wrong");
        assertFalse(liquidityManagement.enableAddLiquidityCustom, "enableAddLiquidityCustom is wrong");
        assertFalse(liquidityManagement.enableRemoveLiquidityCustom, "enableRemoveLiquidityCustom is wrong");
    }
}
