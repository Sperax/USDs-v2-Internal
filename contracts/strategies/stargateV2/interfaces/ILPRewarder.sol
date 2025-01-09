pragma solidity 0.8.19;

interface ILPRewarder {
    function getRewards(address lpToken, address user) external view returns (uint256);
}
