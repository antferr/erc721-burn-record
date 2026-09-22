// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ITestToken, BurnRecordToken} from "./mocks/Tokens.sol";
import {
    AtomicRedeemer,
    NaiveClaimer,
    SnapshotClaimer,
    Custodian,
    PayingRedeemer,
    LateSettlement
} from "./mocks/Consumers.sol";

/// @dev Group C of the test plan: consumer patterns. Demonstrative, repository only.
contract ConsumersTest is Test {
    ITestToken internal token;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal keeper = makeAddr("keeper");

    function setUp() public {
        token = ITestToken(address(new BurnRecordToken()));
    }

    // C1
    function test_AtomicRedeem_RecordsHolder() public {
        AtomicRedeemer redeemer = new AtomicRedeemer(token);
        token.mint(alice, 1);
        vm.startPrank(alice);
        token.approve(address(redeemer), 1);
        redeemer.redeem(1);
        vm.stopPrank();

        assertEq(token.burnedBy(1), alice, "record must name the holder");
        assertTrue(token.burnedBy(1) != address(redeemer), "record must not name the redeemer");
        assertEq(redeemer.redeemedBy(1), alice);
    }

    // C2
    function test_Consumer_ZeroIsNoAuthorization() public {
        NaiveClaimer naive = new NaiveClaimer(token);
        SnapshotClaimer snapshot = new SnapshotClaimer(token);

        token.mint(alice, 1); // live token: record is zero
        vm.startPrank(alice);
        vm.expectRevert(NaiveClaimer.NoRecord.selector);
        naive.claim(1);
        vm.expectRevert(SnapshotClaimer.NoRecord.selector);
        snapshot.claim(1);

        // never minted token: record is zero
        vm.expectRevert(NaiveClaimer.NoRecord.selector);
        naive.claim(99);
        vm.expectRevert(SnapshotClaimer.NoRecord.selector);
        snapshot.claim(99);
        vm.stopPrank();

        assertEq(naive.payouts() + snapshot.payouts(), 0);
    }

    // C3
    function test_NaiveConsumer_ReadsLive() public {
        NaiveClaimer naive = new NaiveClaimer(token);
        SnapshotClaimer snapshot = new SnapshotClaimer(token);

        // alice burns id 1 and claims on both consumers
        token.mint(alice, 1);
        vm.startPrank(alice);
        token.burn(1);
        naive.claim(1);
        snapshot.claim(1);
        vm.stopPrank();

        // the token contract re-mints id 1 to bob, who burns it
        token.mint(bob, 1);
        vm.startPrank(bob);
        token.burn(1);

        // the naive consumer pays a second time for the same id
        naive.claim(1);
        assertEq(naive.payouts(), 2, "naive consumer paid twice for id 1");

        // the snapshot consumer treated its first reading as final
        vm.expectRevert(SnapshotClaimer.AlreadyClaimed.selector);
        snapshot.claim(1);
        vm.stopPrank();
        assertEq(snapshot.payouts(), 1);
    }

    // C4
    function test_IndependentCustodians_ReleaseLater() public {
        Custodian first = new Custodian(token);
        Custodian second = new Custodian(token);
        token.mint(alice, 7);
        vm.deal(address(this), 3 ether);
        first.deposit{value: 1 ether}(7);
        second.deposit{value: 2 ether}(7);

        // before the burn, neither custodian releases anything
        vm.expectRevert(Custodian.NoRecord.selector);
        first.release(7);
        vm.expectRevert(Custodian.NoRecord.selector);
        second.release(7);

        // the token changes hands, then its owner burns it without involving the custodians
        vm.prank(alice);
        token.transferFrom(alice, bob, 7);
        vm.prank(bob);
        token.burn(7);

        // later, in separate transactions and in any order, anyone triggers the releases
        vm.roll(block.number + 10);
        vm.prank(keeper);
        second.release(7);
        vm.roll(block.number + 50);
        vm.prank(carol);
        first.release(7);

        // both paid the owner at the time of the burn, once
        assertEq(bob.balance, 3 ether);
        assertEq(alice.balance + carol.balance + keeper.balance, 0);
        assertEq(first.releasedTo(7), bob);
        assertEq(second.releasedTo(7), bob);
        vm.expectRevert(Custodian.AlreadyReleased.selector);
        first.release(7);
        vm.expectRevert(Custodian.AlreadyReleased.selector);
        second.release(7);
    }

    // C5
    function test_ValueAfterBurn_ClaimedByBurner() public {
        PayingRedeemer redeemer = new PayingRedeemer(token);
        LateSettlement settlement = new LateSettlement(token);
        token.mint(alice, 9);
        vm.deal(address(this), 2 ether);
        redeemer.deposit{value: 1 ether}(9);
        settlement.accrue{value: 0.3 ether}(9); // accrued before the burn

        // nothing can be claimed while the token exists
        vm.prank(alice);
        vm.expectRevert(LateSettlement.NoRecord.selector);
        settlement.claim(9);

        // the redeemer burns the token and pays what it holds, in one transaction
        vm.startPrank(alice);
        token.approve(address(redeemer), 9);
        redeemer.redeem(9);
        vm.stopPrank();
        assertEq(alice.balance, 1 ether);
        assertEq(token.burnedBy(9), alice, "the record names the holder, not the redeemer");

        // more value reaches the settlement contract after the burn
        settlement.accrue{value: 0.2 ether}(9);

        // only the recorded burner can claim it
        vm.prank(carol);
        vm.expectRevert(LateSettlement.NotBurner.selector);
        settlement.claim(9);
        vm.prank(address(redeemer));
        vm.expectRevert(LateSettlement.NotBurner.selector);
        settlement.claim(9);

        vm.prank(alice);
        settlement.claim(9);
        assertEq(alice.balance, 1.5 ether);
        assertEq(carol.balance, 0);
    }
}
