// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import { IProtocolFeeCollector } from "./IProtocolFeeCollector.sol";
import { IAuthorizer } from "./IAuthorizer.sol";
import { IVault } from "./IVault.sol";

interface IVaultAdmin {
    /*******************************************************************************
                              Constants and immutables
    *******************************************************************************/

    /**
     * @notice Returns Vault's pause window end time.
     * @dev This value is immutable; the getter can be called by anyone.
     */
    function getPauseWindowEndTime() external view returns (uint256);

    /**
     * @notice Returns Vault's buffer period duration.
     * @dev This value is immutable; the getter can be called by anyone.
     */
    function getBufferPeriodDuration() external view returns (uint256);

    /**
     * @notice Returns Vault's buffer period end time.
     * @dev This value is immutable; the getter can be called by anyone.
     */
    function getBufferPeriodEndTime() external view returns (uint256);

    /**
     * @notice Get the minimum number of tokens in a pool.
     * @dev We expect the vast majority of pools to be 2-token.
     * @return The token count of a minimal pool
     */
    function getMinimumPoolTokens() external pure returns (uint256);

    /**
     * @notice Get the maximum number of tokens in a pool.
     * @return The token count of a minimal pool
     */
    function getMaximumPoolTokens() external pure returns (uint256);

    /// @dev Returns the main Vault address.
    function vault() external view returns (IVault);

    /// @dev Returns the ProtocolFeeCollector address.
    function getProtocolFeeCollector() external view returns (IProtocolFeeCollector);

    /*******************************************************************************
                                    Pool Information
    *******************************************************************************/

    /**
     * @notice Retrieve the scaling factors from a pool's rate providers.
     * @dev This is not included in `getPoolTokenInfo` since it makes external calls that might revert,
     * effectively preventing retrieval of basic pool parameters. Tokens without rate providers will always return
     * FixedPoint.ONE (1e18).
     */
    function getPoolTokenRates(address pool) external view returns (uint256[] memory);

    /*******************************************************************************
                                    Vault Pausing
    *******************************************************************************/

    /**
     * @notice Indicates whether the Vault is paused.
     * @return True if the Vault is paused
     */
    function isVaultPaused() external view returns (bool);

    /**
     * @notice Returns the paused status, and end times of the Vault's pause window and buffer period.
     * @return paused True if the Vault is paused
     * @return vaultPauseWindowEndTime The timestamp of the end of the Vault's pause window
     * @return vaultBufferPeriodEndTime The timestamp of the end of the Vault's buffer period
     */
    function getVaultPausedState() external view returns (bool, uint256, uint256);

    /**
     * @notice Pause the Vault: an emergency action which disables all operational state-changing functions.
     * @dev This is a permissioned function that will only work during the Pause Window set during deployment.
     */
    function pauseVault() external;

    /**
     * @notice Reverse a `pause` operation, and restore the Vault to normal functionality.
     * @dev This is a permissioned function that will only work on a paused Vault within the Buffer Period set during
     * deployment. Note that the Vault will automatically unpause after the Buffer Period expires.
     */
    function unpauseVault() external;

    /*******************************************************************************
                                    Pool Pausing
    *******************************************************************************/

    /**
     * @notice Pause the Pool: an emergency action which disables all pool functions.
     * @dev This is a permissioned function that will only work during the Pause Window set during pool factory
     * deployment.
     */
    function pausePool(address pool) external;

    /**
     * @notice Reverse a `pause` operation, and restore the Pool to normal functionality.
     * @dev This is a permissioned function that will only work on a paused Pool within the Buffer Period set during
     * deployment. Note that the Pool will automatically unpause after the Buffer Period expires.
     */
    function unpausePool(address pool) external;

    /*******************************************************************************
                                   Fees
    *******************************************************************************/

    /**
     * @notice Sets a new swap fee percentage for the protocol.
     * @param newSwapFeePercentage The new swap fee percentage to be set
     */
    function setProtocolSwapFeePercentage(uint256 newSwapFeePercentage) external;

    /**
     * @notice Sets a new yield fee percentage for the protocol.
     * @param newYieldFeePercentage The new swap fee percentage to be set
     */
    function setProtocolYieldFeePercentage(uint256 newYieldFeePercentage) external;

    /**
     * @notice Assigns a new static swap fee percentage to the specified pool.
     * @param pool The address of the pool for which the static swap fee will be changed
     * @param swapFeePercentage The new swap fee percentage to apply to the pool
     */
    function setStaticSwapFeePercentage(address pool, uint256 swapFeePercentage) external;

    /**
     * @notice Assigns a new pool creator fee percentage to the specified pool.
     * @param pool The address of the pool for which the pool creator fee will be changed
     * @param poolCreatorFeePercentage The new pool creator fee percentage to apply to the pool
     */
    function setPoolCreatorFeePercentage(address pool, uint256 poolCreatorFeePercentage) external;

    /**
     * @notice Collects accumulated protocol swap fees for the specified pool.
     * @dev Fees are sent to the ProtocolFeeCollector address.
     * @param pool The pool on which all protocol fees should be collected
     */
    function collectProtocolSwapFees(address pool) external;

    /**
     * @notice Collects accumulated protocol yield fees for the specified pool.
     * @dev Fees are sent to the ProtocolFeeCollector address.
     * @param pool The pool on which all protocol fees should be collected
     */
    function collectProtocolYieldFees(address pool) external;

    /**
     * @notice Calculate the aggregate percentage, given protocol and creator fee components.
     * @dev Fees will be combined to give the total aggregate percentage.
     * See example:
     * tokenOutAmount = 10000; poolSwapFeePct = 10%; protocolFeePct = 40%; creatorFeePct = 60%
     * totalFees = tokenOutAmount * poolSwapFeePct = 10000 * 10% = 1000
     * protocolFees = totalFees * protocolFeePct = 1000 * 40% = 400
     * creatorAndLpFees = totalFees - protocolFees = 1000 - 400 = 600
     * creatorFees = creatorAndLpFees * creatorFeePct = 600 * 60% = 360
     * lpFees (will stay in the pool) = creatorAndLpFees - creatorFees = 600 - 360 = 240
     *
     * So, the aggregate percentage is: totalFees * protocolFeePct +
     *     (totalFees - totalFees * protocolFeePct) * creatorFeePct
     *     = totalFees * protocolFeePct + totalFees * (1 - protocolFeePct) * creatorFeePct
     *     = protocolFeePct + (1 - protocolFeePct) * creatorFeePct
     *
     * In the example, that would be: 0.4 + (1 - 0.4) * 0.6 = 0.4 + 0.6 * 0.6 = 0.4 + 0.36 = 0.76 (76%)
     *
     * @param protocolFeePercentage The protocol fee percentage
     * @param creatorFeePercentage The creator fee percentage
     */
    function getAggregateFeePercentage(uint256 protocolFeePercentage, uint256 creatorFeePercentage) external pure returns (uint256);

    /*******************************************************************************
                                    Recovery Mode
    *******************************************************************************/

    /**
     * @notice Enable recovery mode for a pool.
     * @dev This is a permissioned function.
     * @param pool The pool
     */
    function enableRecoveryMode(address pool) external;

    /**
     * @notice Disable recovery mode for a pool.
     * @dev This is a permissioned function.
     * @param pool The pool
     */
    function disableRecoveryMode(address pool) external;

    /*******************************************************************************
                                    Queries
    *******************************************************************************/

    /// @notice Disables queries functionality on the Vault. Can be called only by governance.
    function disableQuery() external;

    /*******************************************************************************
                                Authentication
    *******************************************************************************/

    /**
     * @notice Sets a new Authorizer for the Vault.
     * @dev The caller must be allowed by the current Authorizer to do this.
     * Emits an `AuthorizerChanged` event.
     */
    function setAuthorizer(IAuthorizer newAuthorizer) external;
}
