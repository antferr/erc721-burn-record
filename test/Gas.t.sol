// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ITestToken, BurnRecordToken, ClearOnMintBurnRecordToken, PlainBurnableToken} from "./mocks/Tokens.sol";

/// @dev Group D of the test plan: cost of the extension. Storage is cooled before each
///      measurement, so the figures include cold access as in a real transaction.
///      Gas refunds, applied at the end of a transaction, are not included.
contract GasTest is Test {
    address internal alice = makeAddr("alice");

    function _measureMint(address token, uint256 id) internal returns (uint256 used) {
        address to = alice; // read before measuring: the test's own storage must not count
        vm.cool(token);
        uint256 g = gasleft();
        ITestToken(token).mint(to, id);
        used = g - gasleft();
    }

    function _measureBurn(address token, uint256 id) internal returns (uint256 used) {
        vm.cool(token);
        vm.prank(alice);
        uint256 g = gasleft();
        ITestToken(token).burn(id);
        used = g - gasleft();
    }

    function _measureRead(address token, uint256 id) internal returns (uint256 used) {
        vm.cool(token);
        uint256 g = gasleft();
        ITestToken(token).burnedBy(id);
        used = g - gasleft();
    }

    // D1
    function test_Gas_BurnOverhead() public {
        address plain = address(new PlainBurnableToken());
        address writeOnBurn = address(new BurnRecordToken());
        address clearOnMint = address(new ClearOnMintBurnRecordToken());

        uint256 mintPlain = _measureMint(plain, 1);
        uint256 mintWrite = _measureMint(writeOnBurn, 1);
        uint256 mintClear = _measureMint(clearOnMint, 1);

        uint256 burnPlain = _measureBurn(plain, 1);
        uint256 burnWrite = _measureBurn(writeOnBurn, 1);
        uint256 burnClear = _measureBurn(clearOnMint, 1);

        uint256 readBurned = _measureRead(writeOnBurn, 1);
        ITestToken(writeOnBurn).mint(alice, 2);
        uint256 readLive = _measureRead(writeOnBurn, 2);

        console.log("mint, plain                 ", mintPlain);
        console.log("mint, write on burn  (b)    ", mintWrite);
        console.log("mint, clear on mint  (a)    ", mintClear);
        console.log("burn, plain                 ", burnPlain);
        console.log("burn, write on burn  (b)    ", burnWrite);
        console.log("burn, clear on mint  (a)    ", burnClear);
        console.log("mint overhead (a)           ", mintClear - mintPlain);
        console.log("burn overhead (b)           ", burnWrite - burnPlain);
        console.log("burnedBy, burned token (b)  ", readBurned);
        console.log("burnedBy, live token (b)    ", readLive);

        // The overhead of a burn is one new storage slot. Bounds are generous on purpose:
        // the test guards against unexpected extra writes, not against exact figures.
        assertGt(burnWrite, burnPlain);
        assertLt(burnWrite - burnPlain, 30_000);
        // Variant (b) must not add cost to minting beyond noise; variant (a) pays for
        // clearing the record slot on every mint.
        assertLt(mintWrite > mintPlain ? mintWrite - mintPlain : 0, 500);
        assertGt(mintClear, mintWrite);
    }
}
