// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IVaultAdmin } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultAdmin.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/vault/IRateProvider.sol";

import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BasePoolMath } from "@balancer-labs/v3-solidity-utils/contracts/math/BasePoolMath.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";

import { PoolMock } from "../../contracts/test/PoolMock.sol";
import { DynamicFeePoolMock } from "../../contracts/test/DynamicFeePoolMock.sol";

import { BaseVaultTest } from "./utils/BaseVaultTest.sol";

contract LiquidityApproximationDynamicFeeTest is BaseVaultTest {
    using ArrayHelpers for *;
    using FixedPoint for *;

    address internal swapPool;
    address internal liquidityPool;
    // Allows small roundingDelta to account for rounding
    uint256 internal roundingDelta = 1e12;
    // The percentage delta of the swap fee, which is sufficiently large to compensate for
    // inaccuracies in liquidity approximations within the specified limits for these tests
    uint256 internal liquidityPercentageDelta = 25e16; // 25%
    uint256 internal swapFeePercentageDelta = 20e16; // 20%
    uint256 internal maxSwapFeePercentage = 0.1e18; // 10%
    uint256 internal maxAmount = 3e8 * 1e18 - 1;

    uint256 internal daiIdx;

    function setUp() public virtual override {
        defaultBalance = 1e10 * 1e18;
        BaseVaultTest.setUp();

        (daiIdx, ) = getSortedIndexes(address(dai), address(usdc));

        assertEq(dai.balanceOf(alice), dai.balanceOf(bob), "Bob and Alice DAI balances are not equal");
    }

    function createPool() internal virtual override returns (address) {
        address[] memory tokens = [address(dai), address(usdc)].toMemoryArray();

        liquidityPool = _createPool(tokens, "liquidityPool");
        swapPool = _createPool(tokens, "swapPool");

        // NOTE: stores address in `pool` (unused in this test)
        return address(0xdead);
    }

    function _createPool(address[] memory tokens, string memory label) internal virtual override returns (address) {
        DynamicFeePoolMock newPool = new DynamicFeePoolMock(
            IVault(address(vault)),
            "ERC20 Pool",
            "ERC20POOL",
            vault.buildTokenConfig(tokens.asIERC20(), new IRateProvider[](2)),
            true,
            365 days,
            address(0)
        );
        vm.label(address(newPool), label);
        return address(newPool);
    }

    function initPool() internal override {
        poolInitAmount = 1e9 * 1e18;

        vm.startPrank(lp);
        _initPool(swapPool, [poolInitAmount, poolInitAmount].toMemoryArray(), 0);
        _initPool(liquidityPool, [poolInitAmount, poolInitAmount].toMemoryArray(), 0);
        vm.stopPrank();
    }

    /// Add

    function testAddLiquidityUnbalanced__Fuzz(uint256 daiAmountIn, uint256 swapFeePercentage) public {
        daiAmountIn = bound(daiAmountIn, 1e18, maxAmount);
        // swap fee from 0% - 10%
        swapFeePercentage = bound(swapFeePercentage, 0, maxSwapFeePercentage);

        _setSwapFeePercentage(address(liquidityPool), swapFeePercentage);
        _setSwapFeePercentage(address(swapPool), swapFeePercentage);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[daiIdx] = uint256(daiAmountIn);

        vm.startPrank(alice);
        router.addLiquidityUnbalanced(address(liquidityPool), amountsIn, 0, false, bytes(""));

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );
        vm.stopPrank();

        vm.prank(bob);
        uint256 amountOut = router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            daiAmountIn - amountsOut[daiIdx],
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        assertLiquidityOperation(amountOut, swapFeePercentage, true);
    }

    function testAddLiquidityUnbalancedNoSwapFee__Fuzz(uint256 daiAmountIn) public {
        daiAmountIn = bound(daiAmountIn, 1e18, maxAmount);

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[daiIdx] = uint256(daiAmountIn);

        vm.startPrank(alice);
        router.addLiquidityUnbalanced(address(liquidityPool), amountsIn, 0, false, bytes(""));

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );
        vm.stopPrank();

        vm.prank(bob);
        router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            daiAmountIn - amountsOut[daiIdx],
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        assertLiquidityOperationNoSwapFee();
    }

    function testAddLiquiditySingleTokenExactOut__Fuzz(uint256 exactBptAmountOut, uint256 swapFeePercentage) public {
        exactBptAmountOut = bound(exactBptAmountOut, 1e18, maxAmount / 2 - 1);
        // swap fee from 0% - 10%
        swapFeePercentage = bound(swapFeePercentage, 0, maxSwapFeePercentage);

        _setSwapFeePercentage(address(liquidityPool), swapFeePercentage);
        _setSwapFeePercentage(address(swapPool), swapFeePercentage);

        vm.startPrank(alice);
        uint256 daiAmountIn = router.addLiquiditySingleTokenExactOut(
            address(liquidityPool),
            dai,
            1e50,
            exactBptAmountOut,
            false,
            bytes("")
        );

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );
        vm.stopPrank();

        vm.prank(bob);
        uint256 amountOut = router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            daiAmountIn - amountsOut[daiIdx],
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        assertLiquidityOperation(amountOut, swapFeePercentage, true);
    }

    function testAddLiquiditySingleTokenExactOutNoSwapFee__Fuzz(uint256 exactBptAmountOut) public {
        exactBptAmountOut = bound(exactBptAmountOut, 1e18, maxAmount / 2 - 1);

        vm.startPrank(alice);
        uint256 daiAmountIn = router.addLiquiditySingleTokenExactOut(
            address(liquidityPool),
            dai,
            1e50,
            exactBptAmountOut,
            false,
            bytes("")
        );

        uint256[] memory amountsOut = router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );
        vm.stopPrank();

        vm.prank(bob);
        router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            daiAmountIn - amountsOut[daiIdx],
            0,
            MAX_UINT256,
            false,
            bytes("")
        );

        assertLiquidityOperationNoSwapFee();
    }

    /// Remove

    function testRemoveLiquiditySingleTokenExact__Fuzz(uint256 exactAmountOut, uint256 swapFeePercentage) public {
        exactAmountOut = bound(exactAmountOut, 1e18, maxAmount);
        // swap fee from 0% - 10%
        swapFeePercentage = bound(swapFeePercentage, 0, maxSwapFeePercentage);

        _setSwapFeePercentage(address(liquidityPool), swapFeePercentage);
        _setSwapFeePercentage(address(swapPool), swapFeePercentage);

        // Add liquidity so we have something to remove
        vm.prank(alice);
        uint256 bptAmountOut = router.addLiquidityUnbalanced(
            address(liquidityPool),
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            bytes("")
        );

        vm.startPrank(alice);
        // test removeLiquiditySingleTokenExactOut
        router.removeLiquiditySingleTokenExactOut(
            address(liquidityPool),
            bptAmountOut,
            usdc,
            exactAmountOut,
            false,
            bytes("")
        );

        // remove remaining liquidity
        router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        vm.stopPrank();

        vm.startPrank(bob);
        // simulate the same outcome with a pure swap
        uint256 amountOut = router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            defaultBalance - dai.balanceOf(alice),
            0,
            MAX_UINT256,
            false,
            bytes("")
        );
        vm.stopPrank();

        assertLiquidityOperation(amountOut, swapFeePercentage, false);
    }

    function testRemoveLiquiditySingleTokenExactNoSwapFee__Fuzz(uint256 exactAmountOut) public {
        exactAmountOut = bound(exactAmountOut, 1e18, maxAmount);

        // Add liquidity so we have something to remove
        vm.prank(alice);
        uint256 bptAmountOut = router.addLiquidityUnbalanced(
            address(liquidityPool),
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            bytes("")
        );

        vm.startPrank(alice);
        // test removeLiquiditySingleTokenExactOut
        router.removeLiquiditySingleTokenExactOut(
            address(liquidityPool),
            bptAmountOut,
            usdc,
            exactAmountOut,
            false,
            bytes("")
        );

        // remove remaining liquidity
        router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        vm.stopPrank();

        vm.startPrank(bob);
        // simulate the same outcome with a pure swap
        router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            defaultBalance - dai.balanceOf(alice),
            0,
            MAX_UINT256,
            false,
            bytes("")
        );
        vm.stopPrank();

        assertLiquidityOperationNoSwapFee();
    }

    function testRemoveLiquiditySingleTokenExactIn__Fuzz(uint256 exactBptAmountIn, uint256 swapFeePercentage) public {
        exactBptAmountIn = bound(exactBptAmountIn, 1e18, maxAmount / 2 - 1);
        // swap fee from 0% - 10%
        swapFeePercentage = bound(swapFeePercentage, 0, maxSwapFeePercentage);

        _setSwapFeePercentage(address(liquidityPool), swapFeePercentage);
        _setSwapFeePercentage(address(swapPool), swapFeePercentage);

        // Add liquidity so we have something to remove
        vm.prank(alice);
        router.addLiquidityUnbalanced(
            address(liquidityPool),
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            bytes("")
        );

        vm.startPrank(alice);
        // test removeLiquiditySingleTokenExactIn
        router.removeLiquiditySingleTokenExactIn(address(liquidityPool), exactBptAmountIn, usdc, 1, false, bytes(""));

        // remove remaining liquidity
        router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        vm.stopPrank();

        vm.startPrank(bob);
        // simulate the same outcome with a pure swap
        uint256 amountOut = router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            defaultBalance - dai.balanceOf(alice),
            0,
            MAX_UINT256,
            false,
            bytes("")
        );
        vm.stopPrank();

        assertLiquidityOperation(amountOut, swapFeePercentage, false);
    }

    function testRemoveLiquiditySingleTokenExactInNoSwapFee__Fuzz(uint256 exactBptAmountIn) public {
        exactBptAmountIn = bound(exactBptAmountIn, 1e18, maxAmount / 2 - 1);

        // Add liquidity so we have something to remove
        vm.prank(alice);
        router.addLiquidityUnbalanced(
            address(liquidityPool),
            [maxAmount, maxAmount].toMemoryArray(),
            0,
            false,
            bytes("")
        );

        vm.startPrank(alice);
        // test removeLiquiditySingleTokenExactIn
        router.removeLiquiditySingleTokenExactIn(address(liquidityPool), exactBptAmountIn, usdc, 1, false, bytes(""));

        // remove remaining liquidity
        router.removeLiquidityProportional(
            address(liquidityPool),
            IERC20(liquidityPool).balanceOf(alice),
            [uint256(0), uint256(0)].toMemoryArray(),
            false,
            bytes("")
        );

        vm.stopPrank();

        vm.startPrank(bob);
        // simulate the same outcome with a pure swap
        router.swapSingleTokenExactIn(
            address(swapPool),
            dai,
            usdc,
            defaultBalance - dai.balanceOf(alice),
            0,
            MAX_UINT256,
            false,
            bytes("")
        );
        vm.stopPrank();

        assertLiquidityOperationNoSwapFee();
    }

    /// Utils

    function assertLiquidityOperationNoSwapFee() internal {
        // See @notice
        assertEq(dai.balanceOf(alice), dai.balanceOf(bob), "Bob and Alice DAI balances are not equal");

        uint256 aliceAmountOut = usdc.balanceOf(alice) - defaultBalance;
        uint256 bobAmountOut = usdc.balanceOf(bob) - defaultBalance;
        uint256 bobToAliceRatio = bobAmountOut.divDown(aliceAmountOut);

        // See @notice at `LiquidityApproximationTest`
        assertApproxEqAbs(aliceAmountOut, bobAmountOut, roundingDelta, "Swap fee delta is too big");

        // See @notice at `LiquidityApproximationTest`
        assertGe(bobToAliceRatio, 1e18, "Bob has less USDC compare to Alice");
        assertLe(bobToAliceRatio, 1e18 + roundingDelta, "Bob has too much USDC compare to Alice");

        // Alice and Bob have no BPT tokens
        assertEq(PoolMock(swapPool).balanceOf(alice), 0, "Alice should have 0 BPT");
        assertEq(PoolMock(liquidityPool).balanceOf(alice), 0, "Alice should have 0 BPT");
        assertEq(PoolMock(swapPool).balanceOf(bob), 0, "Bob should have 0 BPT");
        assertEq(PoolMock(liquidityPool).balanceOf(bob), 0, "Bob should have 0 BPT");
    }

    function assertLiquidityOperation(uint256 amountOut, uint256 swapFeePercentage, bool addLiquidity) internal {
        // See @notice
        assertEq(dai.balanceOf(alice), dai.balanceOf(bob), "Bob and Alice DAI balances are not equal");

        uint256 aliceAmountOut = usdc.balanceOf(alice) - defaultBalance;
        uint256 bobAmountOut = usdc.balanceOf(bob) - defaultBalance;
        uint256 bobToAliceRatio = bobAmountOut.divDown(aliceAmountOut);

        uint256 liquidityTaxPercentage = liquidityPercentageDelta.mulDown(swapFeePercentage);

        uint256 swapFee = amountOut.divUp(swapFeePercentage.complement()) - amountOut;

        // See @notice at `LiquidityApproximationTest`
        assertApproxEqAbs(
            aliceAmountOut,
            bobAmountOut,
            swapFee.mulDown(swapFeePercentageDelta) + roundingDelta,
            "Swap fee delta is too big"
        );

        // See @notice at `LiquidityApproximationTest`
        assertGe(
            bobToAliceRatio,
            1e18 - (addLiquidity ? liquidityTaxPercentage : 0) - roundingDelta,
            "Bob has too little USDC compare to Alice"
        );
        assertLe(
            bobToAliceRatio,
            1e18 + (addLiquidity ? 0 : liquidityTaxPercentage) + roundingDelta,
            "Bob has too much USDC compare to Alice"
        );
    }

    function _setSwapFeePercentage(address pool, uint256 swapFeePercentage) internal virtual override {
        DynamicFeePoolMock(pool).setSwapFeePercentage(swapFeePercentage);
    }
}