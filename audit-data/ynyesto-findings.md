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

This means that (with the default s_guardianAndDaoCut) for every deposit:
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


### [I-3] Misleading comment about `amounts[1]` in `UniswapAdapter._uniswapInvest()` function

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
