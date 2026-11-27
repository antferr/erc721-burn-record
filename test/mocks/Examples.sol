// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {ERC721BurnRecord} from "../../src/ERC721BurnRecord.sol";
import {IERC721BurnRecord} from "../../src/IERC721BurnRecord.sol";

contract MyToken is ERC721, ERC721Burnable, ERC721BurnRecord {
    constructor() ERC721("MyToken", "MTK") {}

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721BurnRecord)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721BurnRecord) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}

/// @notice Holds value for the tokens of one collection and releases it to the owner recorded at
///         the burn, including value deposited after the burn. Takes no part in the burn.
contract ExampleCustodian {
    bytes4 private constant BURN_RECORD_INTERFACE = 0x43470a89;

    IERC721BurnRecord public immutable token;
    mapping(uint256 tokenId => uint256 amount) public held;
    mapping(uint256 tokenId => address recipient) public recipientOf;

    error NotABurnRecord(address token);
    error NoRecord(uint256 tokenId);
    error PaymentFailed(address recipient);

    /// @param token_ A token contract the deployer already trusts (step 1).
    constructor(address token_) {
        if (!IERC165(token_).supportsInterface(BURN_RECORD_INTERFACE)) revert NotABurnRecord(token_);
        token = IERC721BurnRecord(token_);
    }

    function deposit(uint256 tokenId) external payable {
        held[tokenId] += msg.value;
    }

    /// @dev Anyone may trigger the release: the value always goes to the stored recipient.
    function release(uint256 tokenId) external {
        address recipient = recipientOf[tokenId];
        if (recipient == address(0)) {
            recipient = token.burnedBy(tokenId); // step 2
            if (recipient == address(0)) revert NoRecord(tokenId); // step 3
            recipientOf[tokenId] = recipient; // step 4
        }
        uint256 amount = held[tokenId];
        held[tokenId] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert PaymentFailed(recipient);
    }
}
