// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Address.sol";

import "./constants/addresses.sol";
import "./interfaces/IExchange.sol";
import "./interfaces/ITokenSwap.sol";
import "./AddressAccessor.sol";

contract USDRExchangeProxy is AddressAccessor, Pausable {
    using Address for address;
    using SafeERC20 for IERC20;

    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function getAmountOut(address token, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        (address underlying, address tokenSwap, address exchange) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(
                    UNDERLYING_ADDRESS,
                    TOKEN_SWAP_ADDRESS,
                    USDR_EXCHANGE_ADDRESS
                )
            ),
            (address, address, address)
        );
        amountOut = ITokenSwap(tokenSwap).quoteOut(token, underlying, amountIn);
        amountOut /= 1e9; // 18 to 9 decimals
        uint256 depositFee = abi.decode(
            exchange.functionStaticCall(
                abi.encodeWithSignature("depositFee()")
            ),
            (uint256)
        );
        if (depositFee > 0) {
            amountOut = amountOut - ((amountOut * depositFee) / 100e2);
        }
    }

    function swapFromToken(
        address token,
        uint256 amountIn,
        uint256 minAmountOut,
        address to
    ) external whenNotPaused returns (uint256 amountOut) {
        (address underlying, address tokenSwap, address exchange) = abi.decode(
            addressProvider.getAddresses(
                abi.encode(
                    UNDERLYING_ADDRESS,
                    TOKEN_SWAP_ADDRESS,
                    USDR_EXCHANGE_ADDRESS
                )
            ),
            (address, address, address)
        );
        IERC20(token).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(token).approve(tokenSwap, amountIn);
        amountOut = ITokenSwap(tokenSwap).exchange(
            token,
            underlying,
            amountIn,
            0,
            ITokenSwap.EXCHANGE_TYPE.EXACT_INPUT
        );
        IERC20(underlying).approve(exchange, amountOut);
        amountOut = IExchange(exchange).swapFromUnderlying(amountOut, to);
        require(amountOut >= minAmountOut, "output amount too low");
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }
}
