// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {ITestToken, BurnRecordToken, ClearOnMintBurnRecordToken, ConsecutiveBurnRecordToken} from "./mocks/Tokens.sol";

/// @dev Rebuilds the burn record the way an indexer would: only from the `Transfer`
///      logs the token emitted, with no access to the token's state. A burn sets the
///      record to the `from` of the log, and a mint clears it, so the replayed record
///      follows the same rules a contract reads through {burnedBy}.
abstract contract LogReplay {
    bytes32 internal constant TRANSFER_TOPIC = keccak256("Transfer(address,address,uint256)");

    mapping(uint256 tokenId => address burner) public replayedBurner;

    function _replay(Vm.Log[] memory logs, address token) internal {
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory entry = logs[i];
            if (entry.emitter != token || entry.topics.length != 4 || entry.topics[0] != TRANSFER_TOPIC) {
                continue;
            }
            address from = address(uint160(uint256(entry.topics[1])));
            address to = address(uint160(uint256(entry.topics[2])));
            uint256 tokenId = uint256(entry.topics[3]);
            if (to == address(0)) {
                replayedBurner[tokenId] = from;
            } else if (from == address(0)) {
                delete replayedBurner[tokenId];
            }
        }
    }
}

/// @dev Drives random sequences of mint, transfer, approval, burn and re-mint, records the
///      logs of every step and replays them. It keeps no ledger of its own: what it knows
///      comes from the logs only.
contract ReplayHandler is Test, LogReplay {
    uint256 public constant ID_SPACE = 8;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ITestToken public immutable token;
    address[] internal actors;

    constructor(ITestToken token_) {
        token = token_;
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        actors.push(makeAddr("actor3"));
    }

    modifier replayed() {
        vm.recordLogs();
        _;
        _replay(vm.getRecordedLogs(), address(token));
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

    function mint(uint256 actorSeed, uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists,) = _owner(id);
        if (exists) return;
        token.mint(_actor(actorSeed), id);
    }

    function transfer(uint256 toSeed, uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        vm.prank(owner);
        token.transferFrom(owner, _actor(toSeed), id);
    }

    function transferToDead(uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists || owner == DEAD) return;
        vm.prank(owner);
        token.transferFrom(owner, DEAD, id);
    }

    function burnByOwner(uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        vm.prank(owner);
        token.burn(id);
    }

    function burnByApproved(uint256 opSeed, uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        address op = _actor(opSeed);
        if (!exists || op == owner) return;
        vm.prank(owner);
        token.approve(op, id);
        vm.prank(op);
        token.burn(id);
    }

    function burnByOperatorForAll(uint256 opSeed, uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        address op = _actor(opSeed);
        if (!exists || op == owner) return;
        vm.prank(owner);
        token.setApprovalForAll(op, true);
        vm.prank(op);
        token.burn(id);
        vm.prank(owner);
        token.setApprovalForAll(op, false);
    }

    function burnInternal(uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists,) = _owner(id);
        if (!exists) return;
        token.internalBurn(id);
    }
}

/// @dev F1: after any sequence of steps, the record rebuilt from the logs equals {burnedBy}
///      for every id, live, burned or never minted.
abstract contract ReplayInvariantsTest is Test {
    ITestToken internal token;
    ReplayHandler internal handler;

    function _deploy() internal virtual returns (ITestToken);

    function setUp() public {
        token = _deploy();
        handler = new ReplayHandler(token);
        targetContract(address(handler));
    }

    // F1
    function invariant_ViewEqualsReplayedLogs() public view {
        for (uint256 id; id < handler.ID_SPACE(); ++id) {
            assertEq(token.burnedBy(id), handler.replayedBurner(id), "view differs from replayed logs");
        }
    }
}

contract ReplayInvariantsWriteOnBurnTest is ReplayInvariantsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new BurnRecordToken()));
    }
}

contract ReplayInvariantsClearOnMintTest is ReplayInvariantsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new ClearOnMintBurnRecordToken()));
    }
}

/// @dev F2 and F3: fixed lifecycles, compared with the view after every step.
contract ReplayLifecycleTest is Test, LogReplay {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _check(ITestToken token, uint256 tokenId, string memory step) internal {
        _replay(vm.getRecordedLogs(), address(token));
        assertEq(token.burnedBy(tokenId), replayedBurner[tokenId], step);
        vm.recordLogs();
    }

    function _lifecycle(ITestToken token) internal {
        vm.recordLogs();

        token.mint(alice, 1);
        _check(token, 1, "after mint");

        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        _check(token, 1, "after transfer");

        vm.prank(bob);
        token.approve(carol, 1);
        vm.prank(carol);
        token.burn(1);
        _check(token, 1, "after burn by an approved operator");
        assertEq(replayedBurner[1], bob, "replay names the owner, not the operator");

        token.mint(carol, 1);
        _check(token, 1, "after re-mint");

        token.internalBurn(1);
        _check(token, 1, "after internal burn");
        assertEq(replayedBurner[1], carol, "replay names the last owner");
    }

    // F2
    function test_Lifecycle_WriteOnBurn() public {
        _lifecycle(ITestToken(address(new BurnRecordToken())));
    }

    // F2
    function test_Lifecycle_ClearOnMint() public {
        _lifecycle(ITestToken(address(new ClearOnMintBurnRecordToken())));
    }

    // F3: tokens minted in a batch at construction emit no `Transfer`, as ERC-721 allows.
    //     The replay never sees their mint, and still agrees with the view, because a
    //     burn always emits `Transfer` and that is the only log the record depends on.
    function test_Lifecycle_ConsecutiveMintWithoutTransfer() public {
        vm.recordLogs();
        ConsecutiveBurnRecordToken token = new ConsecutiveBurnRecordToken(alice, 4);
        _replay(vm.getRecordedLogs(), address(token));
        for (uint256 id; id < 4; ++id) {
            assertEq(token.burnedBy(id), replayedBurner[id], "batch-minted token before burn");
        }

        vm.recordLogs();
        vm.prank(alice);
        token.burn(2);
        _replay(vm.getRecordedLogs(), address(token));
        assertEq(token.burnedBy(2), alice, "view after burn");
        assertEq(replayedBurner[2], alice, "replay after burn");
    }
}
