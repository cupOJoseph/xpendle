# xPENDLE

Token and vault contract for institutional grade vePENDLE liquid staking.

## Features:
1. Deposit PENDLE in the vault to recieve xPENDLE
2. PENDLE received by the vault auto locks for 30 days and pays 90% of rewards to xPENDLE holders. 10% of rewards are directed to xPENDLE-PENDLE LPs
3. Council governance on PENDLE votes that can be turned over to other guages or other systems in the future. Council Governance can also update the split of rewards.

<hr>

## Withdrawals and Redemption Queue (stPENDLE.sol)

- **AUM-based accounting**: The vault tracks total PENDLE under management (AUM). Shares represent a pro‑rata claim on AUM. Conversions use AUM and `totalSupply()`:
  - `convertToShares = fullMulDiv(assets, totalSupply, AUM)`
  - `convertToAssets = fullMulDiv(shares, AUM, totalSupply)`
- **Epoch-based queue**: Withdrawals are requested in shares and queued per epoch. Requests for the current epoch are not allowed; use the next epoch or a specific future epoch.
- **How to request**: `requestRedemptionForEpoch(uint256 shares, uint256 epoch)` where `epoch = 0` means `currentEpoch + 1`. The vault records pending shares per user per epoch.
- **Redemption window**: During each epoch, claims can be executed only within `preLockRedemptionPeriod` from the epoch start; outside the window, claims return 0.
- **Claiming**: Users claim queued redemptions with `claimAvailableRedemptionShares(uint256 shares)` during the window.
- **Snapshot and rate**:
  - At the start of each epoch (`startNewEpoch()`), the vault snapshots `AUM` and `totalSupply` to derive a fixed assets‑per‑share rate for that epoch.
  - All claims in that epoch settle at the snapshot rate (independent of intra‑epoch deposits/fees).
- **Liquidity and epochs**:
  - `startFirstEpoch()`: locks the vault’s entire PENDLE balance for the initial epoch.
  - `startNewEpoch()`: withdraws matured vePENDLE, computes assets reserved for pending redemptions at the snapshot rate (clamped to unlocked), and re‑locks the remainder for `epochDuration`.
- **Deposits**:
  - Before the first epoch: use `depositBeforeFirstEpoch(assets, receiver)`. Shares mint 1:1 against assets and are not locked until `startFirstEpoch()` is called.
  - After the first epoch has started: use `deposit(assets, receiver)`. Deposited assets increase AUM and are locked immediately (subject to current epoch locking logic).
- **Fees**: `claimFees(totalAccrued, proof)` increases AUM (no share mint). If the redemption window is closed, the vault may lock all currently unlocked PENDLE except what’s needed to honor reserved redemptions.
- **Observability**: `getUserAvailableRedemption(address)`, `getTotalRequestedRedemptionAmountPerEpoch(uint256)`, `redemptionUsersForEpoch(uint256)`, `getAvailableRedemptionAmount()` (unlocked PENDLE balance), `previewVeWithdraw()`, and `previewRedeemWithCurrentValues(uint256)`.
**⚠️ Important Limitations**
- Standard ERC‑4626 `redeem`, `mint`, and `withdraw` functions are **disabled**
- Withdrawals require epoch‑based queueing with specific timing windows
- Claims outside redemption windows return **zero assets**
- Current epoch requests are not allowed — minimum 1 epoch delay

## Dev Instructions 

## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
