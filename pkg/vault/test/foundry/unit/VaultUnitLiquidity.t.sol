// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "forge-std/console.sol";

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IBasePool } from "@balancer-labs/v3-interfaces/contracts/vault/IBasePool.sol";
import { IVaultErrors } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultErrors.sol";
import { IPoolLiquidity } from "@balancer-labs/v3-interfaces/contracts/vault/IPoolLiquidity.sol";
import { IVaultEvents } from "@balancer-labs/v3-interfaces/contracts/vault/IVaultEvents.sol";
import { PoolConfig } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";

import { BalancerPoolToken } from "@balancer-labs/v3-vault/contracts/BalancerPoolToken.sol";
import { EnumerableMap } from "@balancer-labs/v3-solidity-utils/contracts/openzeppelin/EnumerableMap.sol";
import { ArrayHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ArrayHelpers.sol";
import { ScalingHelpers } from "@balancer-labs/v3-solidity-utils/contracts/helpers/ScalingHelpers.sol";
import { FixedPoint } from "@balancer-labs/v3-solidity-utils/contracts/math/FixedPoint.sol";
import { BasePoolMath } from "@balancer-labs/v3-solidity-utils/contracts/math/BasePoolMath.sol";

import { IVaultMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import { BaseTest } from "@balancer-labs/v3-solidity-utils/test/foundry/utils/BaseTest.sol";
import { VaultMockDeployer } from "@balancer-labs/v3-vault/test/foundry/utils/VaultMockDeployer.sol";

contract VaultUnitLiquidityTest is BaseTest {
    using ArrayHelpers for *;
    using ScalingHelpers for *;
    using FixedPoint for *;
    using EnumerableMap for EnumerableMap.IERC20ToBytes32Map;

    // #region Test structs

    struct TestAddLiquidityParams {
        AddLiquidityParams addLiquidityParams;
        uint256[] expectedAmountsInScaled18;
        uint256[] maxAmountsInScaled18;
        uint256[] expectSwapFeeAmountsScaled18;
        uint256 expectedBPTAmountOut;
    }

    struct TestRemoveLiquidityParams {
        RemoveLiquidityParams removeLiquidityParams;
        uint256[] expectedAmountsOutScaled18;
        uint256[] minAmountsOutScaled18;
        uint256[] expectSwapFeeAmountsScaled18;
        uint256 expectedBPTAmountIn;
    }
    // #endregion

    address internal constant ZERO_ADDRESS = address(0x00);

    IVaultMock internal vault;

    address pool = address(0x1234);
    uint256 initTotalSupply = 1000e18;
    uint256 swapFeePercentage = 1e16;

    function setUp() public virtual override {
        BaseTest.setUp();
        vault = IVaultMock(address(VaultMockDeployer.deploy()));

        _mockMintCallback(address(this), initTotalSupply);
        vault.mintERC20(pool, address(this), initTotalSupply);

        uint256[] memory initialBalances = new uint256[](tokens.length);
        vault.manualSetPoolTokenBalances(pool, tokens, initialBalances);

        /* TODO for (uint256 i = 0; i < tokens.length; i++) {
            vault.manualSetPoolCreatorFees(pool, tokens[i], 0);
        }*/
    }

    // #region AddLiquidity tests
    function testAddLiquidityProportional() public {
        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.PROPORTIONAL,
            1e18
        );

        _testAddLiquidity(
            poolData,
            TestAddLiquidityParams({
                addLiquidityParams: params,
                expectedAmountsInScaled18: BasePoolMath.computeProportionalAmountsIn(
                    poolData.balancesLiveScaled18,
                    vault.totalSupply(params.pool),
                    params.minBptAmountOut
                ),
                maxAmountsInScaled18: maxAmountsInScaled18,
                expectSwapFeeAmountsScaled18: new uint256[](tokens.length),
                expectedBPTAmountOut: params.minBptAmountOut
            })
        );
    }

    function testAddLiquidityUnbalanced() public {
        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.UNBALANCED,
            1e18
        );

        // mock invariants
        (uint256 currentInvariant, uint256 newInvariantAndInvariantWithFeesApplied) = (1e16, 1e18);
        vm.mockCall(
            params.pool,
            abi.encodeWithSelector(IBasePool.computeInvariant.selector, poolData.balancesLiveScaled18),
            abi.encode(currentInvariant)
        );

        uint256[] memory newBalances = new uint256[](tokens.length);
        for (uint256 i = 0; i < newBalances.length; i++) {
            newBalances[i] = poolData.balancesLiveScaled18[i] + maxAmountsInScaled18[i];
        }

        vm.mockCall(
            params.pool,
            abi.encodeWithSelector(IBasePool.computeInvariant.selector, newBalances),
            abi.encode(newInvariantAndInvariantWithFeesApplied)
        );

        (uint256 bptAmountOut, uint256[] memory swapFeeAmountsScaled18) = BasePoolMath.computeAddLiquidityUnbalanced(
            poolData.balancesLiveScaled18,
            maxAmountsInScaled18,
            vault.totalSupply(params.pool),
            swapFeePercentage,
            IBasePool(params.pool).computeInvariant
        );

        _testAddLiquidity(
            poolData,
            TestAddLiquidityParams({
                addLiquidityParams: params,
                expectedAmountsInScaled18: maxAmountsInScaled18,
                maxAmountsInScaled18: maxAmountsInScaled18,
                expectSwapFeeAmountsScaled18: swapFeeAmountsScaled18,
                expectedBPTAmountOut: bptAmountOut
            })
        );
    }

    function testAddLiquiditySingleTokenExactOut() public {
        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, ) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
            1e18
        );

        uint256 tokenInIndex = 0;
        uint256[] memory expectedAmountsInScaled18 = new uint256[](tokens.length);
        uint256[] memory maxAmountsInScaled18 = new uint256[](tokens.length);
        maxAmountsInScaled18[tokenInIndex] = 1e18;
        params.maxAmountsIn[tokenInIndex] = maxAmountsInScaled18[tokenInIndex].toRawUndoRateRoundUp(
            poolData.decimalScalingFactors[tokenInIndex],
            poolData.tokenRates[tokenInIndex]
        );

        uint256 totalSupply = vault.totalSupply(params.pool);
        uint256 newSupply = totalSupply + params.minBptAmountOut;
        vm.mockCall(
            params.pool,
            abi.encodeWithSelector(
                IBasePool.computeBalance.selector,
                poolData.balancesLiveScaled18,
                tokenInIndex,
                newSupply.divUp(totalSupply)
            ),
            abi.encode(newSupply)
        );

        uint256[] memory swapFeeAmountsScaled18;
        (expectedAmountsInScaled18[0], swapFeeAmountsScaled18) = BasePoolMath.computeAddLiquiditySingleTokenExactOut(
            poolData.balancesLiveScaled18,
            0,
            params.minBptAmountOut,
            totalSupply,
            swapFeePercentage,
            IBasePool(params.pool).computeBalance
        );

        _testAddLiquidity(
            poolData,
            TestAddLiquidityParams({
                addLiquidityParams: params,
                expectedAmountsInScaled18: expectedAmountsInScaled18,
                maxAmountsInScaled18: maxAmountsInScaled18,
                expectSwapFeeAmountsScaled18: swapFeeAmountsScaled18,
                expectedBPTAmountOut: params.minBptAmountOut
            })
        );
    }

    function testAddLiquidityCustom() public {
        uint256 bptAmountOut = 1e18;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.CUSTOM,
            bptAmountOut
        );

        poolData.poolConfig.liquidityManagement.enableAddLiquidityCustom = true;

        uint256[] memory expectedAmountsInScaled18 = new uint256[](tokens.length);
        uint256[] memory expectSwapFeeAmountsScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            expectedAmountsInScaled18[i] = 1e18;
            expectSwapFeeAmountsScaled18[i] = 1e16;
        }

        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onAddLiquidityCustom.selector,
                params.to,
                maxAmountsInScaled18,
                params.minBptAmountOut,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(expectedAmountsInScaled18, bptAmountOut, expectSwapFeeAmountsScaled18, params.userData)
        );

        _testAddLiquidity(
            poolData,
            TestAddLiquidityParams({
                addLiquidityParams: params,
                expectedAmountsInScaled18: expectedAmountsInScaled18,
                maxAmountsInScaled18: maxAmountsInScaled18,
                expectSwapFeeAmountsScaled18: expectSwapFeeAmountsScaled18,
                expectedBPTAmountOut: params.minBptAmountOut
            })
        );
    }

    function testRevertIfBptAmountOutBelowMin() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.CUSTOM,
            1e18
        );

        poolData.poolConfig.liquidityManagement.enableAddLiquidityCustom = true;

        uint256 bptAmountOut = 0;
        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onAddLiquidityCustom.selector,
                params.to,
                maxAmountsInScaled18,
                params.minBptAmountOut,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(new uint256[](tokens.length), bptAmountOut, new uint256[](tokens.length), params.userData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.BptAmountOutBelowMin.selector, bptAmountOut, params.minBptAmountOut)
        );
        vault.manualAddLiquidity(poolData, params, maxAmountsInScaled18, vaultState);
    }

    function testRevertIfAmountInAboveMax() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.CUSTOM,
            1e18
        );

        poolData.poolConfig.liquidityManagement.enableAddLiquidityCustom = true;

        uint256[] memory expectedAmountsInScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            expectedAmountsInScaled18[i] = maxAmountsInScaled18[i] + 1;
        }

        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onAddLiquidityCustom.selector,
                params.to,
                maxAmountsInScaled18,
                params.minBptAmountOut,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(expectedAmountsInScaled18, params.minBptAmountOut, new uint256[](tokens.length), params.userData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultErrors.AmountInAboveMax.selector,
                tokens[0],
                expectedAmountsInScaled18[0],
                maxAmountsInScaled18[0]
            )
        );
        vault.manualAddLiquidity(poolData, params, maxAmountsInScaled18, vaultState);
    }

    function testRevertAddLiquidityUnbalancedIfUnbalancedLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.UNBALANCED,
            1e18
        );

        poolData.poolConfig.liquidityManagement.disableUnbalancedLiquidity = true;

        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        vault.manualAddLiquidity(poolData, params, maxAmountsInScaled18, vaultState);
    }

    function testRevertAddLiquiditySingleTokenExactOutIfUnbalancedLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
            1e18
        );

        poolData.poolConfig.liquidityManagement.disableUnbalancedLiquidity = true;

        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        vault.manualAddLiquidity(poolData, params, maxAmountsInScaled18, vaultState);
    }

    function testRevertAddLiquidityCustomExactOutIfCustomLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) = _makeAddLiquidityParams(
            poolData,
            AddLiquidityKind.CUSTOM,
            1e18
        );

        vm.expectRevert(IVaultErrors.DoesNotSupportAddLiquidityCustom.selector);
        vault.manualAddLiquidity(poolData, params, maxAmountsInScaled18, vaultState);
    }

    // #endregion

    // #region RemoveLiquidity tests
    function testRemoveLiquidityProportional() public {
        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.PROPORTIONAL,
            1e18,
            1
        );

        _testRemoveLiquidity(
            poolData,
            TestRemoveLiquidityParams({
                removeLiquidityParams: params,
                expectedAmountsOutScaled18: BasePoolMath.computeProportionalAmountsOut(
                    poolData.balancesLiveScaled18,
                    vault.totalSupply(params.pool),
                    params.maxBptAmountIn
                ),
                minAmountsOutScaled18: minAmountsOutScaled18,
                expectSwapFeeAmountsScaled18: new uint256[](tokens.length),
                expectedBPTAmountIn: params.maxBptAmountIn
            })
        );
    }

    function testRemoveLiquiditySingleTokenExactIn() public {
        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            1e18,
            0
        );

        uint256 tokenIndex = 0;
        uint256 expectBPTAmountIn = params.maxBptAmountIn;

        params.minAmountsOut[tokenIndex] = 1e18;
        minAmountsOutScaled18[tokenIndex] = params.minAmountsOut[tokenIndex].toScaled18ApplyRateRoundDown(
            poolData.decimalScalingFactors[tokenIndex],
            poolData.tokenRates[tokenIndex]
        );

        uint256[] memory expectedAmountsOutScaled18 = new uint256[](tokens.length);
        uint256[] memory swapFeeAmountsScaled18 = new uint256[](tokens.length);
        uint256 totalSupply = vault.totalSupply(params.pool);
        uint256 newSupply = totalSupply - expectBPTAmountIn;
        vm.mockCall(
            params.pool,
            abi.encodeWithSelector(
                IBasePool.computeBalance.selector,
                poolData.balancesLiveScaled18,
                tokenIndex,
                newSupply.divUp(totalSupply)
            ),
            abi.encode(newSupply)
        );

        (expectedAmountsOutScaled18[tokenIndex], swapFeeAmountsScaled18) = BasePoolMath
            .computeRemoveLiquiditySingleTokenExactIn(
                poolData.balancesLiveScaled18,
                tokenIndex,
                expectBPTAmountIn,
                totalSupply,
                swapFeePercentage,
                IBasePool(params.pool).computeBalance
            );

        _testRemoveLiquidity(
            poolData,
            TestRemoveLiquidityParams({
                removeLiquidityParams: params,
                expectedAmountsOutScaled18: expectedAmountsOutScaled18,
                minAmountsOutScaled18: minAmountsOutScaled18,
                expectSwapFeeAmountsScaled18: swapFeeAmountsScaled18,
                expectedBPTAmountIn: expectBPTAmountIn
            })
        );
    }

    function testRemoveLiquiditySingleTokenExactOut() public {
        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
            type(uint256).max,
            0
        );

        uint256 tokenIndex = 0;
        params.minAmountsOut[tokenIndex] = 2e18;
        minAmountsOutScaled18[tokenIndex] = params.minAmountsOut[tokenIndex].toScaled18ApplyRateRoundDown(
            poolData.decimalScalingFactors[tokenIndex],
            poolData.tokenRates[tokenIndex]
        );

        // mock invariants
        {
            (uint256 currentInvariant, uint256 invariantAndInvariantWithFeesApplied) = (3e8, 3e9);
            vm.mockCall(
                params.pool,
                abi.encodeWithSelector(IBasePool.computeInvariant.selector, poolData.balancesLiveScaled18),
                abi.encode(currentInvariant)
            );

            uint256[] memory newBalances = new uint256[](tokens.length);
            for (uint256 i = 0; i < newBalances.length; i++) {
                newBalances[i] = poolData.balancesLiveScaled18[i];
            }
            newBalances[tokenIndex] -= minAmountsOutScaled18[tokenIndex];

            vm.mockCall(
                params.pool,
                abi.encodeWithSelector(IBasePool.computeInvariant.selector, newBalances),
                abi.encode(invariantAndInvariantWithFeesApplied)
            );

            uint256 taxableAmount = invariantAndInvariantWithFeesApplied.divUp(currentInvariant).mulUp(
                poolData.balancesLiveScaled18[tokenIndex]
            ) - newBalances[tokenIndex];

            uint256 fee = taxableAmount.divUp(swapFeePercentage.complement()) - taxableAmount;
            newBalances[tokenIndex] -= fee;

            uint256 newInvariantAndInvariantWithFeesApplied = 1e5;
            vm.mockCall(
                params.pool,
                abi.encodeWithSelector(IBasePool.computeInvariant.selector, newBalances),
                abi.encode(newInvariantAndInvariantWithFeesApplied)
            );
        }

        (uint256 expectBPTAmountIn, uint256[] memory swapFeeAmountsScaled18) = BasePoolMath
            .computeRemoveLiquiditySingleTokenExactOut(
                poolData.balancesLiveScaled18,
                tokenIndex,
                minAmountsOutScaled18[tokenIndex],
                vault.totalSupply(params.pool),
                swapFeePercentage,
                IBasePool(params.pool).computeInvariant
            );

        _testRemoveLiquidity(
            poolData,
            TestRemoveLiquidityParams({
                removeLiquidityParams: params,
                expectedAmountsOutScaled18: minAmountsOutScaled18,
                minAmountsOutScaled18: minAmountsOutScaled18,
                expectSwapFeeAmountsScaled18: swapFeeAmountsScaled18,
                expectedBPTAmountIn: expectBPTAmountIn
            })
        );
    }

    function testRemoveLiquidityCustom() public {
        PoolData memory poolData = _makeDefaultParams();
        poolData.poolConfig.liquidityManagement.enableRemoveLiquidityCustom = true;

        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.CUSTOM,
            type(uint256).max,
            1
        );

        uint256 expectBPTAmountIn = 1e18;

        uint256[] memory expectedAmountsOutScaled18 = new uint256[](tokens.length);
        uint256[] memory expectSwapFeeAmountsScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            expectedAmountsOutScaled18[i] = 1e18;
            expectSwapFeeAmountsScaled18[i] = 1e16;
        }

        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onRemoveLiquidityCustom.selector,
                params.from,
                params.maxBptAmountIn,
                minAmountsOutScaled18,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(expectBPTAmountIn, expectedAmountsOutScaled18, expectSwapFeeAmountsScaled18, params.userData)
        );

        _testRemoveLiquidity(
            poolData,
            TestRemoveLiquidityParams({
                removeLiquidityParams: params,
                expectedAmountsOutScaled18: expectedAmountsOutScaled18,
                minAmountsOutScaled18: minAmountsOutScaled18,
                expectSwapFeeAmountsScaled18: expectSwapFeeAmountsScaled18,
                expectedBPTAmountIn: expectBPTAmountIn
            })
        );
    }

    function testRevertIfBptAmountInAboveMax() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.CUSTOM,
            1e18,
            0
        );
        poolData.poolConfig.liquidityManagement.enableRemoveLiquidityCustom = true;

        uint256 bptAmountIn = params.maxBptAmountIn + 1;

        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onRemoveLiquidityCustom.selector,
                params.from,
                params.maxBptAmountIn,
                minAmountsOutScaled18,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(bptAmountIn, new uint256[](tokens.length), new uint256[](tokens.length), params.userData)
        );

        vm.expectRevert(
            abi.encodeWithSelector(IVaultErrors.BptAmountInAboveMax.selector, bptAmountIn, params.maxBptAmountIn)
        );
        vault.manualRemoveLiquidity(poolData, params, minAmountsOutScaled18, vaultState);
    }

    function testRevertIfAmountOutBelowMin() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        uint256 defaultMinAmountOut = 1e18;
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.CUSTOM,
            type(uint256).max,
            defaultMinAmountOut
        );
        poolData.poolConfig.liquidityManagement.enableRemoveLiquidityCustom = true;

        uint256 bptAmountIn = 1e18;
        uint256[] memory amountsOutScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            amountsOutScaled18[i] = defaultMinAmountOut - 1;
        }

        vm.mockCall(
            address(params.pool),
            abi.encodeWithSelector(
                IPoolLiquidity.onRemoveLiquidityCustom.selector,
                params.from,
                params.maxBptAmountIn,
                minAmountsOutScaled18,
                poolData.balancesLiveScaled18,
                params.userData
            ),
            abi.encode(bptAmountIn, amountsOutScaled18, new uint256[](tokens.length), params.userData)
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                IVaultErrors.AmountOutBelowMin.selector,
                tokens[0],
                amountsOutScaled18[0],
                params.minAmountsOut[0]
            )
        );

        vault.manualRemoveLiquidity(poolData, params, minAmountsOutScaled18, vaultState);
    }

    function testRevertRemoveLiquidityUnbalancedIfUnbalancedLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_IN,
            type(uint256).max,
            1
        );
        poolData.poolConfig.liquidityManagement.disableUnbalancedLiquidity = true;

        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        vault.manualRemoveLiquidity(poolData, params, minAmountsOutScaled18, vaultState);
    }

    function testRevertRemoveLiquiditySingleTokenExactOutIfUnbalancedLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.SINGLE_TOKEN_EXACT_OUT,
            type(uint256).max,
            1
        );
        poolData.poolConfig.liquidityManagement.disableUnbalancedLiquidity = true;

        vm.expectRevert(IVaultErrors.DoesNotSupportUnbalancedLiquidity.selector);
        vault.manualRemoveLiquidity(poolData, params, minAmountsOutScaled18, vaultState);
    }

    function testRevertRemoveLiquidityCustomExactOutIfCustomLiquidityIsDisabled() public {
        VaultState memory vaultState;

        PoolData memory poolData = _makeDefaultParams();
        (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) = _makeRemoveLiquidityParams(
            poolData,
            RemoveLiquidityKind.CUSTOM,
            type(uint256).max,
            1
        );

        vm.expectRevert(IVaultErrors.DoesNotSupportRemoveLiquidityCustom.selector);
        vault.manualRemoveLiquidity(poolData, params, minAmountsOutScaled18, vaultState);
    }

    // #endregion

    // #region Helpers
    function _makeAddLiquidityParams(
        PoolData memory poolData,
        AddLiquidityKind kind,
        uint256 minBptAmountOut
    ) internal returns (AddLiquidityParams memory params, uint256[] memory maxAmountsInScaled18) {
        params = AddLiquidityParams({
            pool: pool,
            to: address(this),
            kind: kind,
            maxAmountsIn: new uint256[](tokens.length),
            minBptAmountOut: minBptAmountOut,
            userData: new bytes(0)
        });

        maxAmountsInScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            maxAmountsInScaled18[i] = 1e18;
            params.maxAmountsIn[i] = maxAmountsInScaled18[i].toRawUndoRateRoundUp(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }
    }

    function _makeRemoveLiquidityParams(
        PoolData memory poolData,
        RemoveLiquidityKind kind,
        uint256 maxBptAmountIn,
        uint256 defaultMinAmountOut
    ) internal returns (RemoveLiquidityParams memory params, uint256[] memory minAmountsOutScaled18) {
        params = RemoveLiquidityParams({
            pool: pool,
            from: address(this),
            maxBptAmountIn: maxBptAmountIn,
            minAmountsOut: new uint256[](tokens.length),
            kind: kind,
            userData: new bytes(0)
        });

        minAmountsOutScaled18 = new uint256[](tokens.length);
        for (uint256 i = 0; i < tokens.length; i++) {
            minAmountsOutScaled18[i] = defaultMinAmountOut;
            params.minAmountsOut[i] = minAmountsOutScaled18[i].toRawUndoRateRoundUp(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }
    }

    function _makeDefaultParams() internal returns (PoolData memory poolData) {
        poolData.poolConfig.staticSwapFeePercentage = swapFeePercentage;

        poolData.balancesLiveScaled18 = new uint256[](tokens.length);
        poolData.balancesRaw = new uint256[](tokens.length);

        poolData.tokenConfig = new TokenConfig[](tokens.length);
        poolData.decimalScalingFactors = new uint256[](tokens.length);
        poolData.tokenRates = new uint256[](tokens.length);

        for (uint256 i = 0; i < poolData.tokenConfig.length; i++) {
            poolData.tokenConfig[i].token = tokens[i];
            poolData.decimalScalingFactors[i] = 1e18;
            poolData.tokenRates[i] = 1e18 * (i + 1);

            poolData.balancesLiveScaled18[i] = 1000e18;
            poolData.balancesRaw[i] = poolData.balancesLiveScaled18[i].toRawUndoRateRoundDown(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }
    }

    function _mockMintCallback(address to, uint256 amount) internal {
        vm.mockCall(
            pool,
            abi.encodeWithSelector(BalancerPoolToken.emitTransfer.selector, ZERO_ADDRESS, to, amount),
            new bytes(0)
        );
    }

    function _testAddLiquidity(PoolData memory poolData, TestAddLiquidityParams memory params) internal {
        VaultState memory vaultState;
        vaultState.protocolSwapFeePercentage = swapFeePercentage;

        uint256[] memory expectedAmountsInRaw = new uint256[](params.expectedAmountsInScaled18.length);
        for (uint256 i = 0; i < expectedAmountsInRaw.length; i++) {
            expectedAmountsInRaw[i] = params.expectedAmountsInScaled18[i].toRawUndoRateRoundUp(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }

        _mockMintCallback(address(this), params.expectedBPTAmountOut);

        vm.expectEmit();
        emit IVaultEvents.PoolBalanceChanged(
            params.addLiquidityParams.pool,
            params.addLiquidityParams.to,
            expectedAmountsInRaw.unsafeCastToInt256(true)
        );

        (
            PoolData memory updatedPoolData,
            uint256[] memory amountsInRaw,
            uint256[] memory amountsInScaled18,
            uint256 bptAmountOut,
            bytes memory returnData
        ) = vault.manualAddLiquidity(poolData, params.addLiquidityParams, params.maxAmountsInScaled18, vaultState);

        assertEq(bptAmountOut, params.expectedBPTAmountOut, "Unexpected BPT amount out");
        assertEq(
            vault.balanceOf(address(params.addLiquidityParams.pool), address(this)),
            initTotalSupply + bptAmountOut,
            "Token minted with unexpected amount"
        );

        // NOTE: stack too deep fix
        TestAddLiquidityParams memory params_ = params;
        PoolData memory poolData_ = poolData;
        uint256 protocolSwapFeePercentage = vaultState.protocolSwapFeePercentage;

        for (uint256 i = 0; i < poolData_.tokenConfig.length; i++) {
            assertEq(amountsInRaw[i], expectedAmountsInRaw[i], "Unexpected tokenIn amount");
            assertEq(amountsInScaled18[i], params_.expectedAmountsInScaled18[i], "Unexpected tokenIn amount");

            uint256 protocolSwapFeeAmountRaw = _checkProtocolFeeResult(
                poolData_,
                i,
                params_.addLiquidityParams.pool,
                protocolSwapFeePercentage,
                params_.expectSwapFeeAmountsScaled18[i]
            );

            assertEq(
                updatedPoolData.balancesRaw[i],
                poolData_.balancesRaw[i] + amountsInRaw[i] - protocolSwapFeeAmountRaw,
                "Unexpected balancesRaw balance"
            );

            assertEq(vault.getTokenDelta(tokens[i]), int256(amountsInRaw[i]), "Unexpected tokenIn delta");
        }

        _checkSetPoolBalancesResult(
            poolData_,
            vault.getRawBalances(params.addLiquidityParams.pool),
            vault.getLastLiveBalances(params.addLiquidityParams.pool),
            updatedPoolData
        );
    }

    function _testRemoveLiquidity(PoolData memory poolData, TestRemoveLiquidityParams memory params) internal {
        VaultState memory vaultState;
        vaultState.protocolSwapFeePercentage = 1e16;

        uint256[] memory expectedAmountsOutRaw = new uint256[](params.expectedAmountsOutScaled18.length);
        for (uint256 i = 0; i < expectedAmountsOutRaw.length; i++) {
            expectedAmountsOutRaw[i] = params.expectedAmountsOutScaled18[i].toRawUndoRateRoundDown(
                poolData.decimalScalingFactors[i],
                poolData.tokenRates[i]
            );
        }

        vm.prank(pool);
        vault.approve(params.removeLiquidityParams.from, address(this), params.expectedBPTAmountIn);

        vm.expectEmit();
        emit IVaultEvents.PoolBalanceChanged(
            params.removeLiquidityParams.pool,
            params.removeLiquidityParams.from,
            expectedAmountsOutRaw.unsafeCastToInt256(false)
        );

        (
            PoolData memory updatedPoolData,
            uint256 bptAmountIn,
            uint256[] memory amountsOutRaw,
            uint256[] memory amountsOutScaled18,
            bytes memory returnData
        ) = vault.manualRemoveLiquidity(
                poolData,
                params.removeLiquidityParams,
                params.minAmountsOutScaled18,
                vaultState
            );

        assertEq(bptAmountIn, params.expectedBPTAmountIn, "Unexpected BPT amount in");
        assertEq(
            vault.balanceOf(address(params.removeLiquidityParams.pool), address(this)),
            initTotalSupply - bptAmountIn,
            "Token burned with unexpected amount"
        );
        assertEq(
            vault.allowance(address(vault), params.removeLiquidityParams.from, address(this)),
            0,
            "Token burned with unexpected amount"
        );

        uint256[] memory storagePoolBalances = vault.getRawBalances(params.removeLiquidityParams.pool);
        uint256[] memory storageLastLiveBalances = vault.getLastLiveBalances(params.removeLiquidityParams.pool);

        // NOTE: stack too deep fix
        TestRemoveLiquidityParams memory params_ = params;
        PoolData memory poolData_ = poolData;
        uint256 protocolSwapFeePercentage = vaultState.protocolSwapFeePercentage;
        for (uint256 i = 0; i < poolData.tokenConfig.length; i++) {
            // check _computeAndChargeProtocolFees
            uint256 protocolSwapFeeAmountRaw = _checkProtocolFeeResult(
                poolData_,
                i,
                params_.removeLiquidityParams.pool,
                protocolSwapFeePercentage,
                params_.expectSwapFeeAmountsScaled18[i]
            );

            // check balances and amounts
            assertEq(
                updatedPoolData.balancesRaw[i],
                poolData_.balancesRaw[i] - protocolSwapFeeAmountRaw - amountsOutRaw[i],
                "Unexpected balancesRaw balance"
            );
            assertEq(
                amountsOutScaled18[i],
                params_.expectedAmountsOutScaled18[i],
                "Unexpected amountsOutScaled18 amount"
            );
            assertEq(amountsOutRaw[i], expectedAmountsOutRaw[i], "Unexpected tokenOut amount");

            // check _supplyCredit
            assertEq(vault.getTokenDelta(tokens[i]), -int256(amountsOutRaw[i]), "Unexpected tokenOut delta");
        }

        _checkSetPoolBalancesResult(
            poolData_,
            vault.getRawBalances(params_.removeLiquidityParams.pool),
            vault.getLastLiveBalances(params_.removeLiquidityParams.pool),
            updatedPoolData
        );
    }

    function _checkProtocolFeeResult(
        PoolData memory poolData,
        uint256 tokenIndex,
        address pool_,
        uint256 protocolSwapFeePercentage,
        uint256 expectSwapFeeAmountScaled18
    ) internal returns (uint256 protocolSwapFeeAmountRaw) {
        protocolSwapFeeAmountRaw = expectSwapFeeAmountScaled18.mulUp(protocolSwapFeePercentage).toRawUndoRateRoundDown(
            poolData.decimalScalingFactors[tokenIndex],
            poolData.tokenRates[tokenIndex]
        );
        /* TODO assertEq(
            vault.getProtocolFees(pool, poolData.tokenConfig[tokenIndex].token),
            protocolSwapFeeAmountRaw,
            "Unexpected protocol fees"
        );
        assertEq(vault.getPoolCreatorFees(pool_, poolData.tokenConfig[tokenIndex].token), 0, "Unexpected creator fees");*/
    }

    function _checkSetPoolBalancesResult(
        PoolData memory poolData,
        uint256[] memory storagePoolBalances,
        uint256[] memory storageLastLiveBalances,
        PoolData memory updatedPoolData
    ) internal {
        for (uint256 i = 0; i < poolData.tokenConfig.length; i++) {
            assertEq(storagePoolBalances[i], updatedPoolData.balancesRaw[i], "Unexpected pool balance");

            assertEq(
                storageLastLiveBalances[i],
                updatedPoolData.balancesLiveScaled18[i],
                "Unexpected last live balance"
            );

            assertEq(
                updatedPoolData.balancesLiveScaled18[i],
                storagePoolBalances[i].toScaled18ApplyRateRoundDown(
                    poolData.decimalScalingFactors[i],
                    poolData.tokenRates[i]
                ),
                "Unexpected balancesLiveScaled18 balance"
            );
        }
    }
    // #endregion
}