ethereum_package = import_module("github.com/kien-rise/ethereum-package/main.star")
contract_deployer = import_module("./src/contracts/contract_deployer.star")
l2_launcher = import_module("./src/l2.star")
op_supervisor_launcher = import_module("./src/interop/op-supervisor/launcher.star")
op_challenger_launcher = import_module("./src/challenger/op-challenger/launcher.star")

faucet = import_module("./src/faucet/op-faucet/op_faucet_launcher.star")
observability = import_module("./src/observability/observability.star")
util = import_module("./src/util.star")

wait_for_sync = import_module("./src/wait/wait_for_sync.star")
input_parser = import_module("./src/package_io/input_parser.star")
ethereum_package_static_files = import_module(
    "github.com/kien-rise/ethereum-package/src/static_files/static_files.star"
)


def run(plan, args={}):
    """Deploy Optimism L2s on an Ethereum L1.

    Args:
        args(json): Configures other aspects of the environment.
    Returns:
        A full deployment of Optimism L2(s)
    """
    plan.print("[OP-DEPLOY] Starting Optimism deployment process")
    plan.print("[OP-DEPLOY] run() called with args keys: {0}".format(list(args.keys()) if args else "empty"))
    plan.print("[OP-DEPLOY] Parsing the L1 input args")
    # If no args are provided, use the default values with minimal preset
    ethereum_args = args.get("ethereum_package", {})
    external_l1_args = args.get("external_l1_network_params", {})
    if external_l1_args:
        external_l1_args = input_parser.external_l1_network_params_input_parser(
            plan, external_l1_args
        )
    else:
        if "network_params" not in ethereum_args:
            ethereum_args.update(input_parser.default_ethereum_package_network_params())

    optimism_args = input_parser.input_parser(plan, args.get("optimism_package", {}))
    global_tolerations = optimism_args.global_tolerations
    global_node_selectors = optimism_args.global_node_selectors
    global_log_level = optimism_args.global_log_level
    persistent = optimism_args.persistent
    altda_deploy_config = optimism_args.altda_deploy_config

    observability_params = optimism_args.observability
    interop_params = optimism_args.interop

    observability_helper = observability.make_helper(observability_params)

    # Deploy the L1
    l1_network = ""
    if external_l1_args:
        plan.print("Using external L1")
        plan.print(external_l1_args)

        l1_rpc_url = external_l1_args.el_rpc_url
        l1_priv_key = external_l1_args.priv_key

        l1_config_env_vars = {
            "L1_RPC_KIND": external_l1_args.rpc_kind,
            "L1_RPC_URL": l1_rpc_url,
            "CL_RPC_URL": external_l1_args.cl_rpc_url,
            "L1_WS_URL": external_l1_args.el_ws_url,
            "L1_CHAIN_ID": external_l1_args.network_id,
        }

        plan.print("Waiting for network to sync")
        wait_for_sync.wait_for_sync(plan, l1_config_env_vars)
    else:
        plan.print("Deploying a local L1")
        l1 = ethereum_package.run(plan, ethereum_args)
        plan.print(l1.network_params)
        # Get L1 info
        all_l1_participants = l1.all_participants
        l1_network = "local"
        l1_network_params = l1.network_params
        l1_network_id = l1.network_id
        l1_rpc_url = all_l1_participants[0].el_context.rpc_http_url
        l1_priv_key = l1.pre_funded_accounts[
            12
        ].private_key  # reserved for L2 contract deployers
        l1_config_env_vars = get_l1_config(
            plan, all_l1_participants, l1_network_params, l1_network_id
        )
        plan.print("Waiting for L1 to start up")
        wait_for_sync.wait_for_startup(plan, l1_config_env_vars)

    plan.print("[OP-DEPLOY] Starting contract deployment")
    plan.print("[OP-DEPLOY] Calling deploy_contracts with: l1_network={0}, altda_deploy_config={1}".format(l1_network, altda_deploy_config))
    plan.print("[OP-DEPLOY] Number of chains to deploy: {0}".format(len(optimism_args.chains)))
    deployment_output = contract_deployer.deploy_contracts(
        plan,
        l1_priv_key,
        l1_config_env_vars,
        optimism_args,
        l1_network,
        altda_deploy_config,
    )
    plan.print("[OP-DEPLOY] Contract deployment completed")

    jwt_file = plan.upload_files(
        src=ethereum_package_static_files.JWT_PATH_FILEPATH,
        name="op_jwt_file",
    )

    l2s = []
    plan.print("[OP-DEPLOY] Starting L2 chain deployments")
    plan.print("[OP-DEPLOY] Number of L2 chains to deploy: {0}".format(len(optimism_args.chains)))
    for l2_num, chain in enumerate(optimism_args.chains):
        plan.print("[OP-DEPLOY] Launching L2 chain {0}/{1} - {2}".format(l2_num + 1, len(optimism_args.chains), chain.network_params.name))
        plan.print("[OP-DEPLOY] l2_launcher.launch_l2 called with: l2_num={0}, chain_name={1}, global_log_level={2}".format(l2_num, chain.network_params.name, global_log_level))
        l2s.append(
            l2_launcher.launch_l2(
                plan,
                l2_num,
                chain.network_params.name,
                chain,
                jwt_file,
                deployment_output,
                l1_config_env_vars,
                l1_priv_key,
                l1_rpc_url,
                global_log_level,
                global_node_selectors,
                global_tolerations,
                persistent,
                observability_helper,
                interop_params,
            )
        )
        plan.print("[OP-DEPLOY] L2 chain {0} deployment completed".format(chain.network_params.name))

    supervisor = None
    if interop_params.enabled:
        plan.print("[OP-DEPLOY] Launching OP Supervisor for interop")
        plan.print("[OP-DEPLOY] op_supervisor_launcher.launch called with: chains_count={0}, l2s_count={1}".format(len(optimism_args.chains), len(l2s)))
        supervisor = op_supervisor_launcher.launch(
            plan,
            l1_config_env_vars,
            optimism_args.chains,
            l2s,
            jwt_file,
            interop_params.supervisor_params,
            observability_helper,
        )
        plan.print("[OP-DEPLOY] OP Supervisor launched successfully")
    else:
        plan.print("[OP-DEPLOY] Interop disabled, skipping OP Supervisor")

    plan.print("[OP-DEPLOY] Launching {0} challenger(s)".format(len(optimism_args.challengers)))
    for i, challenger_params in enumerate(optimism_args.challengers):
        plan.print("[OP-DEPLOY] Launching challenger {0}/{1}".format(i + 1, len(optimism_args.challengers)))
        plan.print("[OP-DEPLOY] op_challenger_launcher.launch called with: challenger_params={0}".format(challenger_params))
        op_challenger_launcher.launch(
            plan=plan,
            params=challenger_params,
            l2s=l2s,
            supervisor=supervisor,
            l1_config_env_vars=l1_config_env_vars,
            deployment_output=deployment_output,
            observability_helper=observability_helper,
        )
        plan.print("[OP-DEPLOY] Challenger {0} launched successfully".format(i + 1))

    if optimism_args.faucet.enabled:
        plan.print("[OP-DEPLOY] Installing faucet")
        plan.print("[OP-DEPLOY] _install_faucet called with: faucet_enabled={0}, l2s_count={1}".format(optimism_args.faucet.enabled, len(l2s)))
        _install_faucet(
            plan=plan,
            faucet_params=optimism_args.faucet,
            l1_config_env_vars=l1_config_env_vars,
            l1_priv_key=l1_priv_key,
            deployment_output=deployment_output,
            l2s=l2s,
        )
        plan.print("[OP-DEPLOY] Faucet installation completed")
    else:
        plan.print("[OP-DEPLOY] Faucet disabled, skipping installation")

    plan.print("[OP-DEPLOY] Launching observability stack")
    plan.print("[OP-DEPLOY] observability.launch called with: observability_params={0}".format(observability_params))
    observability.launch(
        plan, observability_helper, global_node_selectors, observability_params
    )
    plan.print("[OP-DEPLOY] Optimism deployment process completed successfully")


def get_l1_config(plan, all_l1_participants, l1_network_params, l1_network_id):
    plan.print("[OP-DEPLOY] Building L1 configuration")
    plan.print("[OP-DEPLOY] get_l1_config called with: l1_network_id={0}, participants_count={1}".format(l1_network_id, len(all_l1_participants)))
    env_vars = {}
    env_vars["L1_RPC_KIND"] = "standard"
    env_vars["WEB3_RPC_URL"] = str(all_l1_participants[0].el_context.rpc_http_url)
    env_vars["L1_RPC_URL"] = str(all_l1_participants[0].el_context.rpc_http_url)
    env_vars["CL_RPC_URL"] = str(all_l1_participants[0].cl_context.beacon_http_url)
    env_vars["L1_WS_URL"] = str(all_l1_participants[0].el_context.ws_url)
    env_vars["L1_CHAIN_ID"] = str(l1_network_id)
    env_vars["L1_BLOCK_TIME"] = str(l1_network_params.seconds_per_slot)
    return env_vars


def _install_faucet(
    plan,
    faucet_params,
    l1_config_env_vars,
    l1_priv_key,
    deployment_output,
    l2s,
):
    plan.print("[OP-DEPLOY] Setting up faucet configuration")
    plan.print("[OP-DEPLOY] _install_faucet called with: l2s_count={0}, faucet_params={1}".format(len(l2s), faucet_params))
    faucets = [
        faucet.faucet_data(
            name="l1",
            chain_id=l1_config_env_vars["L1_CHAIN_ID"],
            el_rpc=l1_config_env_vars["L1_RPC_URL"],
            private_key=l1_priv_key,
        ),
    ]
    for l2 in l2s:
        chain_id = l2.network_id

        private_key = util.read_network_config_value(
            plan,
            deployment_output,
            "wallets",
            '."{0}" | .["l2FaucetPrivateKey"]'.format(chain_id),
        )
        faucets.append(
            faucet.faucet_data(
                name=l2.name,
                chain_id=chain_id,
                el_rpc=l2.participants[0].el_context.rpc_http_url,
                private_key=private_key,
            )
        )

    faucet_image = (
        faucet_params.image
        if faucet_params.image != ""
        else input_parser.DEFAULT_FAUCET_IMAGES["op-faucet"]
    )
    faucet.launch(
        plan,
        "op-faucet",
        faucet_image,
        faucets,
    )
