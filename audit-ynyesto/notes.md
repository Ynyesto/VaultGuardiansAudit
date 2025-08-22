Repo doesn't work out of the box. I had to remove the --no-commit flags from the makefile and then I had to remove the OpenZeppelin packages and reinstall with `forge install openzeppelin/openzeppelin-contracts@v5.0.2`.

It seems like the intended behaviour is for token one to always be USDC, so the protocol should work with WETH, USDC and any tokenTwo (LINK in these examples). 

UniswapFactoryMock::getPair() returns always the same address, regardless of the pool being usdc-weth or link-weth, so watch out.

IVaultGuardians is empty.
IInvestableUniverseAdapter is empty too, functions are commented out.

IVaultShares: 
    -   address vaultGuardians; seems like a name for an array, but is just one address

VaultGuardianBase:
