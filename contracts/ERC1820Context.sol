pragma solidity 0.5.16;

import "@openzeppelin/contracts/utils/Address.sol";
import "@openzeppelin/contracts/introspection/IERC1820Registry.sol";

contract ERC1820Context {

    address private constant _ERC1820_REGISTRY_ETH = 0x1820a4B7618BdE71Dce8cdc73aAB6C95905faD24;
    address private constant _ERC1820_REGISTRY_CFX = 0x88887eD889e776bCBe2f0f9932EcFaBcDfCd1820;

    IERC1820Registry internal ERC1820_REGISTRY;

    constructor() public {
        if (Address.isContract(_ERC1820_REGISTRY_ETH)) {
            ERC1820_REGISTRY = IERC1820Registry(_ERC1820_REGISTRY_ETH);
        } else {
            require(Address.isContract(_ERC1820_REGISTRY_CFX), "ERC777: ERC1820 not deployed yet");
            ERC1820_REGISTRY = IERC1820Registry(_ERC1820_REGISTRY_CFX);
        }
    }

}
