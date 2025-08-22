### [H-2] Public `rebalanceFunds()` enables griefing and MEV exploitation when allocations change

**Description:**

The `rebalanceFunds()` function in `VaultShares.sol` is publicly callable and applies the `divestThenInvest` modifier. This forces the vault to fully unwind its Uniswap LP and Aave positions and then reinvest according to the current allocation data.  

At first glance, one might assume this is always exploitable via sandwich attacks since intermediate swaps occur during the rebalance process. However, if the allocation ratios have **not changed**, the vault’s round-trip divest/reinvest cycle results in approximately the same state as before (e.g., withdrawing WETH+USDC liquidity, temporarily swapping to balance the pair, then swapping back when re-adding liquidity). In such a case, backrunning the transaction does not yield consistent extractable profit for attackers, since the pool ends up effectively unchanged.  

The real vulnerability arises after a vault guardian calls `updateHoldingAllocation`. In that scenario, the next call to `rebalanceFunds()` performs *meaningful allocation changes* — for example, reducing Aave allocation and increasing Uniswap allocation. This requires one-sided trades of predictable direction and large size. These trades are visible in the mempool and can be sandwiched, allowing MEV searchers to extract value from the vault.  

**Impact:**

- **MEV exploitation after allocation changes:** When `updateHoldingAllocation` modifies the strategy, the subsequent `rebalanceFunds` performs large predictable swaps that can be sandwiched for profit at the vault’s expense.
- **Griefing risk:** Public callers can repeatedly force full divest/reinvest cycles, exposing the vault to unnecessary slippage and (swap, and liquidity addition and withdrawal) fees even if allocations remain unchanged.
- **Economic inefficiency:** The “divest everything, reinvest everything” approach magnifies costs versus a delta-based rebalance.

**Code Location:**

```solidity
// src/protocol/VaultShares.sol
function rebalanceFunds() public isActive divestThenInvest nonReentrant {}
// ❌ Public access allows anyone to trigger costly operations and expose allocation changes to MEV
```

**Recommended Mitigation:**

1. **Access control:** Restrict `rebalanceFunds()` to trusted roles (e.g., guardian or DAO) rather than leaving it public.
2. **Delta-based rebalancing:** Instead of divesting all funds, compute and execute only the minimal trades required to reach the new allocation.
3. **Slippage checks:** Add strict `minOut` protections to prevent execution at manipulated prices when allocation changes do require swaps.

```solidity
// Example guardian-only restriction
function rebalanceFunds() public onlyGuardian isActive nonReentrant {
    _rebalancePortfolio();
}
```

