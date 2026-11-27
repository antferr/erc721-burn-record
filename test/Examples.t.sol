// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MyToken, ExampleCustodian} from "./mocks/Examples.sol";
import {PlainBurnableToken} from "./mocks/Tokens.sol";

/// @dev The README's token, with a mint function added for the tests only: the README leaves
///      minting to the inheriting contract.
contract MyTokenHarness is MyToken {
    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @dev The examples shown in the README, checked step by step.
contract ExamplesTest is Test {
    MyTokenHarness internal token;
    ExampleCustodian internal custodian;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        token = new MyTokenHarness();
        custodian = new ExampleCustodian(address(token));
        vm.deal(address(this), 10 ether);
    }

    // Checking the result of "Adding ERC-8423 to your project"
    function test_MyToken_DeclaresInterfaces() public view {
        assertTrue(token.supportsInterface(0x43470a89), "ERC-8423");
        assertTrue(token.supportsInterface(0x80ac58cd), "ERC-721");
        assertTrue(token.supportsInterface(0x01ffc9a7), "ERC-165");
        assertFalse(token.supportsInterface(0xffffffff));
    }

    function test_MyToken_RecordsOwnerNotOperator() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.approve(carol, 1);
        vm.prank(carol);
        token.burn(1);
        assertEq(token.burnedBy(1), alice, "record must name the owner, not the operator");
    }

    // Step 1
    function test_Custodian_RejectsTokenWithoutInterface() public {
        PlainBurnableToken plain = new PlainBurnableToken();
        vm.expectRevert(abi.encodeWithSelector(ExampleCustodian.NotABurnRecord.selector, address(plain)));
        new ExampleCustodian(address(plain));
    }

    // Step 3
    function test_Custodian_ZeroIsNoAuthorization() public {
        token.mint(alice, 1);
        custodian.deposit{value: 1 ether}(1);

        vm.expectRevert(abi.encodeWithSelector(ExampleCustodian.NoRecord.selector, 1));
        custodian.release(1); // live token

        vm.expectRevert(abi.encodeWithSelector(ExampleCustodian.NoRecord.selector, 99));
        custodian.release(99); // never minted

        assertEq(address(custodian).balance, 1 ether);
    }

    // Step 2
    function test_Custodian_ReleasesToRecordedOwner() public {
        token.mint(alice, 1);
        custodian.deposit{value: 1 ether}(1);
        vm.prank(alice);
        token.approve(carol, 1);
        vm.prank(carol);
        token.burn(1);

        vm.prank(keeper);
        custodian.release(1);

        assertEq(alice.balance, 1 ether, "value goes to the owner at the burn");
        assertEq(carol.balance, 0);
        assertEq(keeper.balance, 0);
        assertEq(custodian.recipientOf(1), alice);
    }

    // Step 4
    function test_Custodian_ValueAfterTheBurnGoesToStoredRecipient() public {
        token.mint(alice, 1);
        custodian.deposit{value: 1 ether}(1);
        vm.prank(alice);
        token.burn(1);
        custodian.release(1);

        custodian.deposit{value: 0.5 ether}(1); // arrives after the burn
        vm.prank(keeper);
        custodian.release(1);

        assertEq(alice.balance, 1.5 ether);
        assertEq(address(custodian).balance, 0);
    }

    // Step 4
    function test_Custodian_StoredReadingSurvivesReMint() public {
        token.mint(alice, 1);
        vm.prank(alice);
        token.burn(1);
        custodian.release(1); // first reading stored: alice

        token.mint(bob, 1);
        vm.prank(bob);
        token.burn(1);
        assertEq(token.burnedBy(1), bob, "the record now describes the most recent burn");

        custodian.deposit{value: 1 ether}(1);
        custodian.release(1);

        assertEq(alice.balance, 1 ether, "the stored reading still decides");
        assertEq(bob.balance, 0);
    }

    // Step 4: the limit stated in the Security Considerations of ERC-8423
    function test_Custodian_WindowBeforeFirstReading() public {
        token.mint(alice, 1);
        custodian.deposit{value: 1 ether}(1);
        vm.prank(alice);
        token.burn(1);

        // Re-mint and a new burn before the custodian's first reading
        token.mint(bob, 1);
        vm.prank(bob);
        token.burn(1);

        custodian.release(1);

        assertEq(bob.balance, 1 ether, "the window redirects the value to the second burner");
        assertEq(alice.balance, 0);
    }
}
