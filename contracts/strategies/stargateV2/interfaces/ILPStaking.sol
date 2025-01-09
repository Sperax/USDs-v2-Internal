pragma solidity 0.8.19;

interface ILPStaking {
    function deposit(address token, uint256 _amount) external;

    function depositTo(address token, address to, uint256 _amount) external;

    function withdraw(address token, uint256 _amount) external;

    function emergencyWithdraw(address token) external;

    function claim(address token) external;

    function balanceOf(address token, address _user) external view returns (uint256);

    function isPool(address lpToken) external view returns (bool);
}
