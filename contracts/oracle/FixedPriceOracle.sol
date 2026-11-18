// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

/// @title Fixed Price Oracle for USDs protocol
/// @author Sperax Foundation
/// @notice Returns a constant price for exactly one token.
/// @dev Non-upgradeable, no owner, all state is immutable. Deploy one instance per token.
///      Drop-in source for MasterPriceOracle in place of ChainlinkOracle.getTokenPrice(token),
///      for tokens whose Chainlink feed is deprecated. Replace it later via MasterPriceOracle.updateTokenPriceFeed.
contract FixedPriceOracle {
    // Token this oracle prices
    address public immutable TOKEN;
    // Price of one token, scaled by PRICE_PRECISION
    uint256 public immutable PRICE;
    // Precision factor for the price
    uint256 public immutable PRICE_PRECISION;

    // Custom error messages
    error TokenNotSupported(address token);
    error InvalidAddress();
    error InvalidPrice();
    error InvalidPricePrecision();

    /// @param _token Address of the token
    /// @param _price Price of the token scaled by `_pricePrecision`
    /// @param _pricePrecision Precision factor for the price (e.g. 1e8 to match Chainlink USD feeds)
    constructor(address _token, uint256 _price, uint256 _pricePrecision) {
        if (_token == address(0)) revert InvalidAddress();
        if (_price == 0) revert InvalidPrice();
        if (_pricePrecision == 0) revert InvalidPricePrecision();
        TOKEN = _token;
        PRICE = _price;
        PRICE_PRECISION = _pricePrecision;
    }

    /// @notice Gets the price and price precision of the supported token
    /// @param _token Address of the desired token
    /// @return (uint256, uint256) The token's price and its price precision
    /// @dev Same signature as ChainlinkOracle.getTokenPrice so MasterPriceOracle msgData stays identical
    function getTokenPrice(address _token) external view returns (uint256, uint256) {
        if (_token != TOKEN) revert TokenNotSupported(_token);
        return (PRICE, PRICE_PRECISION);
    }
}
