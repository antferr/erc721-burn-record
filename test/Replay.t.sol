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

/// @dev Drives random sequences of mint, transfer, approval, burn and re-mint. It keeps two
///      independent sources of the expected record: its own ledger, built from the operations
///      (the owner it reads before each burn), and the record replayed from the logs of every
///      step. The ledger checks that the record is correct; the replay checks that the logs agree.
contract ReplayHandler is Test, LogReplay {
    uint256 public constant ID_SPACE = 8;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ITestToken public immutable token;
    address[] internal actors;

    mapping(uint256 tokenId => address burner) public expectedBurner;

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
        delete expectedBurner[id];
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
        expectedBurner[id] = owner;
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
        expectedBurner[id] = owner;
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
        expectedBurner[id] = owner;
        vm.prank(owner);
        token.setApprovalForAll(op, false);
    }

    function burnInternal(uint256 idSeed) external replayed {
        uint256 id = idSeed % ID_SPACE;
        (bool exists, address owner) = _owner(id);
        if (!exists) return;
        token.internalBurn(id);
        expectedBurner[id] = owner;
    }
}

/// @dev F1: after any sequence of steps, for every id, live, burned or never minted, both
///      {burnedBy} and the record rebuilt from the logs equal the handler's own ledger. A burn that
///      wrote the same wrong address to the event and to {burnedBy} would agree with the replay
///      and still fail against the ledger.
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
    function invariant_ViewAndLogsMatchModel() public view {
        for (uint256 id; id < handler.ID_SPACE(); ++id) {
            address expected = handler.expectedBurner(id);
            assertEq(token.burnedBy(id), expected, "view differs from the model");
            assertEq(handler.replayedBurner(id), expected, "replayed logs differ from the model");
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

/// @dev F2 and F3: fixed lifecycles. After every step both {burnedBy} and the record rebuilt
///      from the logs are compared with the value the test expects, written out step by step.
contract ReplayLifecycleTest is Test, LogReplay {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _check(ITestToken token, uint256 tokenId, address expected, string memory step) internal {
        _replay(vm.getRecordedLogs(), address(token));
        assertEq(token.burnedBy(tokenId), expected, string.concat(step, ": view"));
        assertEq(replayedBurner[tokenId], expected, string.concat(step, ": replayed logs"));
        vm.recordLogs();
    }

    function _lifecycle(ITestToken token) internal {
        vm.recordLogs();

        token.mint(alice, 1);
        _check(token, 1, address(0), "after mint");

        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        _check(token, 1, address(0), "after transfer");

        vm.prank(bob);
        token.approve(carol, 1);
        vm.prank(carol);
        token.burn(1);
        _check(token, 1, bob, "after burn by an approved operator, owner not operator");

        token.mint(carol, 1);
        _check(token, 1, address(0), "after re-mint");

        token.internalBurn(1);
        _check(token, 1, carol, "after internal burn, last owner");
    }

    // F2
    function test_Lifecycle_WriteOnBurn() public {
        _lifecycle(ITestToken(address(new BurnRecordToken())));
    }

    // F2
    function test_Lifecycle_ClearOnMint() public {
        _lifecycle(ITestToken(address(new ClearOnMintBurnRecordToken())));
    }

    // F3: tokens minted in a batch at construction emit no `Transfer`, as ERC-721 allows
    //     (OpenZeppelin emits the ERC-2309 `ConsecutiveTransfer` instead). The replay never
    //     sees their mint and still agrees with the view, because a burn always emits
    //     `Transfer`. The expected burner comes from the constructor arguments.
    function test_Lifecycle_ConsecutiveMintWithoutTransfer() public {
        vm.recordLogs();
        ConsecutiveBurnRecordToken token = new ConsecutiveBurnRecordToken(alice, 4);
        _replay(vm.getRecordedLogs(), address(token));
        for (uint256 id; id < 4; ++id) {
            assertEq(token.ownerOf(id), alice, "batch-minted token owner");
            assertEq(token.burnedBy(id), address(0), "batch-minted token before burn: view");
            assertEq(replayedBurner[id], address(0), "batch-minted token before burn: replayed logs");
        }

        vm.recordLogs();
        vm.prank(alice);
        token.burn(2);
        _replay(vm.getRecordedLogs(), address(token));
        assertEq(token.burnedBy(2), alice, "after burn: view");
        assertEq(replayedBurner[2], alice, "after burn: replayed logs");
    }
}
