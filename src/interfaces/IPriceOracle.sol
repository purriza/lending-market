// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @notice Chainlink-style aggregator interface used by the market for collateral pricing.
interface IPriceOracle {
    /// @return roundId          the round the answer was computed in
    /// @return answer           collateral price denominated in the base asset, 1e18 scaled
    /// @return startedAt        round start timestamp
    /// @return updatedAt        timestamp the answer was last written
    /// @return answeredInRound  the round the answer was carried over from
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function decimals() external view returns (uint8);
}
