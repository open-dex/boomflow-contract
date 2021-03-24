pragma solidity >=0.4.24;

interface IWrappedCfx {
    function deposit() external payable;
    function burn(uint256 amount, bytes calldata data) external;
}