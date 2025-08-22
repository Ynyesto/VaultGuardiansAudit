### [C-1] Public `rebalanceFunds()` function enables MEV exploitation and fund drain

**Description:**

The `rebalanceFunds()` function in `VaultShares.sol` is currently **publicly callable** and applies the `divestThenInvest` modifier. This means that *any address* can trigger a full divestment of the vault’s Uniswap LP tokens and Aave positions, followed by reinvestment based on the vault’s allocation policy.  

While at first glance this appears “neutral” because liquidity is removed and re-added atomically, in practice the reinvestment process requires **large, deterministic swaps** through the Uniswap router in order to match the target allocation (e.g., converting a portion of the underlying into WETH or USDC before minting LP tokens). These swaps are fully visible in the mempool, predictable in direction, and of significant size relative to TVL.  

This makes the function a **prime MEV target**. Searchers can front-run to push price against the vault’s side, allow the vault to execute its predictable swaps at a worse rate, and back-run to restore price. The resulting slippage and fee losses are effectively drained from the vault’s capital. Since `rebalanceFunds` is public, attackers can **call it repeatedly** whenever profitable, turning the vault into a continuous source of extractable value.

Additionally, because the function performs a full divest/reinvest cycle even when only a small adjustment is needed, the gas costs and slippage are unnecessarily maximized, amplifying the attack surface. This also introduces a griefing vector, as malicious actors can deliberately trigger costly rebalances to harm vault performance.

**Impact:**

- **MEV exploitation:** Predictable large swaps can be sandwiched indefinitely, draining value from vault users.
- **Economic drain:** Repeated calls by attackers can extract profits from the vault whenever gas costs are lower than sandwich profit, leading to long-term erosion of user funds.
- **Griefing risk:** Anyone can force the vault to perform expensive operations (full divest/reinvest) even when unnecessary, consuming gas and introducing slippage losses without guardian approval.

**Code Location:**

```solidity
// src/protocol/VaultShares.sol
function rebalanceFunds() public isActive divestThenInvest nonReentrant {}
// ❌ Public access allows anyone to repeatedly trigger costly and exploitable operations
```

**Recommended Mitigation:**

Restrict and harden rebalance logic to minimize MEV exposure:

1. **Access control:** Limit `rebalanceFunds` to a trusted role such as `onlyGuardian` or a strategist contract.
2. **Delta-based rebalancing:** Instead of divesting everything, calculate the difference between current and target allocations and only trade the required deltas.
3. **Slippage protection:** Add strict `minOut` checks per swap, ideally using oracle/TWAP validation to avoid execution at manipulated prices.
4. **Cooldown or rate-limiting:** Enforce a minimum time between rebalances to prevent repeated griefing calls.
5. **Private execution:** Where possible, use protected transaction relays (e.g., Flashbots) to prevent mempool visibility of large predictable swaps.

```solidity
// Guardian-only access example
function rebalanceFunds() public onlyGuardian isActive nonReentrant {
    _rebalancePortfolio();
}

// Or cooldown-based public version (less recommended)
uint256 private constant REBALANCE_COOLDOWN = 1 hours;
uint256 private s_lastRebalance;

function rebalanceFunds() public isActive nonReentrant {
    require(block.timestamp >= s_lastRebalance + REBALANCE_COOLDOWN, "Cooldown active");
    s_lastRebalance = block.timestamp;
    _rebalancePortfolio();
}
```
