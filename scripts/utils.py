from brownie import network, accounts, Contract, web3
import click
import sys
import time
import json
import os

GAS_LIMIT = 6200000


class Step:
    def __init__(self, func, args, transact, contract=None, contract_addr=""):
        self.func = func
        self.args = args
        self.transact = transact
        self.contract = contract
        self.contract_addr = contract_addr


class Deployment_config:
    def __init__(
        self,
        deployment_params={},
        post_deployment_steps=[],
        upgradeable=False,
        proxy_admin=None,
    ):
        self.deployment_params = deployment_params
        self.post_deployment_steps = post_deployment_steps
        self.upgradeable = upgradeable
        self.proxy_admin = proxy_admin


class Upgrade_config:
    def __init__(
        self, proxy_address, proxy_admin, gnosis_upgrade=True, post_upgrade_steps=[]
    ):
        self.proxy_address = proxy_address
        self.gnosis_upgrade = gnosis_upgrade
        self.proxy_admin = proxy_admin
        self.post_upgrade_steps = post_upgrade_steps


class Upgrade_data:
    def __init__(self, contract, config: Upgrade_config, description=""):
        self.description = description
        self.contract = contract
        self.config = config


class Deployment_data:
    def __init__(self, contract, config: Deployment_config):
        self.contract = contract
        self.config = config


def signal_handler(signal, frame):
    sys.exit(0)


def _getYorN(msg):
    while True:
        answer = input(msg + " [y/n] ")
        lowercase_answer = answer.lower()
        if lowercase_answer == "y" or lowercase_answer == "n":
            return lowercase_answer
        else:
            print("Please enter y or n.")


def get_account(msg: str):
    owner = accounts.load(click.prompt(msg, type=click.Choice(accounts.load())))
    print(f"{msg}: {owner.address}\n")
    return owner


def confirm(msg):
    """
    Prompts the user to confirm an action.
    If they hit yes, nothing happens, meaning the script continues.
    If they hit no, the script exits.
    """
    answer = _getYorN(msg)
    if answer == "y":
        return
    elif answer == "n":
        print("Exiting...")
        exit()


def get_config(msg: str, configurations):
    configs = list(configurations.keys())
    menu = "\nPlease select config: \n"
    for i, k in enumerate(configs):
        menu += str(i) + ". " + k + "\n"
    menu += "-> "
    config_id = int(input(menu))
    config_name = configs[config_id]
    print()
    print("-" * 60, f"\nConfig selected: {config_name}")
    print("-" * 60)

    return (config_name, configurations[config_name])


def print_dict(msg, data, col=40):
    print("-" * 70, f"\n{msg}:")
    print("-" * 70)
    s = "{:<" + str(col) + "} -> {:<" + str(col // 2) + "}"
    for k in data.keys():
        print(s.format(k, str(data[k])))
    print("-" * 70, "\n")


def save_deployment_artifacts(data, name, operation_type=""):
    # Function to store deployment artifacts
    path = os.path.join("deployed", network.show_active())
    os.makedirs(path, exist_ok=True)
    file = os.path.join(
        path,
        operation_type
        + "_"
        + name
        + "_"
        + time.strftime("%m-%d-%Y_%H-%M-%S")
        + ".json",
    )
    with open(file, "w") as json_file:
        json.dump(data, json_file, default=lambda o: o.__dict__, indent=4)
    print(f"Artifacts stored at: {file}")


def resolve_args(args, contract_obj, caller):
    """Resolves derived arguments

    Args:
        args ([]): array str | int | Step
        contract_obj (contract): Current context contract
        caller (address): address of caller

    Returns:
        []str|int|bool: resolved argument array
    """
    res = []
    for arg in args.values():
        if type(arg) is Step:
            arg, val, _ = run_step(arg, contract_obj, caller)
            res.append(val)
        else:
            res.append(arg)
    return args, res


def call_func(contract_obj, func_name, args, transact, caller=None):
    """Interact with a contract

    Args:
        contract_obj (contract): Contract object for interaction
        func_name (str): name of the function
        args ({}): arguments for the function call
        transact (bool): Do a transaction or call
        caller (address): Address of user performing transaction

    Returns:
        val: Returns value for view functions
    """
    func_sig = contract_obj.signatures[func_name]
    func = contract_obj.get_method_object(func_sig)
    args, res = resolve_args(args, contract_obj, caller)
    val = None
    if transact:
        tx = func.transact(*res, {"from": caller})
    else:
        tx = None
        val = func.call(
            *res,
        )
    return args, val, tx


def run_step(step, contract_obj, deployer):
    """Run the post deployment steps

    Args:
        steps (Step): Information of a step
        contract_obj (contract): contract_obj
        deployer (address): Address of user performing transaction

    Returns:
        Steps: Returns steps with updated contract information.
    """
    if type(step) is Step:
        if step.transact:
            print(f"\nRunning step: {step.func}()")
        else:
            print(f"\nFetching: {step.func}()")
        contract_obj = contract_obj
        if step.contract is not None:
            contract_obj = Contract.from_abi(
                "", step.contract_address, step.contract.abi
            )
        else:
            step.contract = contract_obj._name
            step.contract_addr = contract_obj.address
        step.args, val, tx = call_func(
            contract_obj, step.func, step.args, step.transact, deployer
        )
    else:
        print("Invalid argument type skipping")
    return step, val, tx


def get_user(msg):
    """Get the address of the users

    Returns:
        address: Returns address of the deployer
    """
    # simulate transacting with vault core from deployer address on fork
    # contract deployer account
    deployer = accounts.load(click.prompt(msg, type=click.Choice(accounts.load())))
    print(f"{msg}{deployer.address}\n")
    return deployer


def get_tx_info(name, tx):
    data = {}
    data["step"] = name
    data["tx_hash"] = tx.txid
    data["contract"] = tx.contract_name
    data["contract_addr"] = tx.contract_address or tx.receiver
    data["tx_func"] = tx.fn_name
    data["blocknumber"] = tx.block_number
    data["gas_used"] = tx.gas_used
    data["gas_limit"] = tx.gas_limit
    return data


# ---------------------------------------------------------------------------
# Deployment data
# ---------------------------------------------------------------------------
def load_deployment_data():
    for net in (network.show_active(), 'arbitrum-one'):
        path = f'deployed/{net}/deployment_data.json'
        if os.path.exists(path):
            with open(path) as f:
                return json.load(f)
    raise FileNotFoundError('no deployment_data.json found')


# ---------------------------------------------------------------------------
# Safe Transaction Builder batches
# - Action(target, fn, args, desc): one contract call, serialized with named inputs (no raw calldata).
# - write_batch(...): checksum matches safe-react-apps/apps/tx-builder/src/lib/checksum.ts,
#   so the Safe UI imports the file without complaint.
# ---------------------------------------------------------------------------
TX_BUILDER_VERSION = '1.17.0'


class Action:
    def __init__(self, target, fn, args, desc):
        self.target = target
        self.fn = fn
        self.args = args
        self.desc = desc

    def __str__(self):
        return f'{self.target._name}.{self.fn}  --  {self.desc}'


def _abi_inputs(contract, fn, nargs):
    for e in contract.abi:
        if e.get('type') == 'function' and e['name'] == fn and len(e['inputs']) == nargs:
            return e['inputs']
    raise KeyError(f'{contract._name}.{fn} with {nargs} inputs not in ABI')


def _builder_value(v):
    if hasattr(v, 'address'):
        return v.address
    if isinstance(v, str) and v.startswith('0x') and len(v) == 42:
        return web3.to_checksum_address(v)
    if isinstance(v, (bytes, bytearray)):
        return web3.to_hex(v)
    return str(v)


def builder_tx(action):
    inputs = _abi_inputs(action.target, action.fn, len(action.args))
    return {
        'to': action.target.address,
        'value': '0',
        'data': None,
        'contractMethod': {
            'inputs': [{'internalType': i['internalType'], 'name': i['name'], 'type': i['type']} for i in inputs],
            'name': action.fn,
            'payable': False,
        },
        'contractInputsValues': {i['name']: _builder_value(arg) for i, arg in zip(inputs, action.args)},
    }


def _js_json(v):
    return json.dumps(v, separators=(',', ':'), ensure_ascii=False)


def _serialize(obj):
    # Mirrors serializeJSONObject in checksum.ts
    if isinstance(obj, list):
        return '[' + ','.join(_serialize(e) for e in obj) + ']'
    if isinstance(obj, dict):
        keys = sorted(obj.keys())
        acc = '{' + _js_json(keys)
        for k in keys:
            acc += _serialize(obj[k]) + ','
        return acc + '}'
    return _js_json(obj)


def checksum(batch):
    b = dict(batch)
    b['meta'] = {k: v for k, v in batch['meta'].items() if k != 'checksum'}
    b['meta']['name'] = None
    return web3.to_hex(web3.keccak(text=_serialize(b)))


def write_batch(name, actions, path, safe, chain_id, header=''):
    desc = ([header] if header else []) + [f'{i}. {a.desc}' for i, a in enumerate(actions, 1)]
    batch = {
        'version': '1.0',
        'chainId': str(chain_id),
        'createdAt': int(time.time() * 1000),
        'meta': {
            'name': name,
            'description': '\n'.join(desc),
            'txBuilderVersion': TX_BUILDER_VERSION,
            'createdFromSafeAddress': safe,
            'createdFromOwnerAddress': '',
        },
        'transactions': [builder_tx(a) for a in actions],
    }
    batch['meta']['checksum'] = checksum(batch)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'w') as f:
        json.dump(batch, f, indent=2)
    return batch
