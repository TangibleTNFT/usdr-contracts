// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Factory.sol";
import "@uniswap/v3-core/contracts/interfaces/IUniswapV3Pool.sol";
import "@uniswap/v3-periphery/contracts/interfaces/INonfungiblePositionManager.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";

import "../constants/addresses.sol";
import "../constants/roles.sol";
import "../interfaces/IExchange.sol";
import "../interfaces/ILiquidityTokenMath.sol";
import "../interfaces/ITreasury.sol";
import "../AddressAccessor.sol";

interface ICurveFactory {
    function deploy_metapool(
        address base_pool,
        string calldata name,
        string calldata symbol,
        address coin,
        uint256 A,
        uint256 fee,
        uint256 implementation_idx
    ) external returns (address);

    function get_base_pool(address pool) external view returns (address);

    function get_meta_n_coins(address pool)
        external
        view
        returns (uint256, uint256);

    function get_underlying_balances(address pool)
        external
        view
        returns (uint256[8] memory);

    function get_underlying_decimals(address pool)
        external
        view
        returns (uint256[8] memory);
}

interface ICurvePool {
    function underlying_coins(uint256 index) external view returns (address);
}

interface ICurveZapper {
    function add_liquidity(
        address pool,
        uint256[4] calldata deposit_amounts,
        uint256 min_mint_amount
    ) external returns (uint256);

    function exchange_underlying(
        address pool,
        int128 i,
        int128 j,
        uint256 dx,
        uint256 min_dy
    ) external returns (uint256);
}

interface IBooster {
    function depositAll(uint256 pid) external returns (bool);

    function poolLength() external view returns (uint256);

    function poolInfo(uint256 pid)
        external
        view
        returns (
            address lpToken,
            address gauge,
            address rewards,
            bool shutdown,
            address factory
        );
}

interface IRewardPool is IERC20 {
    function getReward(address account, address forwardTo) external;
}

bytes32 constant CURVE_3POOL_ADDRESS = bytes32(keccak256("curve3Pool"));
bytes32 constant CURVE_FACTORY_ADDRESS = bytes32(keccak256("curveFactory"));
bytes32 constant CURVE_ZAPPER_ADDRESS = bytes32(keccak256("curveZapper"));

contract LiquidityManager is AddressAccessor, Pausable {
    address private constant BOOSTER_ADDRESS =
        0xF403C135812408BFbE8713b5A23a04b3D48AAE31;

    address public curvePool; // Curve pool contract address

    uint256 private _minSizePercent; // how many percent of the USDR market cap should be in the curve liquidity pool
    uint256 private _pid; // the Convex pool id that maps the Curve pool to the Convex reward pool
    bool private _pidIsSet; // whether _pid has been set or not

    IBooster private immutable booster; // Instance of the Convex Booster contract
    IRewardPool private _rewardPool; // Instance of the Convex Reward Pool contract

    constructor(address previousImplementation) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        require(
            previousImplementation != address(0),
            "previous implementation not set"
        );
        booster = IBooster(BOOSTER_ADDRESS);
        // Copy the Curve pool address from the previous implementation
        LiquidityManager lpm = LiquidityManager(previousImplementation);
        curvePool = lpm.curvePool();
    }

    /**
     * @notice Increases the liquidity of the Curve pool by depositing `underlyingAmount` of the underlying asset into the pool.
     * @dev This function can only be called by the treasury contract. It first transfers the underlying asset from the treasury
     *      to this contract, then rebalances the pool, and finally adds liquidity to the pool using CurveZapper. Once liquidity
     *      is added, the LP tokens are staked to begin earning rewards.
     * @param underlyingAmount The amount of the underlying asset to deposit into the pool.
     */
    function increaseLiquidity(uint256 underlyingAmount)
        external
        whenNotPaused
    {
        // Get addresses of contracts required to execute the function.
        (
            address underlying,
            address usdr,
            address exchange,
            address treasury,
            address curveFactory,
            address curveZapper
        ) = abi.decode(
                addressProvider.getAddresses(
                    abi.encode(
                        UNDERLYING_ADDRESS,
                        USDR_ADDRESS,
                        USDR_EXCHANGE_ADDRESS,
                        TREASURY_ADDRESS,
                        CURVE_FACTORY_ADDRESS,
                        CURVE_ZAPPER_ADDRESS
                    )
                ),
                (address, address, address, address, address, address)
            );

        // Ensure that only the treasury contract can execute the function.
        require(msg.sender == treasury, "caller is not treasury");

        // Transfer the specified amount of underlying asset from the treasury to this contract.
        IERC20(underlying).transferFrom(
            treasury,
            address(this),
            underlyingAmount
        );

        // Rebalance the pool to ensure stable proportions of the tokens in the pool.
        _rebalancePool(exchange, underlying);

        // Initialize an array to store the token amounts for the add_liquidity function.
        uint256[4] memory amounts;
        // Get the balance of USDR token held by this contract and add it to amounts.
        amounts[0] = IERC20(usdr).balanceOf(address(this));

        // If the USDR balance is greater than zero, approve CurveZapper to spend it.
        if (amounts[0] > 0) {
            IERC20(usdr).approve(curveZapper, amounts[0]);
        }

        // Get the base pool for the current curve pool.
        address basePool = ICurveFactory(curveFactory).get_base_pool(curvePool);
        // Loop through the 3 underlying tokens in the base pool and add them to amounts.
        for (uint256 i; i < 3; ) {
            // Get the token address and balance.
            address token = ICurvePool(basePool).underlying_coins(i);
            uint256 balance = IERC20(token).balanceOf(address(this));
            i++;
            // Approve CurveZapper to spend the balance of the token.
            IERC20(token).approve(curveZapper, balance);
            // Add the token balance to amounts.
            amounts[i] = balance;
        }

        // Add liquidity to the pool using the CurveZapper contract.
        ICurveZapper(curveZapper).add_liquidity(curvePool, amounts, 0);

        // Stake the LP token obtained from adding liquidity to the pool.
        _stakeLPToken();
    }

    /**
     * @dev Stake LP token into the Booster pool
     * @notice This function is private and is called by the increaseLiquidity() function
     * @notice It checks the balance of LP token and stakes all of it into the Booster pool
     */
    function _stakeLPToken() private {
        uint256 amount = IERC20(curvePool).balanceOf(address(this)); // Get the current balance of LP tokens held by this contract.
        if (amount > 0 && _checkRewardPool()) {
            IERC20(curvePool).approve(BOOSTER_ADDRESS, amount); // Approve the Booster to transfer LP tokens.
            booster.depositAll(_pid); // Deposit all available LP tokens into the Booster.
        }
    }

    /**
     * @notice Collects rewards for the contract and sends them to the caller.
     * @dev Only the account with the CONTROLLER_ROLE can call this function.
     */
    function collectRewards() external onlyRole(CONTROLLER_ROLE) {
        if (_checkRewardPool()) {
            // Get rewards from the reward pool contract and send them to the caller
            _rewardPool.getReward(address(this), msg.sender);
        }
    }

    /**
     * @dev Check id the reward pool has been set. Try to find and set it if not.
     * @return True if the reward pool has been set, otherwise false.
     */
    function _checkRewardPool() private returns (bool) {
        if (_pidIsSet) return true;
        // If the pool ID has not been set yet, find and set it.
        (bool success, uint256 pid) = _findPid(curvePool);
        if (success) {
            _pid = pid;
            _pidIsSet = true;
        }
        return success;
    }

    /**
     * @dev Finds the ID of the pool for a given LP token.
     * @param forToken The address of the LP token.
     * @return The ID of the pool for the given LP token. Reverts if no pool is found for the given LP token.
     */
    function _findPid(address forToken) private returns (bool, uint256) {
        // Get the number of pools
        uint256 poolLength = booster.poolLength();

        // Iterate over all pools to find the one that matches the given LP token
        for (uint256 i; i < poolLength; i++) {
            (address lpToken, , address rewards, bool shutdown, ) = booster
                .poolInfo(i);

            // If a pool is found that matches the given LP token and is not shutdown, return its ID
            if (lpToken == forToken && !shutdown) {
                _rewardPool = IRewardPool(rewards);
                return (true, i);
            }
        }
        return (false, 0);
    }

    /**
     * @dev Get the total liquidity in the pool, accounting for all assets in the pool.
     * @return The total liquidity in the pool, denominated in the underlying asset.
     */
    function liquidity() external view returns (uint256) {
        // Get the balances of the pool's assets
        (uint256 usdrBalance, uint256 underlyingBalance) = _getPoolBalances(
            false
        );

        // Get the addresses of the USDR token, underlying token, and USDR exchange
        (address usdr, address underlying, address exchange) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(
                    USDR_ADDRESS,
                    UNDERLYING_ADDRESS,
                    USDR_EXCHANGE_ADDRESS
                )
            ),
            (address, address, address)
        );

        // Add the current balance of USDR and underlying tokens held by the contract
        usdrBalance += IERC20(usdr).balanceOf(address(this));
        underlyingBalance += IERC20(underlying).balanceOf(address(this));

        // Scale the USDR balance to the underlying asset and add to the total liquidity
        return
            IExchange(exchange).scaleToUnderlying(usdrBalance) +
            underlyingBalance;
    }

    /**
     * @dev Calculate the amount of liquidity that is missing from the pool to meet the minimum pool size requirement.
     * @return The amount of liquidity that is missing from the pool.
     */
    function missingLiquidity() external view returns (uint256) {
        // Get the addresses of the USDR exchange and USDR token
        (address exchange, address usdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(USDR_EXCHANGE_ADDRESS, USDR_ADDRESS)
            ),
            (address, address)
        );

        // Calculate the minimum pool size based on the _minSizePercent parameter
        uint256 minSize = IExchange(exchange).scaleToUnderlying(
            (IERC20(usdr).totalSupply() * _minSizePercent) / 100
        );

        uint256 poolBalance;
        {
            // Get the current balances of USDR and underlying tokens in the pool
            (uint256 usdrBalance, uint256 underlyingBalance) = _getPoolBalances(
                false
            );

            // Calculate the total pool balance by converting the USDR balance to underlying token balance
            poolBalance =
                underlyingBalance +
                IExchange(exchange).scaleToUnderlying(usdrBalance);
        }

        // Return the amount of liquidity that is missing from the pool
        return poolBalance < minSize ? (minSize - poolBalance) : 0;
    }

    function setMinSize(uint256 percent) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _minSizePercent = percent;
    }

    function sweepToken(address token) public onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount > 0) {
            IERC20(token).transfer(msg.sender, amount);
        }
    }

    function sweepTokens() external onlyRole(DEFAULT_ADMIN_ROLE) {
        (address underlying, address usdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(UNDERLYING_ADDRESS, USDR_ADDRESS)
            ),
            (address, address)
        );
        sweepToken(underlying);
        sweepToken(usdr);
    }

    function withdrawLPToken() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 amount = IERC20(curvePool).balanceOf(address(this));
        if (amount > 0) IERC20(curvePool).transfer(msg.sender, amount);
        IRewardPool rewardPool = _rewardPool;
        if (address(rewardPool) != address(0)) {
            amount = rewardPool.balanceOf(address(this));
            if (amount > 0) rewardPool.transfer(msg.sender, amount);
        }
    }

    function _getCoinIndex(address token) private view returns (uint256 index) {
        address curveFactory = addressProvider.getAddress(
            CURVE_FACTORY_ADDRESS
        );
        address basePool = ICurveFactory(curveFactory).get_base_pool(curvePool);
        while (index < 3) {
            address coin = ICurvePool(basePool).underlying_coins(index);
            if (coin == token) break;
            index++;
        }
        require(index < 3, "invalid token");
        index++;
    }

    /**
     * @dev Internal function that retrieves the USDR and underlying asset balances of the pool.
     * @param total Flag indicating if the balances should be returned for the entire pool or just the calling contract.
     * @return usdrBalance The USDR balance of the pool.
     * @return underlyingBalance The underlying asset balance of the pool.
     */
    function _getPoolBalances(bool total)
        private
        view
        returns (uint256 usdrBalance, uint256 underlyingBalance)
    {
        uint256 ownership;

        if (total) {
            ownership = 1e18;
        } else {
            // Calculate ownership percentage. CRV LP tokens are exchanges 1:1 for CVX staking tokens.
            uint256 crvOwnership = (IERC20(curvePool).balanceOf(address(this)) *
                1e18) / IERC20(curvePool).totalSupply();
            uint256 cvxOwnership;
            IRewardPool rewardPool = _rewardPool;
            if (address(rewardPool) != address(0)) {
                cvxOwnership =
                    (_rewardPool.balanceOf(address(this)) * 1e18) /
                    IERC20(curvePool).totalSupply();
            }
            ownership = crvOwnership + cvxOwnership;
            if (ownership == 0) return (0, 0);
        }

        // Retrieve curve factory and pool addresses, and the number of underlying coins.
        address curveFactory = addressProvider.getAddress(
            CURVE_FACTORY_ADDRESS
        );
        address pool = curvePool;
        ICurveFactory factory = ICurveFactory(curveFactory);
        (, uint256 nCoins) = factory.get_meta_n_coins(curvePool);

        // Retrieve balances and decimals of underlying assets.
        uint256[8] memory balances = factory.get_underlying_balances(pool);
        uint256[8] memory decimals = factory.get_underlying_decimals(pool);

        // Calculate and return USDR and underlying asset balances based on ownership percentage.
        usdrBalance = (balances[0] * ownership) / 1e18;

        for (uint256 i = 1; i < nCoins; i++) {
            underlyingBalance += balances[i] * (10**(18 - decimals[i]));
        }

        underlyingBalance = (underlyingBalance * ownership) / 1e18;
    }

    /**
     * @dev This function is used to rebalance the pool by swapping USDR to underlying token
     * @param exchange The address of the exchange contract
     * @param underlying The address of the underlying token contract
     **/
    function _rebalancePool(address exchange, address underlying) private {
        // Get the total balances of USDR and underlying tokens in the pool
        (uint256 usdrBalance, uint256 underlyingBalance) = _getPoolBalances(
            true
        );

        // Convert the USDR balance to the equivalent underlying token balance
        uint256 scaledUSDRBalance = IExchange(exchange).scaleToUnderlying(
            usdrBalance
        );

        // Calculate the swap amount required to rebalance the pool
        uint256 swapAmount;
        if (scaledUSDRBalance > underlyingBalance) {
            swapAmount = (scaledUSDRBalance - underlyingBalance) >> 1;
        }

        // Check if swap is needed
        if (swapAmount > 0) {
            // Get the current balance of underlying tokens held by the contract
            underlyingBalance = IERC20(underlying).balanceOf(address(this));

            // Ensure that the swap amount does not exceed the current balance of underlying tokens
            if (underlyingBalance < swapAmount) {
                swapAmount = underlyingBalance;
            }

            // Execute the swap
            if (swapAmount > 0) {
                address curveZapper = addressProvider.getAddress(
                    CURVE_ZAPPER_ADDRESS
                );
                IERC20(underlying).approve(curveZapper, swapAmount);
                uint128 i = uint128(_getCoinIndex(underlying));
                ICurveZapper(curveZapper).exchange_underlying(
                    curvePool,
                    int128(i),
                    0,
                    swapAmount,
                    1
                );
            }
        }
    }
}
