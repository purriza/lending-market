// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/**
 * @notice Deployment used for staging. Mirrors the production topology: the implementation
 *         behind a transparent proxy, with an admin and a separate pause guardian.
 *
 *         One market is listed today:
 *           - WETH : plain 18-decimal collateral, priced at 2,000 base
 */
contract Deploy {
    address public admin = address(0xA11CE);
    address public pauseGuardian = address(0x6DA12D);

    LendingMarket public wethMarket;

    MockERC20 public base;
    MockERC20 public weth;
    MockOracle public wethOracle;

    function run() external {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(2_000e18);

        wethMarket = _deployMarket(address(weth), address(wethOracle), 0.80e18, 1.10e18);
    }

    function _deployMarket(address collateral, address oracle, uint256 collateralFactor, uint256 incentive)
        internal
        returns (LendingMarket)
    {
        LendingMarket impl = new LendingMarket();

        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                pauseGuardian,
                oracle,
                address(base),
                collateral,
                collateralFactor,
                incentive,
                // ~5% APR expressed per second
                uint256(0.05e18) / 365 days
            )
        );

        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), admin, initData);

        return LendingMarket(address(proxy));
    }
}
