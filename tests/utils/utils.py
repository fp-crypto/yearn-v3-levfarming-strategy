import ape


def days_to_secs(days: int) -> int:
    return 60 * 60 * 24 * days


def increase_time(chain, seconds):
    chain.pending_timestamp = chain.pending_timestamp + seconds
    chain.mine(timestamp=chain.pending_timestamp)


def lev_strat_status(strategy):

    print(f"--- Strategy {strategy.name()} ---")
    asset = ape.Contract(strategy.asset())
    print(f"Total Assets {to_units(strategy, strategy.totalAssets())}")
    print(f"Total Debt {to_units(strategy, strategy.totalDebt())}")

    strategy = ape.project.LevCompStrategy.at(strategy.address)
    supply, borrows = strategy.livePosition.call()
    print(f"ETA {to_units(asset, strategy.estimatedTotalAssets())}")
    print(f"Want: {to_units(asset, asset.balanceOf(strategy)):,.2f}")
    print(f"Supply: {to_units(asset, supply):,.2f}")
    print(f"Borrow: {to_units(asset, borrows):,.2f}")
    print(f"Collateral Ratio: {(strategy.liveCollatRatio.call()/1e18)*100:,.4f}%")
    print(f"Target Ratio: {(strategy.targetCollatRatio()/1e18)*100:,.4f}%")


def to_units(token, amount):
    return amount / (10 ** token.decimals())
