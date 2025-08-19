// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AStaticUSDCData} from "./AStaticUSDCData.sol";

abstract contract AStaticTokenData is AStaticUSDCData { // a: tokenOne is meant to always be USDC, but it is not enforced
    // Intended to be LINK
    IERC20 internal immutable i_tokenTwo;
    // @audit-info this is opinionated to LINK even though the name of the interface isn't
    string public constant TOKEN_TWO_VAULT_NAME = "Vault Guardian LINK";
    string public constant TOKEN_TWO_VAULT_SYMBOL = "vgLINK";

    constructor(address weth, address tokenOne, address tokenTwo) AStaticUSDCData(weth, tokenOne) {
        i_tokenTwo = IERC20(tokenTwo);
        // @audit-info: this could be any token, not just LINK, it seems like the intended behaviour is for tokenTwo to be LINK in this case, but it is not enforced
    }

    /**
     * @return The LINK token
     */
    function getTokenTwo() external view returns (IERC20) {
        return i_tokenTwo;
    }
}
