pragma solidity 0.8.19;

interface ILPStaking_V2 {
    function deposit(address lpToken, uint256 amount) external;

    function depositTo(address lpToken, address to, uint256 amount) external;

    function withdraw(address lpToken, uint256 amount) external;

    function emergencyWithdraw(address lpToken) external;

    function claim(address[] memory lpTokens) external;

    function balanceOf(address lpToken, address user) external view returns (uint256);

    function isPool(address lpToken) external view returns (bool);
}
