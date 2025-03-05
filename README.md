# Delegation Framework

> [!WARNING]
> We use tags for audited versions of code releases and the `main` branch is the working development branch. All PRs should be based against `main` branch.

### Getting Started

1. **Fork the repository**:

   - Click the "Fork" button at the top right of the repository page.

2. **Clone your fork**:
   ```shell
   git clone https://github.com/<your-username>/delegation-framework.git
   ```
3. **Create Working Branch**:
   ```shell
   git checkout -b feat/example-branch
   ```

# DeleGator Smart Account

A DeleGator Smart Account is a 4337-compatible Smart Account that implements delegation functionality. An end user will operate through a DeleGatorProxy which uses a chosen DeleGator implementation.

## Overview

An end user controls a DeleGator Proxy that USES a DeleGator Implementation, which IMPLEMENTS DeleGatorCore and interacts with a DelegationManager.

### Delegations

A Delegation enables the ability to share the capability to invoke some onchain action entirely offchain in a secure manner. [Caveats](#caveats) can be combined to create delegations with restricted functionality that users can extend, share or redeem.

A simple example is "Alice delegates the ability to use her USDC to Bob limiting the amount to 100 USDC".

[Read more on "Delegations" ->](/documents/DelegationManager.md#Delegations)

### DeleGator

A DeleGator is the contract an end user controls and uses to interact with other contracts onchain. A DeleGator is an [EIP-1967](https://eips.ethereum.org/EIPS/eip-1967[EIP1967]) proxy contract that uses a DeleGator Implementation which defines the granular details of how the DeleGator works. Users are free to migrate their DeleGator Implementation as their needs change.

### DeleGator Core

The DeleGator Core includes the Delegation execution and ERC-4337 functionality to make the Smart Account work.

[Read more on "DeleGator Core" ->](/documents/DeleGatorCore.md)

### EIP7702 DeleGator Core

The DeleGator 7702 Core includes the Delegation execution and ERC-4337 functionality to make the Smart Account work but without UUPS proxy functionalities.

[Read more on "EIP7702 DeleGator Core" ->](/documents/EIP7702DeleGator.md)

### DeleGator Implementation

A DeleGator Implementation contains the logic for a DeleGator Smart Account. Each DeleGator Implementation must include the required methods for a DeleGator Smart Account, namely the signature scheme to be used for verifying access to control the contract. A few examples are the MultiSigDeleGator and the HybridDeleGator.

[Read more on "MultiSig DeleGator" ->](/documents/MultisigDeleGator.md)

[Read more on "Hybrid DeleGator" ->](/documents/HybridDeleGator.md)

[Read more on "EIP7702 Stateless DeleGator" ->](/documents/EIP7702DeleGator.md)

### Delegation Manager

The Delegation Manager includes the logic for validating and executing Delegations.

[Read more on "Delegation Manager" ->](/documents/DelegationManager.md)

### Caveat Enforcers

Caveats are used to add restrictions and rules for Delegations. By default, a Delegation allows the delegate to make **any** onchain action so caveats are strongly recommended. They are managed by Caveat Enforcer contracts.

Developers can build new Caveat Enforcers for their own use cases, and the possibilities are endless. Developers can optimize their Delegations by making extremely specific and granular caveats for their individual use cases.

[Read more on "Caveats" ->](/documents/DelegationManager.md#Caveats)

## Development

### Third Party Developers

There's several touchpoints where developers may be using or extending a DeleGator Smart Account.

- Developers can build custom DeleGator Implementations that use the [DeleGator Core](/src/DeleGatorCore.sol) or [EIP7702 DeleGator Core](/src/EIP7702/EIP7702DeleGatorCore.sol) to create new ways for end users to control and manage their Smart Accounts.
- Developers can write any contract that meets the [DeleGator Core Interface](/src/interfaces/IDeleGatorCore.sol) to create novel ways of delegating functionality.
- Developers can create custom Caveat Enforcers to refine the capabilities of a delegation for any use case they imagine.
- Developers can craft Delegations to then share onchain capabilities entirely offchain.

### Foundry

This repo uses [Foundry](https://book.getfoundry.sh/).

#### Build

```shell
forge build
```

#### Test

```shell
forge test
```

#### Deploying

1. Copy `.env.example` to `.env` and populate the variables depending on the deployment scripts that you will execute.

```shell
source .env
```

2. For local testing, use [Anvil](https://book.getfoundry.sh/reference/anvil/) to run a local fork of a blockchain to develop in an isolated environment. Or obtain the RPC url for the blockchain to deploy.

```shell
# Example of a forked local environment using anvil
anvil -f <your_rpc_url>
```

3. Deploy the necessary contracts.

> NOTE: As this system matures, this step will no longer be required for public chains where the DeleGator is in use.

```shell
# Deploys the Delegation Manager, Multisig and Hybrid DeleGator implementations
forge script script/DeployDelegationFramework.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast

# Deploys all the caveat enforcers
forge script script/DeployCaveatEnforcers.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast

# Deploys the EIP7702 Staless DeleGator
forge script script/DeployEIP7702StatelessDeleGator.s.sol --rpc-url <your_rpc_url> --private-key $PRIVATE_KEY --broadcast

# Deploys a MultisigDeleGator on a UUPS proxy
forge script script/DeployMultiSigDeleGator.s.sol --private-key $PRIVATE_KEY --broadcast
```

### Javascript

Currently in Gated Alpha phase. Sign up to be an early partner [here](https://gator.metamask.io).

### Notes

- We're building against Solidity [v0.8.23](https://github.com/ethereum/solidity/releases/tag/v0.8.23) for the time being.
- Format on save using the Forge formatter.

### Style Guide

[Read more on "Style Guide" ->](/documents/StyleGuide.md)

### Core Contributors

[Dan Finlay](https://github.com/danfinlay), [Ryan McPeck](https://github.com/McOso), [Dylan DesRosier](https://github.com/dylandesrosier), [Aditya Sharma](https://github.com/destroyersrt), [Hanzel Anchia Mena](https://github.com/hanzel98), [Idris Bowman](https://github.com/V00D00-child), [Jeff Smale](https://github.com/jeffsmale90), [Kevin Bluer](https://github.com/kevinbluer)

## Relevant Documents

- [EIP-712](https://eips.ethereum.org/EIPS/eip-712)
- [EIP-1014](https://eips.ethereum.org/EIPS/eip-1014)
- [EIP-1271](https://eips.ethereum.org/EIPS/eip-1271)
- [EIP-1822](https://eips.ethereum.org/EIPS/eip-1822)
- [EIP-1967](https://eips.ethereum.org/EIPS/eip-1967)
- [EIP-4337](https://eips.ethereum.org/EIPS/eip-4337)
- [EIP-7201](https://eips.ethereum.org/EIPS/eip-7201)
- [EIP-7212](https://eips.ethereum.org/EIPS/eip-7212)
- [EIP-7579](https://eips.ethereum.org/EIPS/eip-7579)
- [EIP-7702](https://eips.ethereum.org/EIPS/eip-7702)
- [EIP-7710](https://eips.ethereum.org/EIPS/eip-7710)
- [EIP-7821](https://eips.ethereum.org/EIPS/eip-7821)

# Hello World Delegation Example

This project demonstrates how to use the ERC-7715/ERC-7702/ERC-7710 delegation framework to allow one wallet to execute smart contract functions on behalf of another wallet.

## Overview

The example consists of:

1. A simple `HelloWorld` contract that is owned by a delegator wallet
2. A script that demonstrates various delegation scenarios:
   - Direct execution by the delegator
   - Delegated execution through another wallet
   - Batch execution of multiple functions
   - Try execution with error handling

## Key Components

- **HelloWorld.sol**: A simple contract with functions to update a message and increment a counter
- **HelloWorldDelegation.s.sol**: A script that demonstrates the delegation capabilities

## How It Works

1. The delegator wallet (ERC7715DeleGator) is the owner of the HelloWorld contract
2. The delegator can directly execute functions on the contract
3. The delegator can create a delegation to allow another wallet to execute functions on its behalf
4. The delegate can use the delegation to execute functions through the DelegationManager

## Running the Example

```bash
# Run the HelloWorld delegation script
forge script script/HelloWorldDelegation.s.sol -vvv
```

## Delegation Scenarios

### Direct Execution

The delegator directly executes a function on the HelloWorld contract by signing a transaction with its private key.

### Delegated Execution

The delegator creates a delegation that allows another wallet to execute functions on its behalf. The delegate then uses this delegation to execute a function through the DelegationManager.

### Batch Execution

Multiple function calls are batched together and executed in a single transaction.

### Try Execution

A function that will revert is executed using the "try" execution mode, which allows the transaction to succeed even if the inner call fails.

## Key Concepts

- **Delegation**: A signed permission from one wallet to another to execute specific functions
- **DelegationManager**: The central contract that validates delegations and executes functions
- **DeleGator**: A smart contract wallet that can create and use delegations
- **Execution Modes**: Different ways to execute functions (single, batch, try)
- **Caveats**: Conditions that can be attached to delegations (not used in this simple example)

## Further Reading

- [ERC-7710: Delegation Registry](https://eips.ethereum.org/EIPS/eip-7710)
- [ERC-7715: Smart Contract Account Delegation](https://eips.ethereum.org/EIPS/eip-7715)
- [ERC-7702: Stateless Smart Contract Account](https://eips.ethereum.org/EIPS/eip-7702)
