// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

import "./constants/addresses.sol";
import "./constants/roles.sol";

import "./AddressAccessor.sol";

contract USDRRebaseProxy is AddressAccessor {
    address[] public pools;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function addPool(address pool) external onlyRole(DEFAULT_ADMIN_ROLE) {
        pools.push(pool);
    }

    function triggerRebase()
        external
        onlyRole(CONTROLLER_ROLE)
        returns (uint256 amount)
    {
        address treasury = addressProvider.getAddress(TREASURY_ADDRESS);
        bool success;
        bytes memory result;
        (success, result) = treasury.call(
            abi.encodeWithSelector(USDRRebaseProxy.triggerRebase.selector)
        );
        if (success == false) {
            assembly {
                revert(add(result, 32), mload(result))
            }
        }
        amount = abi.decode(result, (uint256));
        address[] memory pools_ = pools;
        for (uint256 i = pools_.length; i > 0; ) {
            i--;
            (success, result) = pools_[i].call(
                abi.encodeWithSignature("sync()")
            );
            if (success == false) {
                assembly {
                    revert(add(result, 32), mload(result))
                }
            }
        }
    }
}
