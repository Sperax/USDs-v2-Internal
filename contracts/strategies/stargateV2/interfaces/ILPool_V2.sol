pragma solidity 0.8.19;

interface ILPool_V2 {
    function deposit(address receiver, uint256 amountLD) external;
    function redeem(uint256 amountLD, address receiver) external returns (uint256);
    function lpToken() external view returns (address);
    function redeemable(address owner) external view returns (uint256);
    function token() external view returns (address);
}
