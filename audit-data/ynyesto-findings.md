### [H-1] The constructor of `VaultShares` tries to get LP tokens from non-existent WETH/WETH Uniswap pools when the asset of the vault is WETH, which breaks the `divestThenInvest` modifier.

**Description:** 

The `VaultShares` constructor attempts to get the Uniswap liquidity token for the `asset + WETH` pair:

```solidity
i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth)));
```

However, when the asset is WETH itself, this creates a WETH/WETH pair which doesn't exist in Uniswap. This will cause the constructor to assign the null address to `i_uniswapLiquidityToken`, breaking the `divestThenInvest` modifier and any subsequent Uniswap operations.

**Impact:** 

- WETH vaults would fail during investment/divestment operations, because `i_uniswapLiquidityToken.balanceOf(address(this))` will fail.
- The protocol is fundamentally broken for WETH as an underlying asset

**Proof of Concept:**

In production, when trying to create a WETH vault:

1. `VaultShares` constructor calls `i_uniswapFactory.getPair(WETH, WETH)`
2. This returns `address(0)` because WETH/WETH pairs don't exist
3. `i_uniswapLiquidityToken` becomes `address(0)`
4. Later calls to `rebalanceFunds()`, `withdraw()` and `redeem()` will fail, because the `divestThenInvest()` will fail when calling `balanceOf()` on the null address.

**Recommended Mitigation:** 

Change the following line in the constructor of `VaultShares`:

```solidity
-       i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth))); 
+       if (address(constructorData.asset) == address(i_weth)) {
+           i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(i_weth), address(i_tokenOne))); 
+       }
+       else 
+       {
+            i_uniswapLiquidityToken = IERC20(i_uniswapFactory.getPair(address(constructorData.asset), address(i_weth))); 
+       }
```

---

### [M-1] The `deposit` function in `VaultShares` mints more shares than assets deposited, creating an inflationary mechanism that dilutes existing shareholders

**Description:** 

In the `deposit` function of `VaultShares`, the protocol mints shares to users based on `previewDeposit(assets)`, but then **additionally** mints shares to the guardian and DAO:

```solidity
uint256 shares = previewDeposit(assets);
_deposit(_msgSender(), receiver, assets, shares);

_mint(i_guardian, shares / i_guardianAndDaoCut);        // 0.1% of shares
_mint(i_vaultGuardians, shares / i_guardianAndDaoCut);  // 0.1% of shares
```

This means that (with the default s_guardianAndDaoCut = 1000) for every deposit:
- User gets 100% of the shares they should get
- Guardian gets 0.1% extra shares  
- DAO gets 0.1% extra shares
- **Total: 100.2% of shares are minted per deposit**

**Impact:** 

- **Share dilution**: Existing shareholders see their percentage ownership decrease with each deposit
- **Inflationary mechanism**: The total supply grows faster than the underlying assets
- **Economic imbalance**: Users pay the same amount but the protocol creates additional value for guardians and DAO

**Proof of Concept:**

The following test demonstrates the vulnerability:

```solidity
    function testMoreSharesMintedThanExpected() public hasGuardian { 
        // Initial state: guardian has 100% of shares
        uint256 initialTotalSupply = wethVaultShares.totalSupply();
        uint256 initialGuardianShares = wethVaultShares.balanceOf(guardian);
        uint256 initialVaultGuardiansShares = wethVaultShares.balanceOf(address(vaultGuardians));
        
        // User deposits assets
        address user = makeAddr("user");
        uint256 depositAmount = 10 ether;
        weth.mint(depositAmount, user);
        
        vm.startPrank(user);
        weth.approve(address(wethVaultShares), depositAmount);
        
        uint256 userSharesBefore = wethVaultShares.balanceOf(user);
        uint256 guardianSharesBefore = wethVaultShares.balanceOf(guardian);
        uint256 vaultGuardiansSharesBefore = wethVaultShares.balanceOf(address(vaultGuardians));
        uint256 totalSupplyBefore = wethVaultShares.totalSupply();
        
        uint256 totalExpectedMintedShares = wethVaultShares.previewDeposit(depositAmount);
        uint256 sharesReceivedByUser = wethVaultShares.deposit(depositAmount, user);

        vm.stopPrank();

        uint256 guardianAndDaoCut = vaultGuardians.getGuardianAndDaoCut();
        uint256 userSharesAfter = wethVaultShares.balanceOf(user);
        uint256 totalSupplyAfter = wethVaultShares.totalSupply();
        uint256 guardianSharesAfter = wethVaultShares.balanceOf(guardian);
        uint256 vaultGuardiansSharesAfter = wethVaultShares.balanceOf(address(vaultGuardians));
        uint256 sharesActuallyMinted = totalSupplyAfter - totalSupplyBefore;
        uint256 expectedSharesReceivedByUser = totalExpectedMintedShares - 2 * (totalExpectedMintedShares / guardianAndDaoCut);

        assertEq(guardianSharesAfter - guardianSharesBefore, sharesReceivedByUser / guardianAndDaoCut);
        assertEq(vaultGuardiansSharesAfter - vaultGuardiansSharesBefore, sharesReceivedByUser / guardianAndDaoCut);
        assertGt(sharesReceivedByUser, expectedSharesReceivedByUser);
        assertEq(sharesActuallyMinted, sharesReceivedByUser + 2 * (sharesReceivedByUser / guardianAndDaoCut));
        assertGt(sharesActuallyMinted, totalExpectedMintedShares);
        assertGt(totalSupplyAfter, totalSupplyBefore + totalExpectedMintedShares);
    }
```

**Recommended Mitigation:** 

The guardian and DAO cuts should be taken **from** the user's shares, not **in addition to** them. Modify the `deposit` function:

```solidity
uint256 shares = previewDeposit(assets);
uint256 guardianCut = shares / i_guardianAndDaoCut;
uint256 daoCut = shares / i_guardianAndDaoCut;
uint256 userShares = shares - guardianCut - daoCut;

_deposit(_msgSender(), receiver, assets, userShares);
_mint(i_guardian, guardianCut);
_mint(i_vaultGuardians, daoCut);
```

This ensures that exactly 100% of shares are minted per deposit, maintaining the economic balance of the protocol.

---

### [M-2] All Uniswap operations lack slippage protection, making them vulnerable to sandwich attacks

**Description:** 

The `UniswapAdapter` contract performs all Uniswap operations with `amountOutMin: 0`, `amountAMin: 0` and `amountBMin: 0`, making every swap, liquidity addition, and liquidity removal vulnerable to sandwich attacks:

1. **`swapExactTokensForTokens`** (line 56): `amountOutMin: 0`
2. **`addLiquidity`** (lines 80-81): `amountAMin: 0, amountBMin: 0`  
3. **`removeLiquidity`** (lines 101-102): `amountAMin: 0, amountBMin: 0`

**Impact:** 

- **Sandwich attack vulnerability**: MEV bots can front-run vault operations, manipulate prices, and back-run to extract value
- **Value extraction**: Users lose value on every swap and liquidity operation
- **Economic inefficiency**: The protocol consistently gets worse rates than intended
- **MEV exploitation**: The protocol becomes a target for predatory trading strategies

**Code Location:**

```solidity
// Lines 56 and 106: Swap without slippage protection
amountOutMin: 0,

// Lines 77-78: Add liquidity without slippage protection  
amountAMin: 0,
amountBMin: 0,

// Lines 98-99: Remove liquidity without slippage protection
amountAMin: 0,
amountBMin: 0,
```

**Recommended Mitigation:** 

Implement proper slippage protection by calculating minimum amounts based on expected output and adding a tolerance parameter:

```solidity
// Add slippage tolerance parameter
uint256 public constant SLIPPAGE_TOLERANCE = 50; // 0.5%

// Calculate minimum amounts with slippage protection
uint256 amountOutMin = (expectedAmountOut * (1000 - SLIPPAGE_TOLERANCE)) / 1000;
uint256 amountAMin = (expectedAmountA * (1000 - SLIPPAGE_TOLERANCE)) / 1000;
uint256 amountBMin = (expectedAmountB * (1000 - SLIPPAGE_TOLERANCE)) / 1000;

// Use calculated minimums instead of 0
amountOutMin: amountOutMin,
amountAMin: amountAMin,
amountBMin: amountBMin,
```

This would protect users from excessive slippage while maintaining reasonable execution rates.

---

### [L-1] Unnecessary double approval in `UniswapAdapter._uniswapInvest()` function

**Description:** 

The `_uniswapInvest()` function on line 66 approves `amountOfTokenToSwap + amounts[0]`:

```solidity
succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap + amounts[0]);
```

However, `amounts[0]` represents the amount of input token that was swapped, which equals `amountOfTokenToSwap`. This results in approving `2 * amountOfTokenToSwap`, which is unnecessary and grants to the Uniswap router double the approval needed.

**Impact:** In the unlikely event that Uniswap were hacked, our vault could be drained, since it approves double what it needs to and then only the right amount of approval is consumed.

**Code Location:**

```solidity
// Line 66: Double approval
succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap + amounts[0]);
```

**Recommended Mitigation:** 

Simplify the approval to only approve what's needed:

```solidity
// amounts[0] equals amountOfTokenToSwap, so just approve amountOfTokenToSwap
succ = token.approve(address(i_uniswapRouter), amountOfTokenToSwap);
```

---

---

### [L-2] Naive liquidity calculation in `UniswapAdapter` makes balanced liquidity addition leave small amounts of the asset in the `UniswapAdapter` contract due to not accounting for price impact, slippage and fees.

**Description:** 

The `_uniswapInvest()` function in `UniswapAdapter` uses a fundamentally flawed approach for adding liquidity:

```solidity
// We will do half in WETH and half in the token
uint256 amountOfTokenToSwap = amount / 2;
```

The function attempts to create a 50/50 liquidity pool by:
1. Swapping half the input token for the counter-party token
2. Adding liquidity with the remaining half + the swapped amount

However, with this approach is mathematically impossible to achieve balanced liquidity because it doesn't account for:

- **Swap fees**: Uniswap charges 1%, 0.3% or 0.05% fees on swaps, reducing the output amount
- **Price impact**: The swap itself moves the price, affecting the optimal liquidity ratio
- **Slippage**: The actual swap output may differ from the expected amount

**Impact:** 

- **Impossible liquidity ratios**: The protocol cannot create truly balanced 50/50 pools
- **Protocol failure**: The core liquidity provision mechanism is fundamentally broken
- **User fund loss**: Depositors receive suboptimal LP positions

**Proof of Concept:**

Consider adding liquidity to a WETH/USDC pool:

1. User deposits 1000 USDC
2. Protocol swaps 500 USDC for WETH
3. Due to 0.3% fee + price impact + slippage, it receives less than $500 worth of WETH 
4. Protocol adds liquidity with: 500 USDC + (WETH received)
5. Result: Some USDC is left in the contract because there wasn't enough WETH to match it.

**Code Location:**

```solidity
// Line 41: Flawed liquidity calculation
uint256 amountOfTokenToSwap = amount / 2;

// Lines 77-78: Impossible to achieve balanced liquidity
amountADesired: amountOfTokenToSwap + amounts[0], 
amountBDesired: amounts[1],
```

**Recommended Mitigation:** 

Implement proper liquidity calculation that accounts for fees and price impact:

```solidity
function _uniswapInvest(IERC20 tokenIn, uint256 amountIn) internal {
    IERC20 tokenOut = tokenIn == i_weth ? i_tokenOne : i_weth;

    // 1) Get the pair and reserves (ordered per token0/token1)
    address pair = IUniswapV2Factory(i_uniswapRouter.factory()).getPair(address(tokenIn), address(tokenOut));
    require(pair != address(0), "No pair");
    (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();

    (uint rIn, uint rOut) =
        address(tokenIn) == IUniswapV2Pair(pair).token0()
            ? (uint(r0), uint(r1))
            : (uint(r1), uint(r0));

    // 2) Compute optimal x to swap from tokenIn -> tokenOut
    uint x = _optimalSwapIn(amountIn, rIn);

    // 3) Swap exactly x with a sane minOut (e.g., 0.5% slippage guard)
    tokenIn.approve(address(i_uniswapRouter), x);
    address[] memory path = new address[](2);
    path[0] = address(tokenIn);
    path[1] = address(tokenOut);

    uint yExpected = UniswapV2Library.getAmountOut(x, rIn, rOut);
    uint yMin = (yExpected * 995) / 1000; // 0.5% slippage example

    uint[] memory amounts = i_uniswapRouter.swapExactTokensForTokens(
        x,
        yMin,
        path,
        address(this),
        block.timestamp
    );

    uint amountTokenA = amountIn - x;   // leftover of tokenIn after swap
    uint amountTokenB = amounts[1];     // tokenOut received

    // 4) Add liquidity with non-zero mins (protect vs MEV)
    tokenIn.approve(address(i_uniswapRouter), amountTokenA);
    tokenOut.approve(address(i_uniswapRouter), amountTokenB);

    // Optional: small slippage guard on LP add (e.g., allow 0.5% imbalance)
    uint amountAMin = (amountTokenA * 995) / 1000;
    uint amountBMin = (amountTokenB * 995) / 1000;

    (uint aUsed, uint bUsed, uint liq) = i_uniswapRouter.addLiquidity(
        address(tokenIn),
        address(tokenOut),
        amountTokenA,
        amountTokenB,
        amountAMin,
        amountBMin,
        address(this),
        block.timestamp
    );

    // 5) Sweep any tiny leftovers if you care (could send back to owner/treasury)
    // uint aLeft = amountTokenA - aUsed;
    // uint bLeft = amountTokenB - bUsed;
    // if (aLeft > 0) tokenIn.safeTransfer(treasury, aLeft);
    // if (bLeft > 0) tokenOut.safeTransfer(treasury, bLeft);

    emit UniswapInvested(aUsed, bUsed, liq);
}

// See Babylonian::sqrt() at https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/Babylonian.sol
function _optimalSwapIn(uint a, uint rIn) internal pure returns (uint) {
    // constants for 0.3% fee (γ = 0.997)
    uint numerator = Babylonian.sqrt(rIn * (a * 3988000 + rIn * 3988009)) - (rIn * 1997);
    return numerator / 1994;
}
```

**Key Improvements:**

1. **Mathematical precision**: Uses the optimal swap amount formula that accounts for Uniswap's 0.3% fee
2. **Slippage protection**: Implements 0.5% slippage guards on both swap and liquidity addition
3. **Reserve handling**: Correctly calculates reserves considering token ordering
4. **Leftover management**: Can sweep leftover tokens to treasury/owner
5. **MEV protection**: Non-zero minimum amounts prevent sandwich attacks

This approach ensures that the protocol creates the most balanced liquidity pools possible while protecting users from excessive slippage and MEV attacks.

### [I-1] Incorrect comment in `UniswapAdapter._uniswapInvest()` function

**Description:** 

The following comment in the `UniswapAdapter::_uniswapInvest()` function is incorrect:

```solidity
* @notice So we swap out half of the vault's underlying asset token for WETH if the asset token is USDC or WETH
```

This should read "if the asset token is USDC or LINK (or any other token)" since WETH is handled as a special case in the logic. When the asset is WETH, the function swaps half of it for USDC (`i_tokenOne`), not for WETH.

**Impact:** 

- **Documentation confusion**: Developers may misunderstand the intended behavior
- **Code maintainability**: Misleading comments make the code harder to understand and maintain

**Code Location:**

```solidity
// Line 32: Incorrect comment
* @notice So we swap out half of the vault's underlying asset token for WETH if the asset token is USDC or WETH
```

**Recommended Mitigation:** 

Fix the comment to accurately reflect the logic:

```solidity
* @notice So we swap out half of the vault's underlying asset token for WETH if the asset token is USDC or LINK
```

---

### [I-2] Misleading comment about `amounts[1]` in `UniswapAdapter._uniswapInvest()` function

**Description:** 

The comment on line 73 states:

```solidity
// amounts[1] should be the WETH amount we got back
```

This is misleading because `amounts[1]` is only the WETH amount when swapping from a non-WETH token to WETH. When the asset is WETH itself, `amounts[1]` represents the USDC amount received from swapping WETH to USDC.

**Impact:** 

- **Code confusion**: Developers may misunderstand what `amounts[1]` represents
- **Maintenance issues**: Incorrect comments make future code modifications more error-prone

**Code Location:**

```solidity
// Line 71: Misleading comment  
// amounts[1] should be the WETH amount we got back
```

**Recommended Mitigation:** 

Update the comment to be more accurate:

```solidity
// amounts[1] is the amount of counterPartyToken received from the swap
```

---

### [I-3] Empty and unused interfaces create confusion and suggest incomplete protocol design

**Description:** 

The protocol contains several empty interfaces that are not used anywhere in the codebase:

1. **`IVaultGuardians`** (src/interfaces/IVaultGuardians.sol): Completely empty interface with no function signatures
2. **`IInvestableUniverseAdapter`** (src/interfaces/InvestableUniverseAdapter.sol): Interface with both function signatures commented out

These interfaces suggest that the protocol was designed with a specific architecture in mind but was never fully implemented, creating confusion for developers and auditors.

**Impact:** 

- **Developer confusion**: Empty interfaces suggest incomplete or abandoned design patterns
- **Code maintainability**: Unused interfaces make the codebase harder to understand
- **Audit complexity**: Auditors must determine whether these are intentional or oversight
- **Protocol clarity**: Suggests the protocol design may have evolved from the original architecture

**Code Location:**

```solidity
// src/interfaces/IVaultGuardians.sol
interface IVaultGuardians {} // q why empty?

// src/interfaces/InvestableUniverseAdapter.sol  
interface IInvestableUniverseAdapter { // q why are both functions commented out?
// function invest(IERC20 token, uint256 amount) external;
// function divest(IERC20 token, uint256 amount) external;
}
```

**Recommended Mitigation:** 

Either:
1. **Remove unused interfaces** if they're not needed
2. **Implement the interfaces** if they represent intended functionality
3. **Add clear documentation** explaining why they exist but are empty

If these interfaces are meant for future use, add TODO comments explaining their intended purpose and timeline for implementation.

---

### [I-4] Confusing variable naming in `AStaticUSDCData.sol` makes the code harder to understand

**Description:** 

The `AStaticUSDCData.sol` contract uses the generic variable name `i_tokenOne` when it's specifically designed to work with USDC:

```solidity
// Intended to be USDC
IERC20 internal immutable i_tokenOne;
```

However, throughout the codebase, this variable is consistently used as if it were USDC, and the constructor parameter is even named `usdc` in some places. The generic name `i_tokenOne` is misleading and doesn't reflect the actual intended behavior.

**Impact:** 

- **Code readability**: Developers may not immediately understand that `i_tokenOne` is USDC
- **Maintenance confusion**: Future developers might think this variable can be any token
- **Audit complexity**: Auditors must trace through the code to understand the actual usage
- **Inconsistent naming**: The variable name doesn't match its intended purpose

**Code Location:**

```solidity
// src/abstract/AStaticUSDCData.sol
// Intended to be USDC
IERC20 internal immutable i_tokenOne;

// Used throughout the codebase as if it were USDC
constructor(address weth, address tokenOne) AStaticWethData(weth) {
    i_tokenOne = IERC20(tokenOne); 
}
```

**Recommended Mitigation:** 

Rename the variable to clearly indicate its purpose:

```solidity
// Change from generic to specific
IERC20 internal immutable i_usdc;

constructor(address weth, address usdc) AStaticWethData(weth) {
    i_usdc = IERC20(usdc);
}

function getUsdc() external view returns (IERC20) {
    return i_usdc;
}
```

This makes the code more self-documenting and eliminates confusion about the variable's intended purpose.
