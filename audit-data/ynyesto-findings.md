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