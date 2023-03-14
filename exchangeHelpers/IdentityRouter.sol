// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

contract IdentityRouter {
    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        pure
        validPath(path)
        returns (uint256[] memory amountsIn)
    {
        amountsIn = new uint256[](2);
        amountsIn[0] = amountsIn[1] = amountOut;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        pure
        validPath(path)
        returns (uint256[] memory amountsOut)
    {
        amountsOut = new uint256[](2);
        amountsOut[0] = amountsOut[1] = amountIn;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address,
        uint256
    ) external pure validPath(path) returns (uint256[] memory amountsOut) {
        require(amountOutMin <= amountIn, "invalid output amount");
        amountsOut = new uint256[](2);
        amountsOut[0] = amountsOut[1] = amountIn;
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address,
        uint256
    ) external pure validPath(path) returns (uint256[] memory amountsOut) {
        require(amountInMax >= amountOut, "invalid input amount");
        amountsOut = new uint256[](2);
        amountsOut[0] = amountsOut[1] = amountInMax;
    }

    modifier validPath(address[] calldata path) {
        require(path.length == 2, "invalid path length");
        require(path[0] == path[1], "invalid path");
        _;
    }
}
