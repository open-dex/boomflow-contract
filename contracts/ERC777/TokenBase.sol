pragma solidity 0.5.16;

import "./ERC777.sol";
import "@openzeppelin/contracts/ownership/Ownable.sol";
import "@openzeppelin/contracts/lifecycle/Pausable.sol";

contract TokenBase is ERC777, Ownable {
    event Minted(
        address indexed toAddress,
        uint256 indexed amount,
        string defi,
        string tx_id
    );
    event Burnt(
        uint256 indexed amount,
        string toAddress,
        address indexed fromAddress,
        address defi_relayer
    );

    constructor(
        string memory name,
        string memory symbol,
        address[] memory defaultOperators
    ) public ERC777(name, symbol, defaultOperators) {}

    /* ===== Mint & Burn =====*/
    function mint(
        address account,
        uint256 amount,
        string memory defi,
        string memory tx_id
    ) public onlyOwner whenNotPaused returns (bool) {
        _mint(_msgSender(), account, amount, "", "");
        emit Minted(account, amount, defi, tx_id);
        return true;
    }

    /*
        dex burn cToken from its banker address to withdraw token to user.
        Here useraddr is user conflux address, addr is user btc/eth address.
    */
    function burn(
        address useraddr,
        uint256 amount,
        string memory addr,
        address defi_relayer
    ) public whenNotPaused returns (bool) {
        _burn(_msgSender(), _msgSender(), amount, "", "");
        emit Burnt(amount, addr, useraddr, defi_relayer);
        return true;
    }
}
