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

**Note:** This appears to be a known issue in the protocol. The `VaultGuardians` contract includes a `sweepErc20s()` function specifically designed to collect "little bits left around from swapping or rounding errors" and transfer them to the DAO. This suggests the developers were aware that the current liquidity calculation approach would leave leftover tokens in contracts. However, this function is fundamentally flawed because it can only sweep tokens from the `VaultGuardians` contract itself, while user funds and any leftover tokens from Uniswap operations are stored in individual `VaultShares` contracts.

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

---

### [M-3] `sweepErc20s` function in `VaultGuardians` is fundamentally flawed and cannot fulfill its intended purpose

**Description:** 

The `VaultGuardians` contract includes a `sweepErc20s()` function that claims to collect "little bits left around from swapping or rounding errors":

```solidity
/*
 * @notice Any excess ERC20s can be scooped up by the DAO. 
 * @notice This is often just little bits left around from swapping or rounding errors
 * @dev Since this is owned by the DAO, the funds will always go to the DAO. 
 * @param asset The ERC20 to sweep
 */
function sweepErc20s(IERC20 asset) external {
    uint256 amount = asset.balanceOf(address(this));
    emit VaultGuardians__SweptTokens(address(asset));
    asset.safeTransfer(owner(), amount);
}
```

However, this function has a critical architectural flaw: **it can only sweep tokens from the `VaultGuardians` contract itself, but user funds and leftover tokens from Uniswap operations are stored in individual `VaultShares` contracts**.

**Impact:** 

- **Function is ineffective**: The sweep function cannot collect the "dust" it's designed to collect
- **Misleading documentation**: The comment suggests it will collect leftover tokens from swaps, but it cannot
- **Wasted gas**: DAO calls to this function will always return 0 (no tokens to sweep)
- **Architectural confusion**: Suggests the developers didn't understand their own protocol design

**Root Cause:**

The protocol architecture separates concerns incorrectly:

1. **`VaultGuardians`** - Protocol entry point and DAO control (doesn't hold user funds)
2. **`VaultShares`** - Individual vaults that hold user deposits and leftover tokens
3. **`UniswapAdapter`** - Operates within `VaultShares` contracts, leaving dust there

The `holdAllocation` portion of user deposits (which could be 100% of deposits) never leaves the `VaultShares` contract:

```solidity
// src/protocol/VaultShares.sol _investFunds function
function _investFunds(uint256 assets) private {
    uint256 uniswapAllocation = (assets * s_allocationData.uniswapAllocation) / ALLOCATION_PRECISION;
    uint256 aaveAllocation = (assets * s_allocationData.aaveAllocation) / ALLOCATION_PRECISION;

    _uniswapInvest(IERC20(asset()), uniswapAllocation);
    _aaveInvest(IERC20(asset()), aaveAllocation);
    // holdAllocation is NEVER invested anywhere - it stays in VaultShares!
}
```

**Code Location:**

```solidity
// src/protocol/VaultGuardians.sol
function sweepErc20s(IERC20 asset) external {
    uint256 amount = asset.balanceOf(address(this)); // Only checks VaultGuardians balance
    asset.safeTransfer(owner(), amount);
}

// src/protocol/VaultShares.sol
function _investFunds(uint256 assets) private {
    // holdAllocation portion stays in VaultShares as underlying asset
    // Uniswap dust also stays in VaultShares
}
```

**Recommended Mitigation:** 

**Option 1: Remove the misleading function entirely (Recommended)**
Since the function cannot fulfill its intended purpose and any implementation would either be ineffective or dangerous, remove it completely to avoid confusion.

**Option 2: Implement safe sweeping with user allocation tracking**
If sweep functionality is truly needed, the contract must keep track of users' hold allocations to ensure only dust (tokens that exceed user deposits) can be swept:

```solidity
function sweepExcessTokens(IERC20 asset) external onlyOwner {
    uint256 totalUserHoldAllocations = getTotalUserHoldAllocations(asset);
    uint256 currentBalance = asset.balanceOf(address(this));
    
    require(currentBalance > totalUserHoldAllocations, "No excess tokens");
    uint256 excessAmount = currentBalance - totalUserHoldAllocations;
    
    asset.safeTransfer(owner(), excessAmount);
}
```

This approach requires tracking the total `holdAllocation` amounts in vaults to ensure user funds are never swept.

**Note:** The existing test `testSweepErc20s()` in `VaultGuardiansTest.t.sol` is misleading because it artificially transfers tokens to the `VaultGuardians` contract, which doesn't happen in normal protocol usage. In reality, user funds are deposited into `VaultShares` contracts by calling the `deposit()` function, making the sweep function ineffective.

The current implementation suggests the developers didn't fully understand their own protocol architecture, making this a significant design flaw that renders the sweep functionality completely ineffective.

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

The `AStaticUSDCData.sol` contract uses generic variable and constant names when it's specifically designed to work with USDC:

```solidity
// Intended to be USDC
IERC20 internal immutable i_tokenOne;
string public constant TOKEN_ONE_VAULT_NAME = "Vault Guardian USDC";
string public constant TOKEN_ONE_VAULT_SYMBOL = "vgUSDC";
```

However, throughout the codebase, these variables are consistently used as if they were USDC, and the constructor parameter is even named `usdc` in some places. The generic names `i_tokenOne`, `TOKEN_ONE_VAULT_NAME`, and `TOKEN_ONE_VAULT_SYMBOL` are misleading and don't reflect the actual intended behavior.

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
string public constant TOKEN_ONE_VAULT_NAME = "Vault Guardian USDC";
string public constant TOKEN_ONE_VAULT_SYMBOL = "vgUSDC";

constructor(address weth, address tokenOne) AStaticWethData(weth) {
    i_tokenOne = IERC20(tokenOne); 
}
```

**Recommended Mitigation:** 

Rename the variable and constants to clearly indicate their purpose:

```solidity
// Change from generic to specific
IERC20 internal immutable i_usdc;
string public constant USDC_VAULT_NAME = "Vault Guardian USDC";
string public constant USDC_VAULT_SYMBOL = "vgUSDC";

constructor(address weth, address usdc) AStaticWethData(weth) {
    i_usdc = IERC20(usdc);
}

function getUsdc() external view returns (IERC20) {
    return i_usdc;
}
```

This makes the code more self-documenting and eliminates confusion about the variable's intended purpose.

---

### [I-5] Misleading comment in `AStaticWethData.sol` references non-existent tokens

**Description:** 

The `AStaticWethData.sol` contract contains a confusing comment that suggests it defines multiple tokens:

```solidity
// The following four tokens are the approved tokens the protocol accepts
// The default values are for Mainnet
```

However, this contract only defines one token (`i_weth`) and its associated constants. The comment about "four tokens" is misleading and doesn't match the actual implementation.

**Impact:** 

- **Developer confusion**: The comment suggests there should be four tokens defined in this contract
- **Code inconsistency**: The comment doesn't match the actual code structure
- **Maintenance issues**: Future developers might look for missing token definitions
- **Audit complexity**: Auditors must determine if tokens are missing or if the comment is wrong

**Code Location:**

```solidity
// src/abstract/AStaticWethData.sol
// The following four tokens are the approved tokens the protocol accepts
// The default values are for Mainnet
IERC20 internal immutable i_weth;
// slither-disable-next-line unused-state
string internal constant WETH_VAULT_NAME = "Vault Guardian WETH";
// slither-disable-next-line unused-state
string internal constant WETH_VAULT_SYMBOL = "vgWETH";
```

**Recommended Mitigation:** 

Update the comment to accurately reflect what the contract actually defines:

```solidity
// This contract defines the WETH token and its associated vault metadata
// The default values are for Mainnet
IERC20 internal immutable i_weth;
```

Alternatively, if the comment refers to the entire inheritance chain (WETH + USDC + LINK), clarify this:

```solidity
// This contract defines the WETH token. Combined with child contracts,
// the protocol accepts WETH, USDC, and LINK as approved tokens.
// The default values are for Mainnet
```

This eliminates confusion and makes the code more maintainable.

---

### [I-6] Hardcoded LINK values in `AStaticTokenData.sol` contradict the contract's generic design

**Description:** 

The `AStaticTokenData.sol` contract is designed to be generic and work with any token, but it contains hardcoded LINK-specific values that contradict this design:

```solidity
// Intended to be LINK
IERC20 internal immutable i_tokenTwo;
string public constant TOKEN_TWO_VAULT_NAME = "Vault Guardian LINK";
string public constant TOKEN_TWO_VAULT_SYMBOL = "vgLINK";
```

The contract's generic design allows it to work with LINK or any other tokens that may be added in the future, but the hardcoded vault name and symbol are specifically tied to LINK. This creates a contradiction between the contract's intended flexibility and its actual implementation.

**Impact:** 

- **Design inconsistency**: The contract claims to be generic but has token-specific hardcoded values
- **Limited flexibility**: Adding new tokens requires code changes instead of just constructor parameters
- **Maintenance overhead**: Future token additions require editing the hardcoded names.
- **Architectural confusion**: The contract structure suggests flexibility but the implementation is rigid

**Code Location:**

```solidity
// src/abstract/AStaticTokenData.sol
// Intended to be LINK
IERC20 internal immutable i_tokenTwo;
string public constant TOKEN_TWO_VAULT_NAME = "Vault Guardian LINK";
string public constant TOKEN_TWO_VAULT_SYMBOL = "vgLINK";

constructor(address weth, address tokenOne, address tokenTwo) AStaticUSDCData(weth, tokenOne) {
    i_tokenTwo = IERC20(tokenTwo);
}
```

**Recommended Mitigation:** 

Make the vault name and symbol configurable through the constructor to maintain the contract's generic design:

```solidity
abstract contract AStaticTokenData is AStaticUSDCData {
    IERC20 internal immutable i_tokenTwo;
    string public immutable i_tokenTwoVaultName;
    string public immutable i_tokenTwoVaultSymbol;

    constructor(
        address weth, 
        address tokenOne, 
        address tokenTwo,
        string memory vaultName,
        string memory vaultSymbol
    ) AStaticUSDCData(weth, tokenOne) {
        i_tokenTwo = IERC20(tokenTwo);
        i_tokenTwoVaultName = vaultName;
        i_tokenTwoVaultSymbol = vaultSymbol;
    }

    function getTokenTwo() external view returns (IERC20) {
        return i_tokenTwo;
    }
}
```

This approach maintains the contract's generic nature while allowing each deployment to specify appropriate vault metadata for whatever token is being used.

---

### [I-7] Confusing inheritance hierarchy for static token data

**Description:**

The protocol defines static token references through a chain of abstract contracts:

```solidity
// Chain 1: VaultGuardiansBase
AStaticWethData → AStaticUSDCData → AStaticTokenData → VaultGuardiansBase

// Chain 2: UniswapAdapter
AStaticWethData → AStaticUSDCData → UniswapAdapter
```

This creates two different inheritance paths for similar functionality.
- **VaultGuardiansBase** inherits from `AStaticTokenData` and therefore has access to:
  - `i_weth` (from AStaticWethData)
  - `i_tokenOne` (from AStaticUSDCData)
  - `i_tokenTwo` (from AStaticTokenData)
- **UniswapAdapter** inherits only from `AStaticUSDCData`, so it only has access to:
  - `i_weth`
  - `i_tokenOne`

**Impact:**

- **Architectural inconsistency**: Different parts of the system expose different subsets of tokens despite similar naming and structure.
- **Maintainability risk**: Adding or changing token definitions requires reasoning about which contracts "see" which tokens.
- **Onboarding confusion**: The inheritance chain suggests all contracts share a consistent token model, but they don't.

This is not a direct security risk, but it increases the complexity of understanding and maintaining the system.

**Code Location:**

```solidity
// src/protocol/investableUniverseAdapters/UniswapAdapter.sol
contract UniswapAdapter is AStaticUSDCData { // Only gets i_weth + i_tokenOne

// src/protocol/VaultGuardiansBase.sol  
contract VaultGuardiansBase is AStaticTokenData, IVaultData { // Gets i_weth + i_tokenOne + i_tokenTwo
```

**Recommended Mitigation:**

Unify the inheritance approach so contracts follow a consistent token model. Options include:

1. **Consistent inheritance**: Have all contracts inherit from `AStaticTokenData`, ignoring unused tokens where not needed.
2. **Restructure layers**: Split tokens into clear hierarchies (e.g., CoreTokens for WETH+USDC, ExtendedTokens for LINK and beyond).
3. **Composition over inheritance**: Pass required tokens via constructor parameters instead of through an inheritance chain.

---

### [I-8] Unnecessary contract separation creates architectural complexity

**Description:** 

The protocol unnecessarily separates functionality between `VaultGuardians.sol` and `VaultGuardiansBase.sol`:

- **`VaultGuardians`** inherits from `VaultGuardiansBase` and `Ownable`, but only adds:
  - `updateGuardianStakePrice()` function
  - `updateGuardianAndDaoCut()` function  
  - `sweepErc20s()` function (which is fundamentally flawed)
- **`VaultGuardiansBase`** contains all the core protocol logic

This separation adds unnecessary complexity without providing any architectural benefits. The `VaultGuardians` contract serves no purpose beyond being a thin wrapper that could easily be integrated into the base contract.

**Impact:** 

- **Unnecessary complexity**: Two contracts instead of one for no clear reason
- **Maintenance overhead**: Changes require updates in multiple contracts
- **Architectural confusion**: Unclear why the separation exists

**Code Location:**

```solidity
// src/protocol/VaultGuardians.sol
contract VaultGuardians is Ownable, VaultGuardiansBase {
    // Only adds 3 functions, all of which could be in VaultGuardiansBase
}

// src/protocol/VaultGuardiansBase.sol  
contract VaultGuardiansBase is AStaticTokenData, IVaultData {
    // Contains all the actual protocol logic
}
```

**Recommended Mitigation:** 

Consolidate the contracts by:
1. **Renaming** `VaultGuardiansBase` to `VaultGuardians`
2. **Making** `VaultGuardians` inherit from `Ownable` directly
3. **Moving** the three functions from the current `VaultGuardians` into the renamed base contract
4. **Removing** the unnecessary `VaultGuardians.sol` file

This simplifies the architecture while maintaining all functionality.

---

### [I-9] Wrong event emitted in `updateGuardianAndDaoCut` function

**Description:** 

The `updateGuardianAndDaoCut` function in `VaultGuardians.sol` emits the wrong event:

```solidity
function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
    s_guardianAndDaoCut = newCut;
    emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut); // WRONG EVENT!
}
```

The function updates the guardian and DAO cut percentage, but it emits `VaultGuardians__UpdatedStakePrice` instead of the appropriate `VaultGuardians__UpdatedGuardianAndDaoCut` which isn't even defined.

**Impact:** 

- **Misleading events**: Event logs don't accurately reflect what was updated
- **Monitoring confusion**: External systems monitoring events will receive incorrect information
- **Audit complexity**: Event logs don't match the actual function behavior
- **Code inconsistency**: The wrong event name suggests the function updates stake price, not fees

**Code Location:**

```solidity
// src/protocol/VaultGuardians.sol
event VaultGuardians__UpdatedStakePrice(uint256 oldStakePrice, uint256 newStakePrice);
event VaultGuardians__UpdatedFee(uint256 oldFee, uint256 newFee);

function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
    s_guardianAndDaoCut = newCut;
    emit VaultGuardians__UpdatedStakePrice(s_guardianAndDaoCut, newCut); // Should be UpdatedFee
}
```

**Recommended Mitigation:** 

Define the correct event and fix the event emission to use it:

```solidity
event VaultGuardians__UpdatedGuardianAndDaoCut(uint256 oldCut, uint256 newCut);

function updateGuardianAndDaoCut(uint256 newCut) external onlyOwner {
    uint256 oldCut = s_guardianAndDaoCut;
    s_guardianAndDaoCut = newCut;
    emit VaultGuardians__UpdatedGuardianAndDaoCut(oldCut, newCut); // Correct event
}
```

---

### [I-10] Multiple unused error definitions create code clutter

**Description:** 

Several error definitions in the protocol are never thrown, creating unnecessary code:

1. **`VaultGuardians__TransferFailed`** in `VaultGuardians.sol` - Never used
2. **`VaultGuardiansBase__NotEnoughWeth`** in `VaultGuardiansBase.sol` - Never thrown
3. **`VaultGuardiansBase__CantQuitGuardianWithNonWethVaults`** in `VaultGuardiansBase.sol` - Never thrown  
4. **`VaultGuardiansBase__FeeTooSmall`** in `VaultGuardiansBase.sol` - Never thrown

These unused errors suggest incomplete implementation or abandoned features, making the code harder to understand and maintain.

**Impact:** 

- **Code clutter**: Unnecessary error definitions that serve no purpose
- **Maintenance confusion**: Developers may think these errors are used somewhere
- **Audit complexity**: Auditors must determine if these are intentional or oversight
- **Protocol clarity**: Suggests incomplete or evolving design

**Code Location:**

```solidity
// src/protocol/VaultGuardians.sol
error VaultGuardians__TransferFailed(); // Never used

// src/protocol/VaultGuardiansBase.sol
error VaultGuardiansBase__NotEnoughWeth(uint256 amount, uint256 amountNeeded); // Never thrown
error VaultGuardiansBase__CantQuitGuardianWithNonWethVaults(address guardianAddress); // Never thrown
error VaultGuardiansBase__FeeTooSmall(uint256 fee, uint256 requiredFee); // Never thrown
```

**Recommended Mitigation:** 

Either:
1. **Remove unused errors** if they're not needed
2. **Implement the missing functionality** if these errors represent intended features
3. **Add TODO comments** explaining why these errors exist but are unused

If these errors are meant for future use, document their intended purpose and timeline for implementation. Otherwise, remove them to clean up the codebase.

---
