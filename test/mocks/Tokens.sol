// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721Enumerable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import {ERC721Consecutive} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Consecutive.sol";
import {IERC721BurnRecord} from "../../src/IERC721BurnRecord.sol";
import {ERC721BurnRecord} from "../../src/ERC721BurnRecord.sol";

/// @dev Common surface used by the tests. Both implementation variants expose it.
interface ITestToken is IERC721, IERC721BurnRecord {
    function mint(address to, uint256 tokenId) external;
    function burn(uint256 tokenId) external;
    function internalBurn(uint256 tokenId) external;
}

/// @dev Variant (b), the reference implementation: record written on burn only,
///      masked by an existence check in the getter.
contract BurnRecordToken is ERC721, ERC721Burnable, ERC721BurnRecord {
    constructor() ERC721("BurnRecordToken", "BRT") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    /// @dev Burn path with no authorization check, as used by contracts that burn
    ///      under their own rules (expiry, caps, and so on).
    function internalBurn(uint256 tokenId) external {
        _burn(tokenId);
    }

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

/// @dev Variant (a), used only to show that the specification tests do not depend
///      on the implementation: record written on burn and cleared on mint.
contract ClearOnMintBurnRecordToken is ERC721, ERC721Burnable, IERC721BurnRecord {
    mapping(uint256 tokenId => address burner) private _burners;

    constructor() ERC721("ClearOnMintBurnRecordToken", "COM") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function internalBurn(uint256 tokenId) external {
        _burn(tokenId);
    }

    function burnedBy(uint256 tokenId) external view returns (address) {
        return _burners[tokenId];
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == type(IERC721BurnRecord).interfaceId || super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = super._update(to, tokenId, auth);
        if (to == address(0) && from != address(0)) {
            _burners[tokenId] = from;
        } else if (from == address(0) && to != address(0)) {
            delete _burners[tokenId];
        }
        return from;
    }
}

/// @dev Plain burnable token with no record, baseline for the cost measurement.
contract PlainBurnableToken is ERC721, ERC721Burnable {
    constructor() ERC721("PlainBurnableToken", "PLN") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev A contract that holds tokens and burns them, like a router or a marketplace.
contract HolderContract is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function burn(ITestToken token, uint256 tokenId) external {
        token.burn(tokenId);
    }
}

/// @dev The extension combined with ERC721Enumerable.
contract EnumerableBurnRecordToken is ERC721, ERC721Enumerable, ERC721Burnable, ERC721BurnRecord {
    constructor() ERC721("EnumerableBurnRecordToken", "ENU") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Enumerable, ERC721BurnRecord)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _increaseBalance(address account, uint128 value) internal override(ERC721, ERC721Enumerable) {
        super._increaseBalance(account, value);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721Enumerable, ERC721BurnRecord)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}

/// @dev The extension combined with ERC721Consecutive: tokens minted in a batch in the
///      constructor, with no `Transfer` event at mint, as ERC-721 allows.
contract ConsecutiveBurnRecordToken is ERC721Consecutive, ERC721Burnable, ERC721BurnRecord {
    constructor(address holder, uint96 batchSize) ERC721("ConsecutiveBurnRecordToken", "CON") {
        _mintConsecutive(holder, batchSize);
    }

    function _update(address to, uint256 tokenId, address auth)
        internal
        override(ERC721, ERC721Consecutive, ERC721BurnRecord)
        returns (address)
    {
        return super._update(to, tokenId, auth);
    }

    function _ownerOf(uint256 tokenId) internal view override(ERC721, ERC721Consecutive) returns (address) {
        return super._ownerOf(tokenId);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, ERC721BurnRecord) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
