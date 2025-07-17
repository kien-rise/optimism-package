ENVRC_PATH = "/workspace/optimism/.envrc"
FACTORY_DEPLOYER_ADDRESS = "0x3fAB184622Dc19b6109349B94811493BF2a45362"
FACTORY_ADDRESS = "0x4e59b44847b379578588920cA78FbF26c0B4956C"
# raw tx data for deploying Create2Factory contract to L1
FACTORY_DEPLOYER_CODE = "0xf8a58085174876e800830186a08080b853604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf31ba02222222222222222222222222222222222222222222222222222222222222222a02222222222222222222222222222222222222222222222222222222222222222"

FUND_SCRIPT_FILEPATH = "../../static_files/scripts"

utils = import_module("../util.star")

ethereum_package_genesis_constants = import_module(
    "github.com/kien-rise/ethereum-package/src/prelaunch_data_generator/genesis_constants/genesis_constants.star"
)

CANNED_VALUES = {
    "eip1559Denominator": 50,
    "eip1559DenominatorCanyon": 250,
    "eip1559Elasticity": 6,
}


def _normalize_artifacts_locator(plan, locator):
    """Transform artifact locator from 'artifact://NAME' format to (name, file_path) pair.

    If the locator doesn't use the artifact:// format, returns (None, original_locator).

    Args:
        plan: The plan object
        locator: The original artifact locator string

    Returns:
        tuple: (artifact_name, normalized_locator, mount_point)
    """
    plan.print("[OP-DEPLOY] _normalize_artifacts_locator called with: {0}".format(locator))
    if locator and locator.startswith("artifact://"):
        artifact_name = locator[len("artifact://") :]
        mount_point = "/{0}".format(artifact_name)
        return (artifact_name, "file://{0}".format(mount_point), mount_point)
    return (None, locator, None)


def _normalize_artifacts_locators(plan, l1_locator, l2_locator):
    """Normalize artifact locators with specific mount points.

    Args:
        plan: The plan object
        l1_locator: The L1 artifact locator
        l2_locator: The L2 artifact locator

    Returns:
        tuple: (l1_artifacts_locator, l2_artifacts_locator, extra_files)
    """
    plan.print("[OP-DEPLOY] _normalize_artifacts_locators called with: l1_locator={0}, l2_locator={1}".format(l1_locator, l2_locator))
    (
        l1_artifact_name,
        l1_artifacts_locator,
        l1_mount_point,
    ) = _normalize_artifacts_locator(plan, l1_locator)
    (
        l2_artifact_name,
        l2_artifacts_locator,
        l2_mount_point,
    ) = _normalize_artifacts_locator(plan, l2_locator)

    extra_files = {}
    if l1_mount_point:
        extra_files[l1_mount_point] = plan.get_files_artifact(name=l1_artifact_name)
    if (
        l2_mount_point and l2_mount_point not in extra_files
    ):  # shortcut if both are the same
        extra_files[l2_mount_point] = plan.get_files_artifact(name=l2_artifact_name)

    return l1_artifacts_locator, l2_artifacts_locator, extra_files


def deploy_contracts(
    plan, priv_key, l1_config_env_vars, optimism_args, l1_network, altda_args
):
    plan.print("[OP-DEPLOY] Starting contract deployment process")
    # Print all arguments except plan - detailed output
    plan.print("[OP-DEPLOY] Arguments: l1_network={0}, altda_args={1}".format(l1_network, altda_args))
    plan.print("[OP-DEPLOY] L1 config env vars: {0}".format(l1_config_env_vars))
    plan.print("[OP-DEPLOY] Private key: {0}".format(priv_key))
    plan.print("[OP-DEPLOY] Optimism args: {0}".format(optimism_args))
    l2_chain_ids_list = [
        str(chain.network_params.network_id) for chain in optimism_args.chains
    ]
    l2_chain_ids = ",".join(l2_chain_ids_list)
    plan.print("[OP-DEPLOY] L2 chain IDs: {0}".format(l2_chain_ids))

    plan.print("[OP-DEPLOY] Initializing OP deployer")
    # Print the op-deployer init command
    init_command = "op-deployer init --intent-config-type custom --l1-chain-id $L1_CHAIN_ID --l2-chain-ids {0} --workdir /network-data".format(l2_chain_ids)
    plan.print("[OP-DEPLOY] Running command: {0}".format(init_command))
    op_deployer_init = plan.run_sh(
        name="op-deployer-init",
        description="Initialize L2 contract deployments",
        image=optimism_args.op_contract_deployer_params.image,
        env_vars=l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        run=" && ".join(
            [
                "mkdir -p /network-data",
                "op-deployer init --intent-config-type custom --l1-chain-id $L1_CHAIN_ID --l2-chain-ids {0} --workdir /network-data".format(
                    l2_chain_ids
                ),
            ]
        ),
    )
    plan.print("[OP-DEPLOY] OP deployer initialization completed")

    # Normalize artifact locators with specific mount points
    plan.print("[OP-DEPLOY] Normalizing artifact locators")
    (
        l1_artifacts_locator,
        l2_artifacts_locator,
        contracts_extra_files,
    ) = _normalize_artifacts_locators(
        plan,
        optimism_args.op_contract_deployer_params.l1_artifacts_locator,
        optimism_args.op_contract_deployer_params.l2_artifacts_locator,
    )
    plan.print("[OP-DEPLOY] L1 artifacts locator: {0}".format(l1_artifacts_locator))
    plan.print("[OP-DEPLOY] L2 artifacts locator: {0}".format(l2_artifacts_locator))

    # Print fund script upload details
    plan.print("[OP-DEPLOY] Uploading fund script")
    plan.print("[OP-DEPLOY] Fund script source path: {0}".format(FUND_SCRIPT_FILEPATH))
    fund_script_artifact = plan.upload_files(
        src=FUND_SCRIPT_FILEPATH,
        name="op-deployer-fund-script",
    )
    plan.print("[OP-DEPLOY] Fund script artifact uploaded successfully")

    plan.print("[OP-DEPLOY] Funding deployer addresses")
    plan.run_sh(
        name="op-deployer-fund",
        description="Collect keys, and fund addresses",
        image=utils.DEPLOYMENT_UTILS_IMAGE,
        env_vars={
            "DEPLOYER_PRIVATE_KEY": priv_key,
            "FUND_PRIVATE_KEY": ethereum_package_genesis_constants.PRE_FUNDED_ACCOUNTS[
                19
            ].private_key,
            "FUND_VALUE": "10ether",
            "L1_NETWORK": str(l1_network),
        }
        | l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_init.files_artifacts[0],
            "/fund-script": fund_script_artifact,
        },
        run='bash /fund-script/fund.sh "{0}"'.format(l2_chain_ids),
    )
    plan.print("[OP-DEPLOY] Deployer funding completed")

    plan.print("[OP-DEPLOY] Building hardfork schedule")
    hardfork_schedule = []
    for index, chain in enumerate(optimism_args.chains):
        np = chain.network_params
        plan.print("[OP-DEPLOY] Processing hardfork schedule for chain {0}".format(index))

        # rename each hardfork to the name the override expects
        renames = (
            ("l2GenesisFjordTimeOffset", np.fjord_time_offset),
            ("l2GenesisGraniteTimeOffset", np.granite_time_offset),
            ("l2GenesisHoloceneTimeOffset", np.holocene_time_offset),
            ("l2GenesisIsthmusTimeOffset", np.isthmus_time_offset),
            ("l2GenesisInteropTimeOffset", np.interop_time_offset),
        )

        # only include the hardforks that have been activated since
        # toml does not support null values
        for fork_key, activation_timestamp in renames:
            if activation_timestamp != None:
                plan.print("[OP-DEPLOY] Adding hardfork {0} at timestamp {1} for chain {2}".format(fork_key, activation_timestamp, index))
                hardfork_schedule.append((index, fork_key, activation_timestamp))

    plan.print("[OP-DEPLOY] Building deployment intent configuration")
    intent = {
        "useInterop": optimism_args.interop.enabled,
        "l1ContractsLocator": l1_artifacts_locator,
        "l2ContractsLocator": l2_artifacts_locator,
        "superchainRoles": {
            "superchainGuardian": read_chain_cmd("l1ProxyAdmin", l2_chain_ids_list[0]),
            "protocolVersionsOwner": read_chain_cmd(
                "l1ProxyAdmin", l2_chain_ids_list[0]
            ),
            "superchainProxyAdminOwner": read_chain_cmd(
                "l1ProxyAdmin", l2_chain_ids_list[0]
            ),
        },
        "chains": [],
    }
    plan.print("[OP-DEPLOY] Interop enabled: {0}".format(optimism_args.interop.enabled))

    absolute_prestate = ""
    if optimism_args.op_contract_deployer_params.global_deploy_overrides[
        "faultGameAbsolutePrestate"
    ]:
        absolute_prestate = (
            optimism_args.op_contract_deployer_params.global_deploy_overrides[
                "faultGameAbsolutePrestate"
            ]
        )
        plan.print("[OP-DEPLOY] Using custom fault game absolute prestate: {0}".format(absolute_prestate))
        intent["globalDeployOverrides"] = {
            "dangerouslyAllowCustomDisputeParameters": True,
            "faultGameAbsolutePrestate": absolute_prestate,
        }

    for i, chain in enumerate(optimism_args.chains):
        chain_id = str(chain.network_params.network_id)
        plan.print("[OP-DEPLOY] Configuring chain {0} (ID: {1})".format(i, chain_id))
        plan.print("[OP-DEPLOY] Chain {0} block time: {1}s, fund_dev_accounts: {2}".format(chain_id, chain.network_params.seconds_per_slot, chain.network_params.fund_dev_accounts))
        intent_chain = dict(CANNED_VALUES)
        intent_chain.update(
            {
                "deployOverrides": {
                    "l2BlockTime": chain.network_params.seconds_per_slot,
                    "fundDevAccounts": (
                        True if chain.network_params.fund_dev_accounts else False
                    ),
                },
                "baseFeeVaultRecipient": read_chain_cmd(
                    "baseFeeVaultRecipient", chain_id
                ),
                "l1FeeVaultRecipient": read_chain_cmd("l1FeeVaultRecipient", chain_id),
                "sequencerFeeVaultRecipient": read_chain_cmd(
                    "sequencerFeeVaultRecipient", chain_id
                ),
                "roles": {
                    "batcher": read_chain_cmd("batcher", chain_id),
                    "challenger": read_chain_cmd("challenger", chain_id),
                    "l1ProxyAdminOwner": read_chain_cmd("l1ProxyAdmin", chain_id),
                    "l2ProxyAdminOwner": read_chain_cmd("l2ProxyAdmin", chain_id),
                    "proposer": read_chain_cmd("proposer", chain_id),
                    "systemConfigOwner": read_chain_cmd("systemConfigOwner", chain_id),
                    "unsafeBlockSigner": read_chain_cmd("sequencer", chain_id),
                },
                "dangerousAdditionalDisputeGames": [
                    {
                        "respectedGameType": 0,
                        "faultGameAbsolutePrestate": absolute_prestate,
                        "faultGameMaxDepth": 73,
                        "faultGameSplitDepth": 30,
                        "faultGameClockExtension": 10800,
                        "faultGameMaxClockDuration": 302400,
                        "dangerouslyAllowCustomDisputeParameters": True,
                        "vmType": "CANNON",
                        "useCustomOracle": False,
                        "oracleMinProposalSize": 0,
                        "oracleChallengePeriodSeconds": 0,
                        "makeRespected": False,
                    }
                ],
                "dangerousAltDAConfig": {
                    "useAltDA": altda_args.use_altda,
                    "daCommitmentType": altda_args.da_commitment_type,
                    "daChallengeWindow": altda_args.da_challenge_window,
                    "daResolveWindow": altda_args.da_resolve_window,
                    "daBondSize": altda_args.da_bond_size,
                },
            }
        )
        for index, fork_key, activation_timestamp in hardfork_schedule:
            intent_chain["deployOverrides"][fork_key] = "0x%x" % activation_timestamp
        intent["chains"].append(intent_chain)

    plan.print("[OP-DEPLOY] Encoding intent configuration to JSON")
    # Print the intent configuration
    plan.print("[OP-DEPLOY] Intent configuration: {0}".format(intent))
    intent_json = json.encode(intent)
    plan.print("[OP-DEPLOY] Intent JSON (first 500 chars): {0}".format(intent_json[:500]))
    intent_json_artifact = utils.write_to_file(plan, intent_json, "/tmp", "intent.json")

    plan.print("[OP-DEPLOY] Configuring OP deployer with intent file")
    op_deployer_configure = plan.run_sh(
        name="op-deployer-configure",
        description="Configure L2 contract deployments",
        image=utils.DEPLOYMENT_UTILS_IMAGE,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_init.files_artifacts[0],
            "/tmp": intent_json_artifact,
        },
        run=" && ".join(
            [
                # zhwrd: this mess is temporary until we implement json reading for op-deployer intent file
                # convert intent_json to yaml. this is necessary because its unreliable to evaluate command substitutions in json.
                """cat /tmp/intent.json | dasel -r json -w yaml > /network-data/intent.yaml""",
                # evaluate the command substitutions
                "eval \"echo '$(cat /network-data/intent.yaml)'\" | dasel -r yaml -w json > /network-data/intent-b.json",
                # convert op-deployer generated intent.toml to json
                "dasel -r toml -w json -f /network-data/intent.toml > /network-data/intent-a.json",
                # merge the two intent.json files, ensuring that the chains array is merged correctly
                "jq -s 'add + {chains: map(.chains) | transpose | map(add)}' /network-data/intent-a.json /network-data/intent-b.json > /network-data/intent-merged.json",
                # convert the merged intent.json back to toml
                "cat /network-data/intent-merged.json | dasel -r json -w toml > /network-data/intent.toml",
            ]
        ),
    )
    plan.print("[OP-DEPLOY] OP deployer configuration completed")

    plan.print("[OP-DEPLOY] Preparing apply commands")
    apply_cmds = [
        "op-deployer apply --l1-rpc-url $L1_RPC_URL --private-key $PRIVATE_KEY --workdir /network-data",
    ]
    for chain in optimism_args.chains:
        network_id = chain.network_params.network_id
        plan.print("[OP-DEPLOY] Adding inspection commands for chain {0}".format(network_id))
        apply_cmds.extend(
            [
                "op-deployer inspect genesis --workdir /network-data --outfile /network-data/genesis-{0}.json {0}".format(
                    network_id
                ),
                "op-deployer inspect rollup --workdir /network-data --outfile /network-data/rollup-{0}.json {0}".format(
                    network_id
                ),
            ]
        )

    plan.print("[OP-DEPLOY] Applying contract deployments")
    # Print apply commands
    plan.print("[OP-DEPLOY] Apply commands to execute:")
    for i, cmd in enumerate(apply_cmds):
        plan.print("[OP-DEPLOY]   {0}: {1}".format(i+1, cmd))
    op_deployer_output = plan.run_sh(
        name="op-deployer-apply",
        description="Apply L2 contract deployments",
        image=optimism_args.op_contract_deployer_params.image,
        env_vars={
            "PRIVATE_KEY": str(priv_key),
            "DEPLOYER_CACHE_DIR": "/var/cache/op-deployer",
        }
        | l1_config_env_vars,
        store=[
            StoreSpec(
                src="/network-data",
                name="op-deployer-configs",
            )
        ],
        files={
            "/network-data": op_deployer_configure.files_artifacts[0],
        }
        | contracts_extra_files,
        run=" && ".join(apply_cmds),
    )
    plan.print("[OP-DEPLOY] Contract deployment application completed")

    plan.print("[OP-DEPLOY] Generating chainspecs for all chains")
    for chain in optimism_args.chains:
        chain_id = str(chain.network_params.network_id)
        plan.print("[OP-DEPLOY] Generating chainspec for chain {0}".format(chain_id))
        plan.run_sh(
            name="op-deployer-generate-chainspec",
            description="Generate chainspec",
            image=utils.DEPLOYMENT_UTILS_IMAGE,
            env_vars={"CHAIN_ID": chain_id},
            store=[
                StoreSpec(
                    src="/network-data",
                    name="op-deployer-configs",
                )
            ],
            files={
                "/network-data": op_deployer_output.files_artifacts[0],
                "/fund-script": fund_script_artifact,
            },
            run='jq --from-file /fund-script/gen2spec.jq < "/network-data/genesis-$CHAIN_ID.json" > "/network-data/chainspec-$CHAIN_ID.json"',
        )

    # Print genesis and chainspec file contents (sample)
    plan.print("[OP-DEPLOY] Chainspec generation completed for all chains")
    for chain in optimism_args.chains:
        chain_id = str(chain.network_params.network_id)
        plan.print("[OP-DEPLOY] Generated files for chain {0}:".format(chain_id))
        plan.print("[OP-DEPLOY]   - genesis-{0}.json".format(chain_id))
        plan.print("[OP-DEPLOY]   - rollup-{0}.json".format(chain_id))
        plan.print("[OP-DEPLOY]   - chainspec-{0}.json".format(chain_id))

    plan.print("[OP-DEPLOY] Contract deployment process completed successfully")
    # Print op_deployer_output information
    plan.print("[OP-DEPLOY] Op deployer output information: {0}".format(op_deployer_output))
    return op_deployer_output.files_artifacts[0]


def chain_key(index, key):
    # Note: chain_key is a utility function that doesn't have access to plan
    return "chains.[{0}].{1}".format(index, key)


def read_chain_cmd(filename, l2_chain_id):
    # Note: read_chain_cmd is a utility function that doesn't have access to plan
    return "`jq -r .address /network-data/{0}-{1}.json`".format(filename, l2_chain_id)
