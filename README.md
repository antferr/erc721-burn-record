# ERC-721 burn record: reference implementation

[![CI](https://github.com/antferr/erc721-burn-record/actions/workflows/test.yml/badge.svg)](https://github.com/antferr/erc721-burn-record/actions/workflows/test.yml)

Reference implementation and tests for a proposed ERC-721 extension that lets other contracts read, through `burnedBy`, the address recorded as the owner of a token when it was burned.

The proposal is under discussion on the Fellowship of Ethereum Magicians and has no ERC number yet. Feedback on the semantics belongs in the thread:
https://ethereum-magicians.org/t/erc-721-burn-record-extension/29732

## Why

Burning a token emits a `Transfer` event to the zero address, and indexers store it, but contracts cannot read logs. A contract that holds everything and performs the burn itself does not need this extension: it can read the owner before burning. The record matters when the burn and the claim come apart:

- several contracts hold value for the same token without knowing about each other. Only one of them can perform the burn; the others still need to know, later and independently, whom to release to;
- value reaches a contract after the burn, such as rewards still accruing to the token. A contract that burns and pays in one step can only pay what exists at that moment.

Each custodian could keep its own record of who burned, but then a contract that did not perform the burn has no standard place to look. This extension keeps that fact once, where the burn happens. The contract's state is the source of truth, `burnedBy` is how other contracts read it, and the `Transfer` to `address(0)` announces the change; the specification requires the two views never to disagree. `test/Consumers.t.sol` shows both cases.

## Interface

```solidity
/// @dev The ERC-165 identifier for this interface is 0x43470a89
interface IERC721BurnRecord /* is IERC721, IERC165 */ {
    /// @notice Get the address recorded as having burned a token
    /// @dev Returns address(0) when no burn record exists for `tokenId`
    /// @param tokenId The token to query
    /// @return The address that burned the token, or address(0)
    function burnedBy(uint256 tokenId) external view returns (address);
}
```

## Semantics in brief

The normative text is in the discussion thread. In short:

- The recorded address is the `from` of the `Transfer` event emitted by the burn, that is, the owner at the time of the burn. When an approved operator burns a token, the record names the owner, not the operator. When a contract holds a token and burns it, the record names that contract.
- `address(0)` means that no burn record exists: the token exists, was never minted, or was burned before the record existed. A non-zero answer is proof; zero proves nothing. Interfaces that show this record to users should present zero as "no record", never as proof that the token never existed.
- While a token exists, `burnedBy` returns `address(0)`. The extension does not constrain minting, so a token id can be re-minted; `burnedBy` then reports the most recent burn only: it is not a receipt. A consumer that guards value on it should read it once and store the result: at burn time if it takes part in the burn, otherwise at its first request, which leaves a window between the burn and that reading where ids are re-minted.
- The time and the transaction of the burn are not recorded. Burn history and links to transactions still come from the logs.

## Using the implementation

`ERC721BurnRecord` targets OpenZeppelin Contracts 5.x and extends `_update`, the single path every burn goes through. The inheriting contract has to resolve two overrides:

```solidity
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

The record is written on burns only. While a token exists, `burnedBy` returns zero after checking ownership through `_ownerOf`, so minting pays nothing extra, whatever path mints the token.

## Layout

| Path | Content |
|---|---|
| `src/IERC721BurnRecord.sol` | The interface, verbatim from the proposal |
| `src/ERC721BurnRecord.sol` | Reference implementation for OpenZeppelin Contracts 5.x |
| `test/Semantics.t.sol` | Specification tests, run against two implementation variants |
| `test/Invariants.t.sol` | Random sequences of mint, transfer, approval, burn and re-mint |
| `test/Consumers.t.sol` | Example consumers: redemption at burn time, claims, independent custodians releasing later, value settled after the burn |
| `test/Gas.t.sol` | Cost of the extension |
| `test/Composition.t.sol` | Composition with `ERC721Enumerable` and `ERC721Consecutive` |
| `test/mocks/` | Test tokens and example consumers |
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

Proposal under discussion. The interface may change before it is assigned a number.

## License

[CC0-1.0](LICENSE). Author: Antonio Ferraioli.
