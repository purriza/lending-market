# LendingMarket

Single-collateral money market. Suppliers deposit the base asset and earn interest, borrowers post collateral and draw the base asset against it, and positions that fall below their borrowing power can be liquidated.

## Running it

The project is self-contained. `forge-std` is vendored under `lib/`, so no network access or `forge install` is needed.

```bash
forge build
forge test
forge test -vvv --match-test <name>     # a single test, with traces
```

Requires Foundry. If you do not have it: `curl -L https://foundry.paradigm.xyz | bash && foundryup`

## Layout

```
src/
  LendingMarket.sol                 the implementation, and the only file you need to change
  TransparentUpgradeableProxy.sol   the proxy the market is deployed behind
  interfaces/                       IERC20, IPriceOracle (Chainlink-style aggregator)
  mocks/                            test doubles for the base asset, collateral and oracle
script/
  Deploy.s.sol                      staging deployment, mirrors the production topology
test/
  LendingMarket.t.sol               the suite the market ships with today
```

## How it works

**Accounting.** Supplier and borrower balances are stored as *principal* and scaled by two global indices, `baseSupplyIndex` and `baseBorrowIndex`. `accrueInterest()` advances both to the current timestamp. Present value is `principal * index / 1e18`, so a balance grows without anyone touching per-account storage.

**Scaling.** Everything is 1e18 fixed point unless stated otherwise. The oracle quotes the collateral in base-asset terms, also 1e18. So with WETH at 2,000 base, `getPrice()` returns `2000e18`.

**Borrowing power.** `collateralBalance * price * collateralFactor`, all 1e18 scaled. A position is healthy while its borrowing power covers its debt. `isHealthy()` is the single source of truth for this, and it is checked on any path that increases risk.

**Liquidation.** Once a position is unhealthy, anyone may repay part of its debt and receive collateral in exchange, plus the liquidation incentive. The incentive is 1e18 scaled and always at or above par, so `1.10e18` means the liquidator receives 110% of what they repaid, valued in collateral.

**Deployment.** The market is an implementation behind a `TransparentUpgradeableProxy`. All market state lives in the proxy's storage, which is why any change you make has to be layout-compatible with what is already deployed. The admin owns upgrades and risk parameters. A separate pause guardian exists so the market can be stopped quickly without reaching for the admin key.

## Roles

| Role | Held by | Remit |
|---|---|---|
| `admin` | governance timelock | upgrades, risk parameters, wiring |
| `pauseGuardian` | operations multisig | stopping the market in an incident |

The split matters. The guardian key is warmer and held by more people than the admin key, so anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything.

## Listed markets

See `script/Deploy.s.sol` for the current staging configuration.

## Findings

### 1. Guardian must not be able to set the oracle — Critical

`setOracle` was gated on `onlyGuardian`. A compromised guardian key could set the price near zero and liquidate every open position. This is the boundary the Roles section above already draws: *"anything the guardian can reach should be limited to stopping the market, not changing how it prices or values anything."*

**Changed:** `setOracle` is now `onlyAdmin`. No storage change, so it ships as a plain proxy upgrade.

**Tests:** `test_guardianCannotSetTheOracle` and `test_adminCanSetTheOracle`.

### 2. Liquidation must seize collateral worth the incentivised repayment — Critical

`seizeAmount` was `repayAmount * liquidationIncentive / FACTOR`, which is an amount of the base asset but it was subtracted from a collateral balance without ever asking the oracle for a price. Repaying 1,000 against a borrower holding 10 WETH at 1,800 took all 10 WETH, worth 18,000, instead of the 0.6111 WETH the liquidator was owed. The line that caps `seizeAmount` at the borrower's balance kept this from reverting, so the error was silent. The borrower is left with no collateral and an open debt that no liquidator has any reason to clear and that loss stays with the suppliers.

**Changed:** `seizeAmount` is now `repayAmount * liquidationIncentive / getPrice()`, which converts the incentivised repayment into collateral units. No storage change, so it ships as a plain proxy upgrade.

**Tests:** `test_liquidationSeizesCollateralWorthTheIncentivisedRepayment`.

### 3. The market must reject bad and stale oracle answers — Critical

`getPrice` took one of the five values the oracle returns and checked none of them. The oracle reports the price as a signed number and the market turns it into an unsigned one, so a negative answer becomes a gigantic one and a borrower with almost no collateral could take the whole pool. A zero answer fails the other way round: all collateral is worth nothing and every open position becomes liquidatable at once. There was no check on `updatedAt` either, so if the feed stopped updating the market kept lending against the last price it had seen.

**Changed:** `getPrice` now requires the answer to be above zero and no older than `MAX_PRICE_AGE`. I made that threshold a constant rather than a parameter the admin can update. A new variable could be appended at the end of the storage layout safely but it would read as zero on the live proxy, so every price would count as stale until someone set it and the market would have to be paused around the upgrade to avoid that. I chose to give up the governance knob for compatibility with a contract that already holds user funds. No storage change, so it ships as a plain proxy upgrade.

**Tests:** `test_negativePriceIsRejected`, `test_stalePriceIsRejected` and `test_refreshedPriceIsAcceptedAgain`.

## Scope note

**Priorities.** I fixed the three defects that can drain the market outright and left unfixed the missing `accrueInterest()` in `withdrawCollateral` (leaks only the interest not yet accrued), the absent close factor in `liquidate` (overcharges the borrower rather than the protocol) and the unprotected `initialize` on the implementation (harmless behind a transparent proxy).

**Unsure.** `MAX_PRICE_AGE` is one hour because that is the usual Chainlink heartbeat and no test reaches the branch that caps `seizeAmount` at the borrower's balance.

**AI tooling.** Used throughout, mostly for tests and wording, with every figure re-derived by hand before I accepted it. I rejected a suggestion for the staleness fix, a governable `maxPriceAge` storage variable, because a new slot reads as zero on a live proxy and would freeze pricing the moment the upgrade landed. Although it would be better from a governance point of view.
