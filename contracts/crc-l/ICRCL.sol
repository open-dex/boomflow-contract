pragma solidity 0.5.16;

interface ICRCL {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);

    function deposit(address to, uint256 amount) external;
    function depositCFX(address to) external payable;

    function transferFrom(address sender, address recipient, uint256 amount) external;
    function requestForceWithdraw() external;
    function forceWithdraw(address recipient) external;

    event Transfer(address indexed sender, address indexed recipient, uint256 value);
    event Deposit(address indexed sender, address indexed recipient, uint256 value);
    event Withdraw(address indexed sender, address indexed recipient, uint256 value);
    event Write(address indexed account, uint256 balance);
}