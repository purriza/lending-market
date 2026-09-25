// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {LendingMarket} from "../src/LendingMarket.sol";
import {TransparentUpgradeableProxy} from "../src/TransparentUpgradeableProxy.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockOracle} from "../src/mocks/MockOracle.sol";

/**
 * @notice The suite the market ships with today. It covers the happy paths and nothing else,
 *         which is roughly where the coverage stood when this went to production.
 *
 *         Treat it as a starting point rather than a specification. Extend it.
 */
contract LendingMarketTest is Test {
    uint256 internal constant FACTOR = 1e18;
    uint256 internal constant RATE_PER_SECOND = uint256(0.05e18) / 365 days;

    address internal admin = makeAddr("admin");
    address internal guardian = makeAddr("guardian");
    address internal supplier = makeAddr("supplier");
    address internal borrower = makeAddr("borrower");
    address internal liquidator = makeAddr("liquidator");

    MockERC20 internal base;
    MockERC20 internal weth;
    MockOracle internal wethOracle;

    LendingMarket internal market;

    function setUp() public {
        base = new MockERC20("Base USD", "bUSD", 18);
        weth = new MockERC20("Wrapped Ether", "WETH", 18);
        wethOracle = new MockOracle(2_000e18);

        LendingMarket impl = new LendingMarket();
        bytes memory initData = abi.encodeCall(
            LendingMarket.initialize,
            (
                admin,
                guardian,
                address(wethOracle),
                address(base),
                address(weth),
                0.80e18,
                1.10e18,
                RATE_PER_SECOND
            )
        );
        market = LendingMarket(address(new TransparentUpgradeableProxy(address(impl), admin, initData)));

        // Seed the market with base liquidity for borrowers to draw against.
        base.mint(supplier, 1_000_000e18);
        vm.startPrank(supplier);
        base.approve(address(market), type(uint256).max);
        market.supply(1_000_000e18);
        vm.stopPrank();
    }

    function _postCollateral(address who, uint256 amount) internal {
        weth.mint(who, amount);
        vm.startPrank(who);
        weth.approve(address(market), type(uint256).max);
        market.supplyCollateral(amount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------------------------------

    function test_supplyCreditsTheSupplier() public {
        assertApproxEqAbs(market.supplyBalanceOf(supplier), 1_000_000e18, 1);
    }

    function test_withdrawReturnsBase() public {
        vm.prank(supplier);
        market.withdraw(1_000e18);

        assertEq(base.balanceOf(supplier), 1_000e18);
    }

    function test_borrowAgainstCollateral() public {
        _postCollateral(borrower, 10e18); // 20,000 of collateral, 16,000 of borrowing power

        vm.prank(borrower);
        market.borrow(5_000e18);

        assertEq(base.balanceOf(borrower), 5_000e18);
        assertApproxEqAbs(market.borrowBalanceOf(borrower), 5_000e18, 1);
        assertTrue(market.isHealthy(borrower));
    }

    function test_borrowBeyondBorrowingPowerReverts() public {
        _postCollateral(borrower, 10e18);

        vm.prank(borrower);
        vm.expectRevert("would be undercollateralized");
        market.borrow(17_000e18);
    }

    function test_repayClearsTheDebt() public {
        _postCollateral(borrower, 10e18);

        vm.startPrank(borrower);
        market.borrow(5_000e18);
        base.approve(address(market), type(uint256).max);
        market.repay(5_000e18);
        vm.stopPrank();

        assertEq(market.borrowBalanceOf(borrower), 0);
    }

    function test_interestAccruesOnOpenDebt() public {
        _postCollateral(borrower, 10e18);

        vm.prank(borrower);
        market.borrow(10_000e18);

        vm.warp(block.timestamp + 365 days);
        wethOracle.setPrice(2_000e18);
        market.accrueInterest();

        assertGt(market.borrowBalanceOf(borrower), 10_000e18);
    }

    function test_underwaterPositionCanBeLiquidated() public {
        _postCollateral(borrower, 10e18);

        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_800e18); // borrowing power falls to 14,400
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 1_000e18);
        vm.stopPrank();

        assertGt(weth.balanceOf(liquidator), 0);
    }

    function test_guardianCanPause() public {
        vm.prank(guardian);
        market.setPaused(true);

        assertTrue(market.paused());
    }

    // ---------------------------------------------------------------------------------------
    // Finding 1: Guardian must not be able to set the oracle
    // ---------------------------------------------------------------------------------------

    function test_guardianCannotSetTheOracle() public {
        MockOracle newOracle = new MockOracle(2_500e18);

        vm.prank(guardian);
        vm.expectRevert("not admin");
        market.setOracle(address(newOracle));

        assertEq(address(market.oracle()), address(wethOracle));
        assertEq(market.getPrice(), 2_000e18);
    }

    function test_adminCanSetTheOracle() public {
        MockOracle newOracle = new MockOracle(2_500e18);

        vm.prank(admin);
        market.setOracle(address(newOracle));

        assertEq(address(market.oracle()), address(newOracle));
        assertEq(market.getPrice(), 2_500e18);
    }

    // ---------------------------------------------------------------------------------------
    // Finding 2: Liquidation must seize collateral worth the repayment plus the incentive
    // ---------------------------------------------------------------------------------------

    function test_liquidationSeizesCollateralWorthTheIncentivisedRepayment() public {
        _postCollateral(borrower, 10e18);

        vm.prank(borrower);
        market.borrow(15_000e18);

        wethOracle.setPrice(1_800e18); // borrowing power falls to 14,400
        assertFalse(market.isHealthy(borrower));

        base.mint(liquidator, 1_000e18);
        vm.startPrank(liquidator);
        base.approve(address(market), type(uint256).max);
        market.liquidate(borrower, 1_000e18);
        vm.stopPrank();

        // 1,000 repaid at a 1.10 incentive is 1,100 of value, which at 1,800 per WETH is
        // 0.6111 WETH. The original treated 1,100 as a WETH amount and took all 10 WETH.
        uint256 seized = weth.balanceOf(liquidator);
        assertEq(seized, 611_111_111_111_111_111);
        // seizeAmount truncates, so revaluing it falls short by at most one wei of collateral
        assertApproxEqAbs(seized * market.getPrice() / FACTOR, 1_100e18, market.getPrice() / FACTOR);

        assertEq(market.collateralBalance(borrower), 10e18 - seized);
        assertEq(market.borrowBalanceOf(borrower), 14_000e18);
    }

    // ---------------------------------------------------------------------------------------
    // Finding 3: The market must reject bad and stale oracle answers
    // ---------------------------------------------------------------------------------------

    function test_negativePriceIsRejected() public {
        _postCollateral(borrower, 10e18);

        wethOracle.setPrice(-1);

        vm.expectRevert("bad price");
        market.getPrice();

        vm.prank(borrower);
        vm.expectRevert("bad price");
        market.borrow(1e18);
    }

    function test_stalePriceIsRejected() public {
        _postCollateral(borrower, 10e18);

        vm.warp(block.timestamp + 2 hours);

        vm.expectRevert("stale price");
        market.getPrice();

        vm.prank(borrower);
        vm.expectRevert("stale price");
        market.borrow(1e18);
    }

    function test_refreshedPriceIsAcceptedAgain() public {
        vm.warp(block.timestamp + 2 hours);
        wethOracle.setPrice(2_000e18);

        assertEq(market.getPrice(), 2_000e18);
    }
}
