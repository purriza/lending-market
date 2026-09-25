// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Chainlink-style aggregator whose answer and freshness can be driven from tests.
contract MockOracle {
    uint8 public constant decimals = 18;

    int256 private _answer;
    uint256 private _updatedAt;
    uint80 private _roundId;

    constructor(int256 initialAnswer) {
        _answer = initialAnswer;
        _updatedAt = block.timestamp;
        _roundId = 1;
    }

    /// @notice Writes a fresh answer, stamped at the current block time.
    function setPrice(int256 newAnswer) external {
        _answer = newAnswer;
        _updatedAt = block.timestamp;
        _roundId += 1;
    }

    /// @notice Writes an answer without moving the update timestamp, simulating a stalled feed.
    function setPriceStale(int256 newAnswer) external {
        _answer = newAnswer;
        _roundId += 1;
    }

    /// @notice Explicitly backdates the feed.
    function setUpdatedAt(uint256 timestamp) external {
        _updatedAt = timestamp;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return (_roundId, _answer, _updatedAt, _updatedAt, _roundId);
    }
}
