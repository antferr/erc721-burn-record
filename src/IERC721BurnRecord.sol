// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

/// @dev The ERC-165 identifier for this interface is 0x43470a89
interface IERC721BurnRecord /* is IERC721, IERC165 */ {
    /// @notice Get the address recorded as having burned a token
    /// @dev Returns address(0) when no burn record exists for `tokenId`
    /// @param tokenId The token to query
    /// @return The address that burned the token, or address(0)
    function burnedBy(uint256 tokenId) external view returns (address);
}
