pragma solidity 0.8.19;

interface ILPToken {
    function transferFrom(address from, address to, uint256 _amount) external;

    function balanceOf(address token, address _user) external view returns (uint256);

    function stargate() external view returns (address);
}
