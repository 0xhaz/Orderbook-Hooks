// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.24;

interface IOrderbookFactory {
    struct Pair {
        address base;
        address quote;
    }

    function createBook(address bid_, address ask_) external returns (address orderbook);

    function getBook(uint256 bookId_) external view returns (address orderbook);

    function getPair(address base, address quote) external view returns (address);

    function getBaseQuote(address orderbook) external view returns (address base, address quote);

    function allPairsLength() external view returns (uint256);

    // Address of a manager
    function engine() external view returns (address);

    function getPairs(uint256 start, uint256 end) external view returns (Pair[] memory);

    function getPairsWithIds(uint256[] memory ids) external view returns (Pair[] memory);

    function getPairNames(uint256 start, uint256 end) external view returns (string[] memory names);

    function getPairNamesWithIds(uint256[] memory ids) external view returns (string[] memory names);
}
