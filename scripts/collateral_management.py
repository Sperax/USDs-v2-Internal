from .preset import *
from .utils import get_user, print_dict, get_tx_info

ALLOCATION_THRESHOLD = 100
MINT_THRESHOLD = 10
MIN_INTEREST_TO_COLLECT = 10  # collateral token units, e.g. 10 USDC
MIN_REWARD_TO_COLLECT = 1  # reward token units, e.g. 1 ARB
collaterals = [usdc, usdc_e, usdt, dai, frax, lusd]

collateral_allocation_data = {
    usdc: {aave_strategy: 3333, compound_strategy: 3333, fluid_strategy: 3334},
    usdc_e: {aave_strategy: 5000, compound_strategy: 5000},
    dai: {aave_strategy: 10000},
    lusd: {aave_strategy: 10000},
    usdt: {stargate_strategy: 3333, aave_strategy: 3333, fluid_strategy: 3334},
    frax: {stargate_strategy: 0, aave_strategy: 10000},
}


def get_vault_stat():
    collaterals = [usdc, usdc_e, dai, usdt, lusd, frax]
    total_in_vault = 0
    total_val_in_vault = 0
    total_in_strategies = 0
    total_val_in_strategies = 0
    total_supply_usds = usds.totalSupply() / 10 ** usds.decimals()
    data = {}
    for collateral in collaterals:
        collateral_data = dict()
        decimals = collateral.decimals()
        collateral_price, collateral_price_precision = master_price_oracle.getPrice(
            collateral
        )
        collateral_data['price'] = collateral_price / collateral_price_precision
        collateral_data['collateral_stat'] = get_collateral_stats(collateral)
        collateral_data['collateral_amt_in_vault'] = (
            collateral_manager.getCollateralInVault(collateral) / 10**decimals
        )
        collateral_data['collateral_amt_in_strategies'] = (
            collateral_manager.getCollateralInStrategies(collateral) / 10**decimals
        )
        collateral_data['collateral_val_in_vault'] = (
            collateral_data['collateral_amt_in_vault'] * collateral_data['price']
        )
        collateral_data['collateral_val_in_strategies'] = (
            collateral_data['collateral_amt_in_strategies'] * collateral_data['price']
        )
        collateral_data['fee_data'] = get_collateral_fee(collateral)
        data[collateral] = collateral_data
        total_val_in_vault += collateral_data['collateral_val_in_vault']
        total_val_in_strategies += collateral_data['collateral_val_in_strategies']
        total_in_vault += collateral_data['collateral_amt_in_vault']
        total_in_strategies += collateral_data['collateral_amt_in_strategies']
    total_collateral_amt = total_in_vault + total_in_strategies
    return {
        'total_amt_in_vault': total_in_vault,
        'total_in_strategies': total_in_strategies,
        'total_amount_locked': total_collateral_amt,
        'total_supply_usds': total_supply_usds,
        'collateral_ratio': total_collateral_amt / total_supply_usds,
        'total_val_in_vault': total_val_in_vault,
        'total_val_in_strategies': total_val_in_strategies,
        'tvl': total_val_in_strategies + total_val_in_vault,
        'collateral_data': data,
    }


def get_collateral_strategy_stat(collateral, strategy):
    decimals = collateral.decimals()
    collateral_in_vault = collateral_manager.getCollateralInVault(collateral)
    collateral_in_all_strategies = collateral_manager.getCollateralInStrategies(
        collateral
    )
    total_collateral = collateral_in_vault + collateral_in_all_strategies
    collateral_in_strategy = collateral_manager.getCollateralInAStrategy(
        collateral, strategy
    )
    collateral_cap_for_strategy = collateral_allocation_data[collateral][strategy]
    allocatable_amt = max(
        0,
        min(
            collateral_in_vault,
            ((total_collateral * collateral_cap_for_strategy) / 10000)
            - collateral_in_strategy,
        ),
    )
    interest_earned = strategy.checkInterestEarned(collateral)
    reward_earned = strategy.checkRewardEarned()
    return {
        'allocatable_amt': allocatable_amt / 10**decimals,
        'collateral_in_strategy': collateral_in_strategy / 10**decimals,
        'collateral_in_vault': collateral_in_vault / 10**decimals,
        'total_collateral': total_collateral / 10**decimals,
        'interest_earned': interest_earned / 10**decimals,
        'reward_earned': reward_earned,
        'decimals': decimals,
    }


def get_collateral_fee(collateral):
    fee_prec = 10000
    fee_data = {}
    fee_data['mint_fee'] = fee_calculator.getMintFee(collateral) / fee_prec
    fee_data['redeem_fee'] = fee_calculator.getRedeemFee(collateral) / fee_prec
    return fee_data


def get_collateral_stats(collateral):
    collateral_data = dict()
    for key in collateral_allocation_data[collateral].keys():
        collateral_data[key] = get_collateral_strategy_stat(collateral, key)
    return collateral_data


def allocate_collateral(collateral, owner):
    for key in collateral_allocation_data[collateral].keys():
        collateral_strategy_data = get_collateral_strategy_stat(collateral, key)
        allocatable_amount = collateral_strategy_data['allocatable_amt']
        if allocatable_amount > ALLOCATION_THRESHOLD:
            print(f'allocating {allocatable_amount} {collateral} -> {key}')
            try:
                tx = vault.allocate(
                    collateral,
                    key,
                    int(
                        allocatable_amount * 10 ** collateral_strategy_data['decimals']
                    ),
                    {'from': owner},
                )
                print(tx.info())
            except Exception as e:
                print(f'Error allocating collateral: {e}')
        else:
            print(
                f'Skipping Not enough amount to allocate: {allocatable_amount}, {collateral, key}'
            )


def allocate_all(owner):
    for collateral in collaterals:
        print(f'\nAllocating {collateral}')
        allocate_collateral(collateral, owner)


def get_collaterals_fee():
    collateral_fee_data = {}
    for collateral in collaterals:
        name = collateral.name()
        fee_data = get_collateral_fee(collateral)
        collateral_fee_data[f'{name}_mint'] = fee_data['mint_fee']
        collateral_fee_data[f'{name}_redeem'] = fee_data['redeem_fee']
    return collateral_fee_data


def calibrate_fee(owner):
    fee_before = get_collaterals_fee()
    print_dict('Collateral_fee_before: ', fee_before)
    tx = fee_calculator.calibrateFeeForAll({'from': owner})
    fee_after = get_collaterals_fee()
    print_dict('Collateral_fee_after: ', fee_after)
    print_dict('tx_info', get_tx_info('Fee_calibration', tx))


def yr_mint(owner):
    for collateral in collaterals:
        if (
            collateral.balanceOf(yield_reserve) / 10 ** (collateral.decimals())
            > MINT_THRESHOLD
        ):
            print(f'Minting Collateral {collateral.name()}')
            yield_reserve.mintUSDs(collateral, {'from': owner})


def get_strategies():
    strategies = []
    for strategy_caps in collateral_allocation_data.values():
        for strategy in strategy_caps.keys():
            if strategy not in strategies:
                strategies.append(strategy)
    return strategies


def get_pending_yield(
    strategy, min_interest=MIN_INTEREST_TO_COLLECT, min_reward=MIN_REWARD_TO_COLLECT
):
    # Returns (interest, rewards) in token units, only non-zero entries at/above the floors
    # interest: {collateral: amount}, rewards: {reward_token: amount}
    interest = {}
    for collateral in collaterals:
        if not strategy.supportsCollateral(collateral):
            continue
        amt = strategy.checkInterestEarned(collateral) / 10 ** collateral.decimals()
        if amt > 0 and amt >= min_interest:
            interest[collateral] = amt
    raw_rewards = {}
    for token, amt in strategy.checkRewardEarned():
        raw_rewards[token] = raw_rewards.get(token, 0) + amt
    rewards = {}
    for token, amt in raw_rewards.items():
        if amt == 0:
            continue
        reward_token = ERC20.at(token)
        amt = amt / 10 ** reward_token.decimals()
        if amt >= min_reward:
            rewards[reward_token] = amt
    return interest, rewards


def collect_yield(
    owner, min_interest=MIN_INTEREST_TO_COLLECT, min_reward=MIN_REWARD_TO_COLLECT
):
    # Collects interest and rewards at/above the floors from all strategies in collateral_allocation_data
    summary = {}
    for strategy in get_strategies():
        print(f'\nCollecting yield from {strategy._name} ({strategy.address})')
        interest, rewards = get_pending_yield(strategy, min_interest, min_reward)
        if not interest and not rewards:
            print(
                f'  Nothing above floor (interest >= {min_interest}, reward >= {min_reward})'
            )
            continue
        for collateral, amt in interest.items():
            print(f'  Collecting interest {amt} {collateral.symbol()}')
            tx = strategy.collectInterest(collateral, {'from': owner})
            summary[f'{strategy._name}_{collateral.symbol()}_interest'] = amt
            print_dict('tx_info', get_tx_info(f'{strategy._name}.collectInterest', tx))
        if rewards:
            for reward_token, amt in rewards.items():
                print(f'  Collecting reward {amt} {reward_token.symbol()}')
                summary[f'{strategy._name}_{reward_token.symbol()}_reward'] = amt
            tx = strategy.collectReward({'from': owner})
            print_dict('tx_info', get_tx_info(f'{strategy._name}.collectReward', tx))
    print_dict('Collected_yield', summary)
    return summary


def main():
    owner = get_user('Select deployer ')
