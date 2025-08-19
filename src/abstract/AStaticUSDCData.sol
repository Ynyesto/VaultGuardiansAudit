// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AStaticWethData} from "./AStaticWethData.sol";

abstract contract AStaticUSDCData is AStaticWethData { // q why does it inherit from AStaticWethData?
    // Intended to be USDC
    IERC20 internal immutable i_tokenOne;
    string public constant TOKEN_ONE_VAULT_NAME = "Vault Guardian USDC";
    string public constant TOKEN_ONE_VAULT_SYMBOL = "vgUSDC";

    constructor(address weth, address tokenOne) AStaticWethData(weth) {
        i_tokenOne = IERC20(tokenOne); 
        // @audit-info: this could be any token, not just USDC, it seems like the intended behaviour is for tokenOne to always be USDC, but it is not enforced
    }

    /**
     * @return The USDC token
     */
    function getTokenOne() external view returns (IERC20) {
        return i_tokenOne;
    }
}
