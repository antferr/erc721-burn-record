// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {IERC721BurnRecord} from "./IERC721BurnRecord.sol";

/// @title Reference implementation of the ERC-721 burn record extension
/// @notice Lets other contracts read which address burned a token. The contract's state
///         is the source of truth, {burnedBy} is how other contracts read it, and the
///         `Transfer` event emitted by the burn announces the change.
/// @dev In OpenZeppelin Contracts 5.x every burn path goes through {ERC721-_update},
///      which returns the owner before the update: that is the single point to extend.
///      The stored record is written only on burns, and {burnedBy} reads state, not the
///      stored record alone: while a token exists it returns zero, whatever the stored
///      record holds and whatever path minted the token, so re-minting needs no extra write.
abstract contract ERC721BurnRecord is ERC721, IERC721BurnRecord {
    mapping(uint256 tokenId => address burner) private _burners;

    /// @inheritdoc IERC721BurnRecord
    function burnedBy(uint256 tokenId) public view virtual returns (address) {
        if (_ownerOf(tokenId) != address(0)) {
            return address(0);
        }
        return _burners[tokenId];
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC721BurnRecord).interfaceId || super.supportsInterface(interfaceId);
    }

    /// @dev Records the burner when `to` is the zero address. `from` is the owner
    ///      returned by {ERC721-_update}, the same address carried by the `Transfer`
    ///      event, so the getter and the log cannot disagree.
    function _update(address to, uint256 tokenId, address auth) internal virtual override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (to == address(0) && from != address(0)) {
            _burners[tokenId] = from;
        }
        return from;
    }
}
