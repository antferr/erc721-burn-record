# ERC-8423 burn record: reference implementation

[![CI](https://github.com/antferr/erc721-burn-record/actions/workflows/test.yml/badge.svg)](https://github.com/antferr/erc721-burn-record/actions/workflows/test.yml)

Reference implementation and tests for ERC-8423, a proposed ERC-721 extension that lets other contracts read, through `burnedBy`, the address recorded as the owner of a token when it was burned.

ERC-8423 is published as a Draft: https://eips.ethereum.org/EIPS/eip-8423. Feedback on the semantics belongs in the discussion thread:
https://ethereum-magicians.org/t/erc-8423-erc-721-burn-record-extension/29732

## Why

Burning a token emits a `Transfer` event to the zero address, and indexers store it, but contracts cannot read logs. A contract that holds everything and performs the burn itself does not need this extension: it can read the owner before burning. The record matters when the burn and the claim come apart:

- several contracts hold value for the same token without knowing about each other. Only one of them can perform the burn; the others still need to know, later and independently, whom to release to;
- value reaches a contract after the burn, such as rewards still accruing to the token. A contract that burns and pays in one step can only pay what exists at that moment.

Each custodian could keep its own record of who burned, but then a contract that did not perform the burn has no standard place to look. This extension keeps that fact once, where the burn happens. The contract's state is the source of truth, `burnedBy` is how other contracts read it, and the `Transfer` to `address(0)` announces the change; the specification requires a non-zero answer to match the burn's `Transfer` in the logs, which `test/Replay.t.sol` checks. `test/Consumers.t.sol` shows both cases.

## Interface

```solidity
/// @dev The ERC-165 identifier for this interface is 0x43470a89
interface IERC721BurnRecord /* is IERC721, IERC165 */ {
    /// @notice Get the owner of a token at the time it was burned
    /// @dev Returns address(0) when no burn record exists for `tokenId`
    /// @param tokenId The token to query
    /// @return The owner at the time of the burn, or address(0)
    function burnedBy(uint256 tokenId) external view returns (address);
}
```

## Semantics in brief

The normative text is the Specification of ERC-8423. In short:

- The recorded address is the `from` of the `Transfer` event emitted by the burn, that is, the owner at the time of the burn. When an approved operator burns a token, the record names the owner, not the operator. When a contract holds a token and burns it, the record names that contract.
- `address(0)` means that no burn record exists: the token exists, was never minted, or was burned before the record existed. A non-zero answer is proof; zero proves nothing. Interfaces that show this record to users should present zero as "no record", never as proof that the token never existed.
- While a token exists, `burnedBy` returns `address(0)`. The extension does not constrain minting, so a token id can be re-minted; `burnedBy` then reports the most recent burn only: it is not a receipt. A consumer that guards value on it should read it once and store the result: at burn time if it takes part in the burn, otherwise at its first request, which leaves a window between the burn and that reading where ids are re-minted.
- The time and the transaction of the burn are not recorded. Burn history and links to transactions still come from the logs.

## Adding ERC-8423 to your project

`ERC721BurnRecord` targets OpenZeppelin Contracts 5.x and extends `_update`, the single path every burn goes through. In a Foundry project, install it next to OpenZeppelin Contracts; 5.7.0 is the version the tests use:

```sh
forge install OpenZeppelin/openzeppelin-contracts@v5.7.0 antferr/erc721-burn-record@v0.1.0
```

Foundry derives the import paths from the `lib` folder. If your project lists its remappings explicitly, add these two lines:

```text
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
erc721-burn-record/=lib/erc721-burn-record/src/
```

Then inherit the extension. The inheriting contract has to resolve two overrides:

```solidity
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721Burnable} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import {ERC721BurnRecord} from "erc721-burn-record/ERC721BurnRecord.sol";

contract MyToken is ERC721, ERC721Burnable, ERC721BurnRecord {
    constructor() ERC721("MyToken", "MTK") {}

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
```

`ERC721Burnable` is not required: every burn goes through `_update`, including burns performed under the contract's own rules, and each one produces a record. Minting is left to your contract, and the extension does not constrain it. To check the result, `supportsInterface(0x43470a89)` must return `true` and, after a burn, `burnedBy` must return the owner at the time of the burn.

The record is written on burns only. While a token exists, `burnedBy` returns zero after checking ownership through `_ownerOf`, so minting pays nothing extra, whatever path mints the token.

## Reading the record from another contract

A contract that releases value after a burn it did not perform reads the record in four steps. The normative rules are in the Specification of ERC-8423, the risks in its Security Considerations.

1. **Choose the token contract, then check it.** The record is only as trustworthy as the contract that exposes it: accept it only from token contracts you already trust, as you would for `ownerOf`. The `supportsInterface(0x43470a89)` check catches a wrong address; it does not prove a faithful implementation.
2. **Read `burnedBy(tokenId)`.** A non-zero answer is the owner at the time of the most recent burn of that id. If a contract held the token when it was burned, the answer is that contract, not the person behind it.
3. **Treat `address(0)` as the absence of authorization.** It covers live tokens, ids never minted and tokens burned before the record existed.
4. **Store the first non-zero reading and use it from then on.** `burnedBy` is not a receipt: if the token contract mints the id again, `burnedBy` returns zero while the new token exists, and names its owner when that token is burned. Read the record at burn time if your contract takes part in the burn, otherwise at its first request for that id. In the second case, if the token contract can re-mint ids, a re-mint followed by a new burn before that first reading would redirect the claim to the second owner: check whether the token contract can re-mint.

The custodian below follows these steps. It holds value for the tokens of a single collection, takes no part in the burn, and pays the recorded owner, including value that arrives after the burn:

```solidity
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {IERC721BurnRecord} from "erc721-burn-record/IERC721BurnRecord.sol";

/// @notice Holds value for the tokens of one collection and releases it to the owner recorded at
///         the burn, including value deposited after the burn. Takes no part in the burn.
contract ExampleCustodian {
    bytes4 private constant BURN_RECORD_INTERFACE = 0x43470a89;

    IERC721BurnRecord public immutable token;
    mapping(uint256 tokenId => uint256 amount) public held;
    mapping(uint256 tokenId => address recipient) public recipientOf;

    error NotABurnRecord(address token);
    error NoRecord(uint256 tokenId);
    error PaymentFailed(address recipient);

    /// @param token_ A token contract the deployer already trusts (step 1).
    constructor(address token_) {
        if (!IERC165(token_).supportsInterface(BURN_RECORD_INTERFACE)) revert NotABurnRecord(token_);
        token = IERC721BurnRecord(token_);
    }

    function deposit(uint256 tokenId) external payable {
        held[tokenId] += msg.value;
    }

    /// @dev Anyone may trigger the release: the value always goes to the stored recipient.
    function release(uint256 tokenId) external {
        address recipient = recipientOf[tokenId];
        if (recipient == address(0)) {
            recipient = token.burnedBy(tokenId); // step 2
            if (recipient == address(0)) revert NoRecord(tokenId); // step 3
            recipientOf[tokenId] = recipient; // step 4
        }
        uint256 amount = held[tokenId];
        held[tokenId] = 0;
        (bool ok,) = recipient.call{value: amount}("");
        if (!ok) revert PaymentFailed(recipient);
    }
}
```

The two contracts above are in `test/mocks/Examples.sol`, which continuous integration compiles and exercises. `test/Examples.t.sol` checks each step, including the window before the first reading.

## Layout

| Path | Content |
|---|---|
| `src/IERC721BurnRecord.sol` | The interface, verbatim from the proposal |
| `src/ERC721BurnRecord.sol` | Reference implementation for OpenZeppelin Contracts 5.x |
| `test/Semantics.t.sol` | Specification tests, run against two implementation variants |
| `test/Invariants.t.sol` | Random sequences of mint, transfer, approval, burn and re-mint |
| `test/Replay.t.sol` | `burnedBy` and the record rebuilt only from the `Transfer` logs, as an indexer would, both checked after every step against a model built from the operations |
| `test/Consumers.t.sol` | Example consumers: redemption at burn time, claims, independent custodians releasing later, value settled after the burn |
| `test/Gas.t.sol` | Cost of the extension |
| `test/Composition.t.sol` | Composition with `ERC721Enumerable` and `ERC721Consecutive` |
| `test/Examples.t.sol` | The examples in this README: the token and the custodian |
| `test/mocks/` | Test tokens, example consumers and the examples in this README |
| `.github/workflows/test.yml` | Continuous integration: format check, build and tests |

## Build and test

Requires [Foundry](https://getfoundry.sh). The dependencies are not vendored: install them at the pinned versions after cloning.

```sh
git clone https://github.com/antferr/erc721-burn-record
cd erc721-burn-record
forge install foundry-rs/forge-std@v1.16.2 OpenZeppelin/openzeppelin-contracts@v5.7.0
forge test
```

The same steps run on GitHub Actions at every push, with Foundry v1.8.3.

## Measured cost

Measured with cold storage, before gas refunds, with solc 0.8.37, EVM version osaka and the optimizer at 200 runs.

| Operation | Without the extension | With the extension |
|---|---|---|
| Mint | 69,154 | 69,298 |
| Burn | 36,967 | 59,446 |
| `burnedBy`, burned token | | 5,133 |
| `burnedBy`, live token | | 2,953 |

The overhead of a burn is one new storage slot.

## Status

Draft ERC-8423. The interface may change while the proposal is a draft. The code has not been audited.

## License

[CC0-1.0](LICENSE). Author: Antonio Ferraioli.
