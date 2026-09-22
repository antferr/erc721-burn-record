// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.24;

import {ITestToken} from "./Tokens.sol";

/// @dev Redemption at burn time: the holder approves this contract, which burns the
///      token and reads the record in the same transaction.
contract AtomicRedeemer {
    ITestToken public immutable token;
    mapping(uint256 tokenId => address holder) public redeemedBy;

    error NotOwner();
    error RecordMismatch();

    constructor(ITestToken token_) {
        token = token_;
    }

    function redeem(uint256 tokenId) external {
        if (token.ownerOf(tokenId) != msg.sender) revert NotOwner();
        token.burn(tokenId);
        address burner = token.burnedBy(tokenId);
        if (burner != msg.sender) revert RecordMismatch();
        redeemedBy[tokenId] = burner;
    }
}

/// @dev Reads the record on every claim and keys claims by burner. Unsafe when the
///      token contract re-mints ids: the record only describes the most recent burn.
contract NaiveClaimer {
    ITestToken public immutable token;
    mapping(uint256 tokenId => mapping(address burner => bool)) public claimed;
    uint256 public payouts;

    error NoRecord();
    error NotBurner();
    error AlreadyClaimed();

    constructor(ITestToken token_) {
        token = token_;
    }

    function claim(uint256 tokenId) external {
        address burner = token.burnedBy(tokenId);
        if (burner == address(0)) revert NoRecord();
        if (burner != msg.sender) revert NotBurner();
        if (claimed[tokenId][msg.sender]) revert AlreadyClaimed();
        claimed[tokenId][msg.sender] = true;
        payouts += 1;
    }
}

/// @dev Stores the first reading of the record and treats it as final for that id.
contract SnapshotClaimer {
    ITestToken public immutable token;
    mapping(uint256 tokenId => address claimant) public claimant;
    uint256 public payouts;

    error NoRecord();
    error NotBurner();
    error AlreadyClaimed();

    constructor(ITestToken token_) {
        token = token_;
    }

    function claim(uint256 tokenId) external {
        if (claimant[tokenId] != address(0)) revert AlreadyClaimed();
        address burner = token.burnedBy(tokenId);
        if (burner == address(0)) revert NoRecord();
        if (burner != msg.sender) revert NotBurner();
        claimant[tokenId] = burner;
        payouts += 1;
    }
}

/// @dev Holds value for token ids and releases it, in a later transaction, to the address the
///      record names. It does not take part in the burn and does not know other custodians.
///      The first reading of the record is stored and treated as final for that id.
contract Custodian {
    ITestToken public immutable token;
    mapping(uint256 tokenId => uint256 amount) public held;
    mapping(uint256 tokenId => address recipient) public releasedTo;

    error NoRecord();
    error AlreadyReleased();
    error PaymentFailed();

    constructor(ITestToken token_) {
        token = token_;
    }

    function deposit(uint256 tokenId) external payable {
        held[tokenId] += msg.value;
    }

    /// @dev Anyone may trigger the release: the value always goes to the recorded burner.
    function release(uint256 tokenId) external {
        if (releasedTo[tokenId] != address(0)) revert AlreadyReleased();
        address burner = token.burnedBy(tokenId);
        if (burner == address(0)) revert NoRecord();
        releasedTo[tokenId] = burner;
        uint256 amount = held[tokenId];
        held[tokenId] = 0;
        (bool ok,) = burner.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}

/// @dev Burns the token and pays what it holds for it in the same transaction. It checks
///      ownership before burning, so it does not need the record itself.
contract PayingRedeemer {
    ITestToken public immutable token;
    mapping(uint256 tokenId => uint256 amount) public held;

    error NotOwner();
    error PaymentFailed();

    constructor(ITestToken token_) {
        token = token_;
    }

    function deposit(uint256 tokenId) external payable {
        held[tokenId] += msg.value;
    }

    function redeem(uint256 tokenId) external {
        if (token.ownerOf(tokenId) != msg.sender) revert NotOwner();
        token.burn(tokenId);
        uint256 amount = held[tokenId];
        held[tokenId] = 0;
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}

/// @dev Settles value that reaches it after the burn, such as rewards accrued before the burn
///      and paid out later. Took no part in the burn: only the recorded burner may claim.
contract LateSettlement {
    ITestToken public immutable token;
    mapping(uint256 tokenId => uint256 amount) public accrued;
    mapping(uint256 tokenId => bool) public settled;

    error NoRecord();
    error NotBurner();
    error AlreadySettled();
    error PaymentFailed();

    constructor(ITestToken token_) {
        token = token_;
    }

    function accrue(uint256 tokenId) external payable {
        accrued[tokenId] += msg.value;
    }

    function claim(uint256 tokenId) external {
        address burner = token.burnedBy(tokenId);
        if (burner == address(0)) revert NoRecord();
        if (msg.sender != burner) revert NotBurner();
        if (settled[tokenId]) revert AlreadySettled();
        settled[tokenId] = true;
        uint256 amount = accrued[tokenId];
        accrued[tokenId] = 0;
        (bool ok,) = burner.call{value: amount}("");
        if (!ok) revert PaymentFailed();
    }
}
