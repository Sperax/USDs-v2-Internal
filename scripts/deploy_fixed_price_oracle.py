"""
Deploy a FixedPriceOracle (default: LUSD at $1) and build the Safe batch that points MasterPriceOracle at it.

Entry points (`brownie run scripts/deploy_fixed_price_oracle.py <fn> --network <net>`):
- simulate          : anvil fork. Deploys from a funded fork account, impersonates the Safe to run
                      MasterPriceOracle.updateTokenPriceFeed, checks getPrice and the vault redeem view.
- deploy            : live. Deploys from a brownie account, saves the artifact, writes the Safe batch JSON.
- build_safe_batch  : live. Writes the Safe batch for an already deployed oracle (ORACLE_ADDR env var, or the
                      deployment_data.json key below).

Safe batch = one call: MasterPriceOracle.updateTokenPriceFeed(token, oracle, getTokenPrice(token) calldata).
Nothing else changes; ChainlinkOracle keeps its LUSD entry but nobody reads it anymore.
"""

import os
import time

from brownie import Contract, FixedPriceOracle, MasterPriceOracle, VaultCore, accounts, chain, network, web3

from .configurations import LUSD, USDS_OWNER_ADDR
from .utils import Action, get_tx_info, get_user, load_deployment_data, print_dict, save_deployment_artifacts, write_batch

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SAFE = USDS_OWNER_ADDR
CHAIN_ID = '42161'
TOKEN = web3.to_checksum_address(LUSD)
PRICE_PRECISION = 10**8  # same scale as the Chainlink USD feeds the protocol uses today
PRICE = 1 * PRICE_PRECISION  # $1.00
DEPLOYMENT_KEY = 'lusd_fixed_price_oracle'  # key in deployed/<network>/deployment_data.json
PUBLISH_SRC = False

D = load_deployment_data()
mpo = MasterPriceOracle.at(D['master_price_oracle'])
vault = Contract.from_abi('Vault', D['vault'], VaultCore.abi)  # proxy, so from_abi


def line(title=''):
    print('-' * 100)
    if title:
        print(title)
        print('-' * 100)


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
def current_feed():
    source, data = mpo.tokenPriceFeed(TOKEN)
    price = None
    try:
        price = tuple(mpo.getPrice(TOKEN))
    except Exception as e:  # feed may already be dead
        price = f'getPrice reverted: {str(e)[:80]}'
    return {'source': source, 'msgData': web3.to_hex(data), 'price': price}


def print_state(label):
    line(f'{label}: MasterPriceOracle feed for {TOKEN}')
    print_dict('feed', current_feed())


# ---------------------------------------------------------------------------
# Deploy and verify
# ---------------------------------------------------------------------------
def deploy_oracle(deployer):
    oracle = FixedPriceOracle.deploy(TOKEN, PRICE, PRICE_PRECISION, {'from': deployer}, publish_source=PUBLISH_SRC)
    assert oracle.TOKEN() == TOKEN
    assert tuple(oracle.getTokenPrice(TOKEN)) == (PRICE, PRICE_PRECISION)
    print(f'\nFixedPriceOracle deployed at {oracle.address}: {TOKEN} = {PRICE / PRICE_PRECISION} (precision {PRICE_PRECISION})\n')
    return oracle


def load_oracle():
    addr = os.environ.get('ORACLE_ADDR') or D.get(DEPLOYMENT_KEY)
    if not addr:
        raise SystemExit(f'Set ORACLE_ADDR or add "{DEPLOYMENT_KEY}" to deployed/{network.show_active()}/deployment_data.json')
    oracle = FixedPriceOracle.at(addr)
    if oracle.TOKEN() != TOKEN or tuple(oracle.getTokenPrice(TOKEN)) != (PRICE, PRICE_PRECISION):
        raise SystemExit(f'Oracle at {addr} does not price {TOKEN} at {PRICE}/{PRICE_PRECISION}')
    return oracle


def plan(oracle):
    data = oracle.getTokenPrice.encode_input(TOKEN)
    return [Action(mpo, 'updateTokenPriceFeed', [TOKEN, oracle.address, data],
                   f'point MasterPriceOracle LUSD feed at FixedPriceOracle {oracle.address} ($1.00, precision 1e8)')]


def preflight(oracle):
    """Checks that hold on live and on a fork. The eth_call from the Safe proves the owner call would succeed."""
    owner = mpo.owner()
    if owner != SAFE:
        raise SystemExit(f'MasterPriceOracle owner is {owner}, expected the Safe {SAFE}')
    acts = plan(oracle)
    a = acts[0]
    mpo.updateTokenPriceFeed.call(*a.args, {'from': SAFE})  # reverts here if the Safe tx would revert
    print(f'preflight ok: owner is the Safe, updateTokenPriceFeed eth_call from the Safe succeeds\n')
    return acts


def verify(oracle):
    checks = []
    source, data = mpo.tokenPriceFeed(TOKEN)
    checks.append(('MPO source == FixedPriceOracle', source == oracle.address))
    checks.append(('MPO msgData == getTokenPrice(LUSD)', web3.to_hex(data) == oracle.getTokenPrice.encode_input(TOKEN)))
    price = tuple(mpo.getPrice(TOKEN))
    checks.append((f'MPO getPrice == ({PRICE}, {PRICE_PRECISION}), got {price}', price == (PRICE, PRICE_PRECISION)))
    try:
        rv = vault.redeemView['address,uint256'](TOKEN, 10**18)
        checks.append((f'Vault.redeemView(LUSD, 1e18) works: {rv[0] / 10**18:.6f} LUSD', rv[0] > 0))
    except Exception as e:
        checks.append((f'Vault.redeemView(LUSD, 1e18) reverted: {str(e)[:80]}', False))
    line('Checks')
    ok = True
    for name, passed in checks:
        ok &= passed
        print(f"{'PASS' if passed else 'FAIL':<6}{name}")
    print()
    return ok


def _batch_path():
    return os.path.join('deployed', network.show_active(),
                        f"Safe_batch_lusd_fixed_price_oracle_{time.strftime('%m-%d-%Y_%H-%M-%S')}.json")


def _write(acts):
    path = _batch_path()
    write_batch('USDs: LUSD fixed price oracle', acts, path, SAFE, CHAIN_ID, f'Built at block {chain.height}.')
    print(f'Safe Transaction Builder batch written to: {path}')
    print('Import it in the Safe UI (Apps -> Transaction Builder -> Load), simulate with Tenderly, then queue.')


# ---------------------------------------------------------------------------
# Entry points
# ---------------------------------------------------------------------------
def _fork_account(addr, eth=10):
    addr = web3.to_checksum_address(addr)
    web3.provider.make_request('anvil_impersonateAccount', [addr])
    web3.provider.make_request('anvil_setBalance', [addr, hex(eth * 10**18)])
    return accounts.at(addr, force=True)


def simulate():
    if 'anvil' not in web3.client_version.lower():
        raise SystemExit(f'simulate needs an anvil fork, node is "{web3.client_version}"')
    print(f'\nNetwork: {network.show_active()}  block: {chain.height}\n')
    print_state('Before')
    deployer = _fork_account('0x3333333333333333333333333333333333333333')
    oracle = deploy_oracle(deployer)
    acts = preflight(oracle)
    safe = _fork_account(SAFE)
    for a in acts:
        print(f'[Safe] {a}')
        tx = getattr(a.target, a.fn)(*a.args, {'from': safe})
        print(f'    ok  gas={tx.gas_used}\n')
    print_state('After')
    ok = verify(oracle)
    _write(acts)
    # brownie persists deployments under chain id 42161, shared with real mainnet; drop the fork-only record
    FixedPriceOracle.remove(oracle)
    print('SIMULATION PASSED' if ok else 'SIMULATION FAILED')


def deploy():
    deployer = get_user('Select deployer ')
    print_state('Before')
    oracle = deploy_oracle(deployer)
    save_deployment_artifacts(
        {'oracle': oracle.address, 'token': TOKEN, 'price': PRICE, 'price_precision': PRICE_PRECISION,
         'transactions': [get_tx_info('Deployment_transaction', oracle.tx)]},
        'fixedPriceOracle_LUSD', 'Deployment',
    )
    print(f'Add to deployed/{network.show_active()}/deployment_data.json:  "{DEPLOYMENT_KEY}": "{oracle.address}"\n')
    acts = preflight(oracle)
    _write(acts)


def build_safe_batch():
    print_state('Current')
    oracle = load_oracle()
    acts = preflight(oracle)
    _write(acts)


def main():
    print_state('Current')
