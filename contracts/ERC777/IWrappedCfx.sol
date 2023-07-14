pragma solidity >=0.4.24;

interface IWrappedCfx {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}