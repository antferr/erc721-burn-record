// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITestToken, BurnRecordToken, ClearOnMintBurnRecordToken} from "./mocks/Tokens.sol";

/// @dev Drives random sequences of mint, transfer, approval, burn and re-mint over a
///      small id space and a few actors, and keeps its own ledger of the last burner.
contract BurnRecordHandler is Test {
    uint256 public constant ID_SPACE = 8;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ITestToken public immutable token;
    address[] internal actors;

    mapping(uint256 tokenId => address burner) public ghostLastBurner;
    mapping(uint256 tokenId => bool) public ghostBurned; // burned and not re-minted since

    constructor(ITestToken token_) {
        token = token_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _owner(uint256 id) internal view returns (bool exists, address owner) {
        try token.ownerOf(id) returns (address o) {
            return (true, o);
        } catch {
            return (false, address(0));
        }
    }

    function _recordBurn(uint256 id, address owner) internal {
        ghostLastBurner[id] = owner;
        ghostBurned[id] = true;
    }

    function mint(uint256 actorSeed, uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists,) = _owner(id);
        if (exists) return;
        token.mint(_actor(actorSeed), id);
        ghostBurned[id] = false;
    }

    function transfer(uint256 toSeed, uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        vm.prank(owner);
        token.transferFrom(owner, _actor(toSeed), id);
    }

    function transferToDead(uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists || owner == DEAD) return;
        vm.prank(owner);
        token.transferFrom(owner, DEAD, id);
    }

    function burnByOwner(uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        vm.prank(owner);
        token.burn(id);
        _recordBurn(id, owner);
    }

    function burnByApproved(uint256 opSeed, uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        address op = _actor(opSeed);
        if (!exists || op == owner) return;
        vm.prank(owner);
        token.approve(op, id);
        vm.prank(op);
        token.burn(id);
        _recordBurn(id, owner);
    }

    function burnByOperatorForAll(uint256 opSeed, uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        address op = _actor(opSeed);
        if (!exists || op == owner) return;
        vm.prank(owner);
        token.setApprovalForAll(op, true);
        vm.prank(op);
        token.burn(id);
        _recordBurn(id, owner);
        vm.prank(owner);
        token.setApprovalForAll(op, false);
    }

    function burnInternal(uint256 idSeed) external {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        token.internalBurn(id);
        _recordBurn(id, owner);
    }
}

abstract contract InvariantsTest is Test {
    ITestToken internal token;
    BurnRecordHandler internal handler;

    function _deploy() internal virtual returns (ITestToken);

    function setUp() public {
        token = _deploy();
        handler = new BurnRecordHandler(token);
        targetContract(address(handler));
    }

    function _exists(uint256 id) internal view returns (bool) {
        try token.ownerOf(id) returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    // A14
    function invariant_NoLiveTokenWithRecord() public view {
        for (uint256 id; id < handler.ID_SPACE(); ++id) {
            if (_exists(id)) {
                assertEq(token.burnedBy(id), address(0), "live token with a record");
            }
        }
    }

    // A15
    function invariant_RecordMatchesLastBurn() public view {
        for (uint256 id; id < handler.ID_SPACE(); ++id) {
            if (_exists(id)) continue;
            if (handler.ghostBurned(id)) {
                assertEq(token.burnedBy(id), handler.ghostLastBurner(id), "record differs from last burn");
            } else {
                assertEq(token.burnedBy(id), address(0), "never minted token with a record");
            }
        }
    }
}

contract InvariantsWriteOnBurnTest is InvariantsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new BurnRecordToken()));
    }
}

contract InvariantsClearOnMintTest is InvariantsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new ClearOnMintBurnRecordToken()));
    }
}
