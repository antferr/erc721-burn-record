// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC721BurnRecord} from "../src/IERC721BurnRecord.sol";
import {ITestToken, BurnRecordToken, ClearOnMintBurnRecordToken, HolderContract} from "./mocks/Tokens.sol";

/// @dev Specification tests (groups A and B of the test plan). They only use what the
///      specification requires, and they run against both implementation variants.
abstract contract SemanticsTest is Test {
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    ITestToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _deploy() internal virtual returns (ITestToken);

    function setUp() public {
        token = _deploy();
    }

    // A1
    function test_LiveToken_ReturnsZero() public {
        token.mint(alice, 1);
        assertEq(token.burnedBy(1), address(0));
    }

    // A2
    function test_NeverMinted_ReturnsZero() public view {
        assertEq(token.burnedBy(42), address(0));
    }

    // A3
    function testFuzz_NeverReverts(uint256 tokenId, bool mintIt, bool burnIt) public {
        if (mintIt) {
            token.mint(alice, tokenId);
            if (burnIt) {
                vm.prank(alice);
                token.burn(tokenId);
            }
        }
        token.burnedBy(tokenId);
    }

    // A4
    function test_OwnerBurn_RecordsOwner() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.burn(1);
        assertEq(token.burnedBy(1), alice);
    }

    // A5
    function test_Record_EqualsTransferFrom() public {
        token.mint(alice, 7);
        vm.prank(alice);
        token.transferFrom(alice, bob, 7);

        vm.recordLogs();
        vm.prank(bob);
        token.burn(7);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        address from;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (
                l.emitter == address(token) && l.topics.length == 4 && l.topics[0] == TRANSFER_SIG
                    && address(uint160(uint256(l.topics[2]))) == address(0) && uint256(l.topics[3]) == 7
            ) {
                from = address(uint160(uint256(l.topics[1])));
                found++;
            }
        }
        assertEq(found, 1, "exactly one burn Transfer expected");
        assertEq(token.burnedBy(7), from, "record differs from the log");
        assertEq(from, bob);
    }

    // A6
    function test_ApprovedBurn_RecordsOwnerNotOperator() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.approve(carol, 1);
        vm.prank(carol);
        token.burn(1);
        assertEq(token.burnedBy(1), alice);
        assertTrue(token.burnedBy(1) != carol);
    }

    // A7
    function test_OperatorForAllBurn_RecordsOwner() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.setApprovalForAll(carol, true);
        vm.prank(carol);
        token.burn(1);
        assertEq(token.burnedBy(1), alice);
    }

    // A8
    function test_InternalBurnPath_Records() public {
        token.mint(alice, 1);
        token.internalBurn(1); // called by this test contract, not by the owner
        assertEq(token.burnedBy(1), alice);
    }

    // A9
    function test_ContractHolderBurn_RecordsContract() public {
        HolderContract holder = new HolderContract();
        token.mint(address(holder), 1);
        holder.burn(token, 1);
        assertEq(token.burnedBy(1), address(holder));
    }

    // A10
    function test_DeadAddress_IsNotABurn() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.transferFrom(alice, DEAD, 1);
        assertEq(token.ownerOf(1), DEAD);
        assertEq(token.burnedBy(1), address(0));
    }

    // A11
    function test_Transfers_DoNotWrite() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.transferFrom(alice, bob, 1);
        assertEq(token.burnedBy(1), address(0));
        vm.prank(bob);
        token.transferFrom(bob, carol, 1);
        assertEq(token.burnedBy(1), address(0));
    }

    // A12
    function test_Remint_ReturnsZero() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.burn(1);
        assertEq(token.burnedBy(1), alice);
        token.mint(bob, 1);
        assertEq(token.burnedBy(1), address(0));
    }

    // A13
    function test_Reburn_ReportsMostRecent() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.burn(1);
        token.mint(bob, 1);
        vm.prank(bob);
        token.burn(1);
        assertEq(token.burnedBy(1), bob);
    }

    // B1
    function test_InterfaceId_IsSelector() public pure {
        assertEq(type(IERC721BurnRecord).interfaceId, bytes4(0x43470a89));
        assertEq(IERC721BurnRecord.burnedBy.selector, bytes4(0x43470a89));
    }

    // B2
    function test_Supports_BurnRecord() public view {
        assertTrue(token.supportsInterface(0x43470a89));
    }

    // B3
    function test_Supports_ERC721_ERC165() public view {
        assertTrue(token.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(token.supportsInterface(0x01ffc9a7), "ERC-165");
    }

    // B4
    function test_Rejects_0xffffffff() public view {
        assertFalse(token.supportsInterface(0xffffffff));
    }
}

/// @dev Variant (b): the reference implementation.
contract SemanticsWriteOnBurnTest is SemanticsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new BurnRecordToken()));
    }
}

/// @dev Variant (a): record cleared on mint.
contract SemanticsClearOnMintTest is SemanticsTest {
    function _deploy() internal override returns (ITestToken) {
        return ITestToken(address(new ClearOnMintBurnRecordToken()));
    }
}
