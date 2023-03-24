// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.9;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./constants/addresses.sol";
import "./constants/roles.sol";
import "./AddressAccessor.sol";

/**
 * @title TreasuryRentCollector
 * @notice Collects rent for a treasury contract from a real estate contract
 * @dev Uses a list of NFTs held in the treasury to find and collect rent
 */
contract TreasuryRentCollector is AddressAccessor, Pausable {
    using Address for address;

    address public realEstateContractAddress;

    /**
     * @dev Grants the default admin role to the deployer and sets the real estate contract address
     * @param realEstateContractAddress_ Address of the real estate contract
     */
    constructor(address realEstateContractAddress_) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        realEstateContractAddress = realEstateContractAddress_;
    }

    /**
     * @notice Sets the address of the real estate contract
     * @param realEstateContractAddress_ Address of the real estate contract
     */
    function setRealEstateContractAddress(address realEstateContractAddress_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        realEstateContractAddress = realEstateContractAddress_;
    }

    /**
     * @notice Pauses the contract
     */
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses the contract
     */
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    /**
     * @notice Entry point for Gelato task runner.
     */
    function execute(bytes memory data) external {
        address(this).functionCall(data);
    }

    /**
     * @notice Collects rent for the specified NFT held in the treasury
     * @param index Index of the NFT in the treasury
     * @param isFraction True if the NFT is a fractional NFT, false otherwise
     */
    function collectRent(uint256 index, bool isFraction)
        external
        whenNotPaused
    {
        (address rentShare, address treasury, address treasuryTracker) = abi
            .decode(
                addressProvider.getAddresses(
                    abi.encode(
                        TANGIBLE_RENT_SHARE_ADDRESS,
                        TREASURY_ADDRESS,
                        TREASURY_TRACKER_ADDRESS
                    )
                ),
                (address, address, address)
            );
        (
            address revenueShare,
            address contractAddress,
            uint256 tokenId
        ) = isFraction
                ? _prepareRentCollectionForFraction(
                    rentShare,
                    treasuryTracker,
                    index
                )
                : _prepareRentCollection(rentShare, treasuryTracker, index);
        _collect(treasury, revenueShare, contractAddress, tokenId);
    }

    /**
     * @notice Defractionalizes the specified tokens
     * @param nft Address of the fractional NFT contract
     * @param tokenIds IDs of the tokens to defractionalize
     */
    function defractionalize(address nft, uint256[] memory tokenIds) external {
        address treasury = addressProvider.getAddress(TREASURY_ADDRESS);
        treasury.functionCall(
            abi.encodeWithSelector(
                TreasuryRentCollector.defractionalize.selector,
                nft,
                tokenIds
            )
        );
    }

    function _collect(
        address treasury,
        address revenueShare,
        address contractAddress,
        uint256 tokenId
    ) private {
        treasury.functionCall(
            abi.encodeWithSignature(
                "claimRentForToken(address,address,uint256)",
                revenueShare,
                contractAddress,
                tokenId
            )
        );
    }

    function _prepareRentCollectionForFraction(
        address rentShare,
        address treasuryTracker,
        uint256 index
    )
        private
        view
        returns (
            address revenueShare,
            address fractionContractAddress,
            uint256 fractionTokenId
        )
    {
        (fractionContractAddress, fractionTokenId) = _fraction(
            treasuryTracker,
            index
        );
        (address contractAddress, uint256 tokenId) = _nft(
            fractionContractAddress
        );
        address distributor = _distributor(rentShare, contractAddress, tokenId);
        revenueShare = _revenueShare(distributor);
    }

    function _prepareRentCollection(
        address rentShare,
        address treasuryTracker,
        uint256 index
    )
        private
        view
        returns (
            address revenueShare,
            address contractAddress,
            uint256 tokenId
        )
    {
        contractAddress = realEstateContractAddress;
        tokenId = _token(treasuryTracker, index);
        address distributor = _distributor(rentShare, contractAddress, tokenId);
        revenueShare = _revenueShare(distributor);
    }

    function _token(address treasuryTracker, uint256 index)
        private
        view
        returns (uint256)
    {
        return
            toUint256(
                treasuryTracker.functionStaticCall(
                    abi.encodeWithSignature(
                        "tnftTokensInTreasury(address,uint256)",
                        realEstateContractAddress,
                        index
                    )
                )
            );
    }

    function _fraction(address treasuryTracker, uint256 index)
        private
        view
        returns (address, uint256)
    {
        address fractionContractAddress = toAddress(
            treasuryTracker.functionStaticCall(
                abi.encodeWithSignature(
                    "tnftFractionsContracts(address,uint256)",
                    realEstateContractAddress,
                    index
                )
            )
        );
        return (
            fractionContractAddress,
            toUint256(
                treasuryTracker.functionStaticCall(
                    abi.encodeWithSignature(
                        "fractionTokensInTreasury(address,uint256)",
                        fractionContractAddress,
                        index
                    )
                )
            )
        );
    }

    function _nft(address fractionContractAddress)
        private
        view
        returns (address, uint256)
    {
        return (
            toAddress(
                fractionContractAddress.functionStaticCall(
                    abi.encodeWithSignature("tnft()")
                )
            ),
            toUint256(
                fractionContractAddress.functionStaticCall(
                    abi.encodeWithSignature("tnftTokenId()")
                )
            )
        );
    }

    function _distributor(
        address rentShare,
        address contractAddress,
        uint256 tokenId
    ) private view returns (address) {
        return
            toAddress(
                rentShare.functionStaticCall(
                    abi.encodeWithSignature(
                        "distributorForToken(address,uint256)",
                        contractAddress,
                        tokenId
                    )
                )
            );
    }

    function _revenueShare(address distributor) private view returns (address) {
        return
            toAddress(
                distributor.functionStaticCall(
                    abi.encodeWithSignature("rentShareContract()")
                )
            );
    }

    /**
     * @dev Converts a byte array to an address.
     * @param data The byte array to convert.
     * @return The address corresponding to the input byte array.
     */
    function toAddress(bytes memory data) internal pure returns (address) {
        require(data.length == 32, "Invalid input length");
        return abi.decode(data, (address));
    }

    /**
     * @dev Converts a byte array to a uint256.
     * @param data The byte array to convert.
     * @return The uint256 corresponding to the input byte array.
     */
    function toUint256(bytes memory data) internal pure returns (uint256) {
        require(data.length == 32, "Invalid input length");
        return abi.decode(data, (uint256));
    }
}
