// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";

import "../constants/addresses.sol";
import "../interfaces/IExchange.sol";
import "../interfaces/ITreasury.sol";
import "../AddressAccessor.sol";

/**
 * @title PearlLiquidityManager
 * @dev This contract manages liquidity across different pools and handles related operations.
 */
contract PearlLiquidityManager is OwnableUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct Pool {
        IPair pair; // Pair associated with the pool
        IGauge gauge; // Gauge to measure liquidity in the pool
        uint256 ratio; // Ratio of liquidity distribution
    }

    AddressProvider public addressProvider;
    IERC20Upgradeable public rewardToken;
    ISingleTokenLiquidityProvider public liquidityProvider;
    IPairFactory public pairFactory;

    Pool[] public pools;

    uint256 public minSizePercent;

    uint256 private _totalRatio;

    event LiquidityIncreased(address indexed _pair, uint256 _amount);
    event RewardsCollected(address indexed _rewardToken, uint256 _totalReward);

    /**
     * @dev Initialize the contract with initial values
     * @param _liquidityProvider Address of the liquidity provider
     * @param _pairFactory Address of the pair factory
     * @param _rewardToken Address of the reward token
     * @param _pools Array of Pool structures
     */
    function initialize(
        address _addressProvider,
        address _liquidityProvider,
        address _pairFactory,
        address _rewardToken,
        Pool[] memory _pools
    ) public initializer {
        __Ownable_init();
        addressProvider = AddressProvider(_addressProvider);
        liquidityProvider = ISingleTokenLiquidityProvider(_liquidityProvider);
        pairFactory = IPairFactory(_pairFactory);
        rewardToken = IERC20Upgradeable(_rewardToken);
        minSizePercent = 25;
        _addPools(_pools);
    }

    /**
     * @dev Set the address provider
     * @param _addressProvider The new address provider
     */
    function setAddressProvider(AddressProvider _addressProvider)
        external
        onlyOwner
    {
        addressProvider = _addressProvider;
    }

    /**
     * @dev Set the minimum size percentage for liquidity
     * @param _percent The new minimum size percentage
     */
    function setMinSize(uint256 _percent) external onlyOwner {
        require(_percent <= 100, "invalid percentage");
        minSizePercent = _percent;
    }

    /**
     * @dev Set the pools and manage the liquidity accordingly
     * @param _pools The new pools to be set
     */
    function setPools(Pool[] memory _pools) external onlyOwner {
        for (uint256 _i = pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            if (!_isPool(_pools, address(pools[_i].pair))) {
                pools[_i].gauge.withdrawAllAndHarvest();
                _transferAll(pools[_i].pair, msg.sender);
            }
        }
        delete pools;
        _totalRatio = 0;
        _addPools(_pools);
        _transferAll(rewardToken, msg.sender);
    }

    /**
     * @dev Collect all rewards from the pools
     */
    function collectRewards() external onlyOwner {
        for (uint256 _i = pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            pools[_i].gauge.getReward();
        }
        uint256 _amount = _transferAll(rewardToken, msg.sender);
        emit RewardsCollected(address(rewardToken), _amount);
    }

    /**
     * @dev Deposits all available LP tokens from the owner
     */
    function depositAll() external onlyOwner {
        for (uint256 _i = pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            uint256 _balance = pools[_i].pair.balanceOf(msg.sender);
            if (_balance != 0) {
                IERC20Upgradeable(pools[_i].pair).safeTransferFrom(
                    msg.sender,
                    address(this),
                    _balance
                );
                _stake(pools[_i], _balance);
            }
        }
    }

    /**
     * @dev Increase liquidity in the pools with the underlying amount
     * @param _underlyingAmount Amount of underlying asset to increase liquidity
     */
    function increaseLiquidity(uint256 _underlyingAmount) external {
        (address _underlying, address _usdr, address _treasury) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(UNDERLYING_ADDRESS, USDR_ADDRESS, TREASURY_ADDRESS)
            ),
            (address, address, address)
        );

        // Ensure that only the treasury can call this function
        require(msg.sender == _treasury, "caller is not treasury");

        // Transfer the underlying amount from treasury to this contract
        IERC20Upgradeable(_underlying).transferFrom(
            _treasury,
            address(this),
            _underlyingAmount
        );

        // Swap the underlying token for USDR
        _swapUnderlyingToUsdr(_underlyingAmount);

        uint256 _usdrAvailable = IERC20Upgradeable(_usdr).balanceOf(
            address(this)
        );

        // Calculate the new total liquidity including available USDR
        uint256 _currentLiquidity = _liquidityInUSDR();
        uint256 _newTotalLiquidity = _currentLiquidity + _usdrAvailable;

        Pool[] memory _pools = pools;
        uint256[] memory _desiredLiquidityIncrease = new uint256[](
            _pools.length
        );

        // Iterate through pools to calculate desired liquidity increase
        for (uint256 _i = _pools.length; _i != 0 && _usdrAvailable != 0; ) {
            unchecked {
                --_i;
            }
            if (_i == 0) {
                _desiredLiquidityIncrease[0] = _usdrAvailable;
            } else {
                uint256 _desiredLiquidity = (_newTotalLiquidity *
                    _pools[_i].ratio) / _totalRatio;
                uint256 _current = _getPoolLiquidity(_pools[_i]);
                if (_desiredLiquidity > _current) {
                    unchecked {
                        uint256 _increaseBy = _desiredLiquidity - _current;
                        if (_increaseBy > _usdrAvailable) {
                            _increaseBy = _usdrAvailable;
                        }
                        _desiredLiquidityIncrease[_i] = _increaseBy;
                        _usdrAvailable -= _increaseBy;
                    }
                }
            }
        }

        // Iterate through pools again to apply the calculated liquidity increase
        for (uint256 _i = _pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            if (_desiredLiquidityIncrease[_i] != 0) {
                IERC20Upgradeable(_usdr).approve(
                    address(liquidityProvider),
                    _desiredLiquidityIncrease[_i]
                );
                uint256 _liquidity = liquidityProvider.addLiquidity(
                    _pools[_i].pair,
                    _usdr,
                    _desiredLiquidityIncrease[_i],
                    0,
                    1
                );
                _stake(_pools[_i], _liquidity);
                emit LiquidityIncreased(
                    address(_pools[_i].pair),
                    _desiredLiquidityIncrease[_i]
                );
            }
        }
    }

    /**
     * @dev Get the total liquidity across all pools
     * @return _liquidity The total liquidity
     */
    function liquidity() public view returns (uint256 _liquidity) {
        _liquidity = _usdrToUnderlying(_liquidityInUSDR());
    }

    /**
     * @dev Get the amount of missing liquidity
     * @return The amount of missing liquidity
     */
    function missingLiquidity() external view returns (uint256) {
        (address _exchange, address _usdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(USDR_EXCHANGE_ADDRESS, USDR_ADDRESS)
            ),
            (address, address)
        );

        uint256 _minSize = IExchange(_exchange).scaleToUnderlying(
            (IERC20Upgradeable(_usdr).totalSupply() * minSizePercent) / 100
        );

        uint256 _currentLiquidity = liquidity();

        unchecked {
            return
                _currentLiquidity < _minSize
                    ? (_minSize - _currentLiquidity)
                    : 0;
        }
    }

    function _getPoolLiquidity(Pool memory _pool)
        internal
        view
        returns (uint256)
    {
        address _usdr = addressProvider.getAddress(USDR_ADDRESS);

        IPair _pair = _pool.pair;
        (uint256 _reserve0, uint256 _reserve1, ) = _pair.getReserves();
        (address _token0, address _token1) = _pair.tokens();

        uint256 _totalSupply = _pair.totalSupply();
        uint256 _balance = IGauge(_pool.gauge).balanceOf(address(this));
        uint256 _share = (_balance * 1e18) / _totalSupply;

        uint256 _amount0 = (_reserve0 * _share) / 1e18;
        uint256 _amount1 = (_reserve1 * _share) / 1e18;

        if (_token0 == _usdr) {
            return _amount0 + _pair.current(_token1, _amount1);
        } else {
            return _amount1 + _pair.current(_token0, _amount0);
        }
    }

    function _addPools(Pool[] memory _pools) internal {
        require(_pools.length != 0, "at least 1 pool required");
        uint256 _totalRatio_;
        for (uint256 _i = _pools.length; _i != 0; ) {
            unchecked {
                --_i;
                _totalRatio_ += _pools[_i].ratio;
            }
            require(_pools[_i].ratio != 0, "ratio must not be 0");
            _validatePair(_pools[_i].pair);
            pools.push(_pools[_i]);
            _stake(
                _pools[_i],
                IERC20Upgradeable(_pools[_i].pair).balanceOf(address(this))
            );
        }
        _totalRatio = _totalRatio_;
    }

    function _liquidityInUSDR() public view returns (uint256 _liquidity) {
        for (uint256 _i = pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            _liquidity += _getPoolLiquidity(pools[_i]);
        }
    }

    function _stake(Pool memory _pool, uint256 _amount) internal {
        if (_amount != 0) {
            _pool.pair.approve(address(_pool.gauge), _amount);
            _pool.gauge.deposit(_amount);
        }
    }

    function _swapUnderlyingToUsdr(uint256 _amount) internal {
        if (_amount != 0) {
            (address _underlying, address _usdr) = abi.decode(
                addressProvider.getAddresses(
                    abi.encode(UNDERLYING_ADDRESS, USDR_ADDRESS)
                ),
                (address, address)
            );
            IPair _pair = IPair(pairFactory.getPair(_usdr, _underlying, true));
            address _token0 = _pair.token0();
            uint256 _amountOut = _pair.getAmountOut(_amount, _underlying);
            IERC20Upgradeable(_underlying).safeTransfer(
                address(_pair),
                _amount
            );
            _pair.swap(
                _token0 == _usdr ? _amountOut : 0,
                _token0 == _usdr ? 0 : _amountOut,
                address(this),
                ""
            );
        }
    }

    function _transferAll(IERC20Upgradeable _token, address _to)
        internal
        returns (uint256 _amount)
    {
        _amount = _token.balanceOf(address(this));
        if (_amount != 0) {
            _token.safeTransfer(_to, _amount);
        }
    }

    function _usdrToUnderlying(uint256 _usdrAmount)
        internal
        view
        returns (uint256 _underlyingAmount)
    {
        (address _underlying, address _usdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(UNDERLYING_ADDRESS, USDR_ADDRESS)
            ),
            (address, address)
        );
        IPair _pair = IPair(pairFactory.getPair(_usdr, _underlying, true));

        _underlyingAmount = (_pair.current(_usdr, 1e9) * _usdrAmount) / 1e9;
    }

    function _underlyingToUsdr(uint256 _underlyingAmount)
        internal
        view
        returns (uint256 _usdrAmount)
    {
        (address _underlying, address _usdr) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(UNDERLYING_ADDRESS, USDR_ADDRESS)
            ),
            (address, address)
        );
        IPair _pair = IPair(pairFactory.getPair(_usdr, _underlying, true));
        _usdrAmount = _pair.current(_underlying, _underlyingAmount);
    }

    function _validatePair(IPair _pair) internal view {
        address _usdr = addressProvider.getAddress(USDR_ADDRESS);
        (address _token0, address _token1) = _pair.tokens();
        require(
            _pair.stable() && (_token0 == _usdr || _token1 == _usdr),
            "invalid pair"
        );
    }

    function _isPool(Pool[] memory _pools, address _pair)
        internal
        pure
        returns (bool)
    {
        for (uint256 _i = _pools.length; _i != 0; ) {
            unchecked {
                --_i;
            }
            if (address(_pools[_i].pair) == _pair) {
                return true;
            }
        }
        return false;
    }
}

interface ISingleTokenLiquidityProvider {
    function addLiquidity(
        IPair _pair,
        address _token,
        uint256 _amount,
        uint256 _swapAmount,
        uint256 _minLiquidity
    ) external returns (uint256 _liquidity);
}

interface IPair is IERC20Upgradeable {
    function current(address _tokenIn, uint256 _amountIn)
        external
        view
        returns (uint256 _amountOut);

    function getAmountOut(uint256 _amountIn, address _tokenIn)
        external
        view
        returns (uint256 _amountOut);

    function getReserves()
        external
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint256 _blockTimestampLast
        );

    function stable() external view returns (bool _stable);

    function swap(
        uint256 _amount0Out,
        uint256 _amount1Out,
        address _to,
        bytes calldata _data
    ) external;

    function token0() external view returns (address _token0);

    function tokens() external view returns (address _token0, address _token1);
}

interface IPairFactory {
    function getPair(
        address _tokenA,
        address _tokenB,
        bool _stable
    ) external view returns (address _pair);
}

interface IGauge {
    function balanceOf(address _account)
        external
        view
        returns (uint256 _balance);

    function deposit(uint256 _amount) external;

    function getReward() external;

    function withdrawAllAndHarvest() external;
}
