pragma solidity 0.5.16;

interface ITokenBase {
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external pure returns (uint8);

    function granularity() external pure returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address tokenHolder) external view returns (uint256);

    function send(
        address recipient,
        uint256 amount,
        bytes calldata data
    ) external;

    function transfer(address recipient, uint256 amount)
        external
        returns (bool);

    function isOperatorFor(address operator, address tokenHolder)
        external
        view
        returns (bool);

    function authorizeOperator(address operator) external;

    function revokeOperator(address operator) external;

    function defaultOperators() external view returns (address[] memory);

    function operatorSend(
        address sender,
        address recipient,
        uint256 amount,
        bytes calldata data,
        bytes calldata operatorData
    ) external;

    function allowance(address holder, address spender)
        external
        view
        returns (uint256);

    function approve(address spender, uint256 value) external returns (bool);

    function transferFrom(
        address holder,
        address recipient,
        uint256 amount
    ) external returns (bool);

    function mint(
        address account,
        uint256 amount,
        address fee_address,
        uint256 fee,
        address defi,
        string calldata tx_id
    ) external returns (bool);

    function burn(
        address user_addr,
        uint256 amount,
        uint256 expected_fee,
        string calldata addr,
        address defi_relayer
    ) external returns (bool);

    function transferOwnership(address newOwner) external;
}
