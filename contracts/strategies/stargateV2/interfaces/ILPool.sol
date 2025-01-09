pragma solidity 0.8.19;

interface ILPool {
    function deposit(address receiver, uint256 _amount) external;
    function redeem(uint256 _amount, address receiver) external;
    function lpToken() external view returns (address);
    function redeemable(address _owner) external view returns (uint256);
    function token() external view returns (address);
}
