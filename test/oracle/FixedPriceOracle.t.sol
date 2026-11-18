// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.19;

import {Test} from "forge-std/Test.sol";
import {FixedPriceOracle} from "../../contracts/oracle/FixedPriceOracle.sol";
import {MasterPriceOracle} from "../../contracts/oracle/MasterPriceOracle.sol";
import {IOracle} from "../../contracts/interfaces/IOracle.sol";

contract FixedPriceOracleTest is Test {
    address constant LUSD = 0x93b346b6BC2548dA6A1E7d98E9a421B42541425b;
    address constant OTHER = 0xFF970A61A04b1cA14834A43f5dE4533eBDDB5CC8;
    uint256 constant PRICE = 1e8;
    uint256 constant PRECISION = 1e8;

    FixedPriceOracle oracle;

    function setUp() public {
        oracle = new FixedPriceOracle(LUSD, PRICE, PRECISION);
    }

    function test_Constructor() public {
        assertEq(oracle.TOKEN(), LUSD);
        assertEq(oracle.PRICE(), PRICE);
        assertEq(oracle.PRICE_PRECISION(), PRECISION);
    }

    function test_RevertWhen_ZeroToken() public {
        vm.expectRevert(FixedPriceOracle.InvalidAddress.selector);
        new FixedPriceOracle(address(0), PRICE, PRECISION);
    }

    function test_RevertWhen_ZeroPrice() public {
        vm.expectRevert(FixedPriceOracle.InvalidPrice.selector);
        new FixedPriceOracle(LUSD, 0, PRECISION);
    }

    function test_RevertWhen_ZeroPrecision() public {
        vm.expectRevert(FixedPriceOracle.InvalidPricePrecision.selector);
        new FixedPriceOracle(LUSD, PRICE, 0);
    }

    function test_GetTokenPrice() public {
        (uint256 price, uint256 precision) = oracle.getTokenPrice(LUSD);
        assertEq(price, PRICE);
        assertEq(precision, PRECISION);
    }

    function test_RevertWhen_OtherToken() public {
        vm.expectRevert(abi.encodeWithSelector(FixedPriceOracle.TokenNotSupported.selector, OTHER));
        oracle.getTokenPrice(OTHER);
    }

    function testFuzz_GetTokenPrice(address token, uint256 price, uint256 precision) public {
        vm.assume(token != address(0) && price != 0 && precision != 0);
        FixedPriceOracle o = new FixedPriceOracle(token, price, precision);
        (uint256 p, uint256 prec) = o.getTokenPrice(token);
        assertEq(p, price);
        assertEq(prec, precision);
    }

    // MasterPriceOracle accepts the oracle as a source with the same msgData shape as ChainlinkOracle
    function test_MasterPriceOracleIntegration() public {
        MasterPriceOracle master = new MasterPriceOracle();
        bytes memory data = abi.encodeWithSelector(FixedPriceOracle.getTokenPrice.selector, LUSD);
        master.updateTokenPriceFeed(LUSD, address(oracle), data);

        IOracle.PriceData memory pd = master.getPrice(LUSD);
        assertEq(pd.price, PRICE);
        assertEq(pd.precision, PRECISION);
        assertTrue(master.priceFeedExists(LUSD));
    }

    function test_RevertWhen_MasterPriceOracleMsgDataForOtherToken() public {
        MasterPriceOracle master = new MasterPriceOracle();
        bytes memory data = abi.encodeWithSelector(FixedPriceOracle.getTokenPrice.selector, OTHER);
        vm.expectRevert(abi.encodeWithSelector(MasterPriceOracle.UnableToFetchPriceFeed.selector, OTHER));
        master.updateTokenPriceFeed(OTHER, address(oracle), data);
    }
}
