// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import "./constants/addresses.sol";
import "./constants/roles.sol";

import "./AddressAccessor.sol";

/*
 * @title USDRRebaseProxy
 * @dev This contract is designed to manage pools and trigger rebase for USDR.
 */
contract USDRRebaseProxy is AddressAccessor {
    bytes32 public constant POOL_MANAGER_ROLE =
        bytes32(keccak256("POOL_MANAGER"));

    event PoolAdded(address indexed pool);
    event PoolRemoved(address indexed pool);

    // Use SafeERC20 for IERC20 to ensure safe interactions with ERC20 tokens.
    using SafeERC20 for IERC20;

    // The address of the voter.
    address public voter;

    // Array of pool addresses.
    address[] public pools;

    // Mapping to keep track of the pools that have been added.
    mapping(address => bool) private _isPoolAdded;

    /*
     * @dev The constructor sets the pool manager address and assigns the admin role to the message sender.
     * @param _voter The address of the voter.
     */
    constructor(address _poolManager) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(DEFAULT_ADMIN_ROLE, _poolManager);
        _grantRole(POOL_MANAGER_ROLE, _poolManager);
    }

    function setVoter(address _voter) external onlyRole(POOL_MANAGER_ROLE) {
        voter = _voter;
    }

    /*
     * @notice Add a new pool to the contract.
     * @dev Only accounts with the admin role can add a pool.
     * @param pool The address of the pool to be added.
     */
    function addPool(address pool) external onlyRole(POOL_MANAGER_ROLE) {
        require(pool != address(0), "Invalid pool address");
        require(!_isPoolAdded[pool], "Pool already added");
        pools.push(pool);
        _isPoolAdded[pool] = true;
        emit PoolAdded(pool);
    }

    /*
     * @notice Remove a pool from the contract.
     * @dev Only accounts with the admin role can remove a pool.
     * @param pool The address of the pool to be removed.
     */
    function removePool(address pool) external onlyRole(POOL_MANAGER_ROLE) {
        require(_isPoolAdded[pool], "Pool not found");

        address[] storage _pools = pools;
        uint256 numPools = _pools.length;
        uint256 lastPoolIndex = numPools - 1;

        // Loop through the list of pools to find and remove the specified pool.
        for (uint256 i = 0; i < numPools; ) {
            if (_pools[i] == pool) {
                if (i != lastPoolIndex) {
                    address lastPool = _pools[lastPoolIndex];
                    _pools[i] = lastPool;
                }
                _pools.pop();
                _isPoolAdded[pool] = false;
                i = lastPoolIndex;
            }
            unchecked {
                ++i;
            }
        }

        emit PoolRemoved(pool);
    }

    /*
     * @notice Trigger a rebase.
     * @dev Only accounts with the controller role can trigger a rebase.
     * @return amount The amount returned from the rebase.
     */
    function triggerRebase()
        external
        onlyRole(CONTROLLER_ROLE)
        returns (uint256 amount)
    {
        // Get the treasury and USDR addresses from the address provider.
        (address treasury, address usdr, address wusdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(
                    TREASURY_ADDRESS,
                    USDR_ADDRESS,
                    bytes32(keccak256("wUSDR"))
                )
            ),
            (address, address, address)
        );
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
        IVoter _voter = IVoter(voter);
        address[] memory pools_ = pools;
        for (uint256 i = pools_.length; i > 0; ) {
            unchecked {
                --i;
            }
            _tryAutoBribe(_voter, IPair(pools_[i]), usdr, wusdr);
        }
    }

    /*
     * @dev Internal function to try to auto bribe for a given pool and token.
     * @param _voter Voter contract address.
     * @param pair Pair contract address.
     * @param autoBribeTokenAddress Address of the token used for auto bribe.
     * @param wrappedTokenAddress Address of the wrapped token used for auto bribe.
     */
    function _tryAutoBribe(
        IVoter _voter,
        IPair pair,
        address autoBribeTokenAddress,
        address wrappedTokenAddress
    ) internal {
        address gauge = _voter.gauges(address(pair));
        bool needsSync;
        if (gauge != address(0) && _voter.isAlive(gauge)) {
            address bribe = _voter.external_bribes(gauge);
            (address token0, address token1) = pair.tokens();
            needsSync =
                0 !=
                (_autoBribeOrReinvest(
                    pair,
                    bribe,
                    token0,
                    autoBribeTokenAddress,
                    wrappedTokenAddress
                ) |
                    _autoBribeOrReinvest(
                        pair,
                        bribe,
                        token1,
                        autoBribeTokenAddress,
                        wrappedTokenAddress
                    ));
        } else {
            needsSync = true;
        }
        if (needsSync) {
            pair.sync();
        }
    }

    /*
     * @dev Internal function to automatically bribe or reinvest.
     * @param pair Pair contract address.
     * @param bribeAddress Address to send the bribe to.
     * @param tokenAddress Address of the token to bribe or reinvest.
     * @param autoBribeTokenAddress Address of the token used for auto bribe.
     * @param wrappedTokenAddress Address of the wrapped token used for auto bribe.
     * @return needsSync Pseudo-boolean indicating whether the pair contract needs to be synced.
     */
    function _autoBribeOrReinvest(
        IPair pair,
        address bribeAddress,
        address tokenAddress,
        address autoBribeTokenAddress,
        address wrappedTokenAddress
    ) internal returns (uint256 needsSync) {
        pair.skim(address(this));
        IERC20 token = IERC20(tokenAddress);
        IERC4626 wrappedToken = IERC4626(wrappedTokenAddress);
        uint256 amount = token.balanceOf(address(this));
        if (amount > 0) {
            if (tokenAddress == autoBribeTokenAddress) {
                token.approve(wrappedTokenAddress, amount);
                uint256 shares = wrappedToken.deposit(amount, address(this));
                wrappedToken.approve(bribeAddress, shares);
                IBribe(bribeAddress).notifyRewardAmount(
                    wrappedTokenAddress,
                    shares
                );
            } else {
                token.safeTransfer(address(pair), amount);
                needsSync = 1;
            }
        }
    }
}

/*
 * @title IBribe
 * @dev Interface for contracts conforming to the IBribe standard.
 */
interface IBribe {
    function notifyRewardAmount(address token, uint256 amount) external;
}

/*
 * @title IPair
 * @dev Interface for contracts conforming to the IPair standard.
 */
interface IPair {
    function skim(address to) external;

    function sync() external;

    function tokens() external view returns (address, address);
}

/*
 * @title IVoter
 * @dev Interface for contracts conforming to the IVoter standard.
 */
interface IVoter {
    function gauges(address pool) external view returns (address);

    function external_bribes(address pool) external view returns (address);

    function isAlive(address gauge) external view returns (bool);
}
