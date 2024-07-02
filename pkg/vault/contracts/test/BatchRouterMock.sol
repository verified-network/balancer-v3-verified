// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IPermit2 } from "permit2/src/interfaces/IPermit2.sol";

import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";
import { IWETH } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/misc/IWETH.sol";

import { AddressMappingSlot } from "@balancer-labs/v3-solidity-utils/contracts/helpers/TransientStorageHelpers.sol";

import "../BatchRouter.sol";

contract BatchRouterMock is BatchRouter {
    constructor(IVault vault, IWETH weth, IPermit2 permit2) BatchRouter(vault, weth, permit2) {
        // solhint-disable-previous-line no-empty-blocks
    }

    function manualGetCurrentSwapTokensInSlot(uint256 index) external pure returns (bytes32) {
        TransientEnumerableSet.AddressSet storage enumerableSet = _currentSwapTokensIn(index);

        bytes32 slot;
        assembly {
            slot := enumerableSet.slot
        }

        return slot;
    }

    function manualGetCurrentSwapTokensOutSlot(uint256 index) external pure returns (bytes32) {
        TransientEnumerableSet.AddressSet storage enumerableSet = _currentSwapTokensOut(index);

        bytes32 slot;
        assembly {
            slot := enumerableSet.slot
        }

        return slot;
    }

    function manualGetCurrentSwapTokenInAmounts(uint256 index) external pure returns (AddressMappingSlot) {
        return _currentSwapTokenInAmounts(index);
    }

    function manualGetCurrentSwapTokenOutAmounts(uint256 index) external pure returns (AddressMappingSlot) {
        return _currentSwapTokenOutAmounts(index);
    }

    function manualGetSettledTokenAmounts(uint256 index) external pure returns (AddressMappingSlot) {
        return _settledTokenAmounts(index);
    }
}
