// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {EnumerableBurnRecordToken, ConsecutiveBurnRecordToken} from "./mocks/Tokens.sol";

/// @dev Group E of the test plan: composition with other OpenZeppelin extensions.
contract CompositionTest is Test {
    bytes32 internal constant TRANSFER_SIG = keccak256("Transfer(address,address,uint256)");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    // E1
    function test_ComposesWith_Enumerable() public {
        EnumerableBurnRecordToken token = new EnumerableBurnRecordToken();
        token.mint(alice, 1);
        token.mint(alice, 2);
        token.mint(bob, 3);
        assertEq(token.totalSupply(), 3);

        vm.prank(alice);
        token.burn(2);

        assertEq(token.totalSupply(), 2);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.tokenOfOwnerByIndex(alice, 0), 1);
        assertEq(token.burnedBy(2), alice);
        assertEq(token.burnedBy(1), address(0));
        assertTrue(token.supportsInterface(0x43470a89));
        assertTrue(token.supportsInterface(0x780e9d63), "ERC-721 Enumerable");
    }

    // E2
    function test_ComposesWith_Consecutive() public {
        vm.recordLogs();
        ConsecutiveBurnRecordToken token = new ConsecutiveBurnRecordToken(alice, 5);
        Vm.Log[] memory deployLogs = vm.getRecordedLogs();
        for (uint256 i; i < deployLogs.length; ++i) {
            assertTrue(deployLogs[i].topics[0] != TRANSFER_SIG, "batch mint must not emit Transfer");
        }

        // a live batch-minted token: the getter reads ownership through the batch structure
        assertEq(token.ownerOf(2), alice);
        assertEq(token.burnedBy(2), address(0));

        vm.recordLogs();
        vm.prank(alice);
        token.burn(2);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        address from;
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == TRANSFER_SIG && logs[i].topics.length == 4) {
                from = address(uint160(uint256(logs[i].topics[1])));
                found++;
            }
        }
        assertEq(found, 1, "burn must emit Transfer");
        assertEq(from, alice);
        assertEq(token.burnedBy(2), from);
    }
}
