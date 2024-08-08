//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Test, console} from "forge-std/Test.sol";
import {DeployDSC} from "../../script/DeployDSC.s.sol";
import {DecentralizedStableCoin} from "../../src/DecentralizedStableCoin.sol";
import {DSCEngine} from "../../src/DSCEngine.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {ERC20Mock} from "../mocks/ERC20Mock.sol";

contract DSCEngineTest is Test {
    DeployDSC deployer;
    DecentralizedStableCoin dsc;
    DSCEngine dsce;
    HelperConfig config;
    address ethUsdPriceFeed;
    address btcUsdPricceFeed;
    address weth;

    address public USER = makeAddr("user");
    uint256 public constant AMOUNT_COLLATERAL = 10 ether;
    uint256 public constant STARTING_ERC20_BALANCE = 10 ether;

    /**
     * 初始化测试环境，实例化 DeployDSC 合约，调用 deployer.run()
     * 部署 DecentralizedStableCoin 和 DSCEngine 合约，并获取配置
     * 从配置中提取 ethUsdPriceFeed 和 weth 地址
     */
    function setUp() public {
        deployer = new DeployDSC();
        (dsc, dsce, config) = deployer.run();
        (ethUsdPriceFeed, btcUsdPricceFeed, weth,,) = config.activeNetworkConfig();
        ERC20Mock(weth).mint(USER, STARTING_ERC20_BALANCE);
    }

    address[] public tokenAddresses;
    address[] public priceFeedAddresses;

    function testRevertsIfTokenLengthDoesntMatchPriceFeeds() public {
        //代币地址1个，喂价地址2个
        tokenAddresses.push(weth);
        priceFeedAddresses.push(ethUsdPriceFeed);
        priceFeedAddresses.push(btcUsdPricceFeed);
        //预期会抛出异常
        vm.expectRevert(DSCEngine.DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength.selector);
        new DSCEngine(tokenAddresses, priceFeedAddresses, address(dsc));
    }

    function testGetTokenAmountFromUsd() public view {
        uint256 usdAmount = 100 ether;
        // $2000/ETH, $100
        uint256 expectedWeth = 0.05 ether;
        console.log("usdAmount:", usdAmount);
        uint256 actualWeth = dsce.getTokenAmountFromUsd(weth, usdAmount);
        console.log("actualWeth:", actualWeth);
        assertEq(actualWeth, expectedWeth);
    }

    function testGetUsdValue() public view {
        //15 ETH（以wei为单位）
        uint256 ethAmount = 15e18;
        //以wei为单位，30000usd
        uint256 expectedUsd = 30000e18;
        uint256 usdValue = dsce.getUsdValue(weth, ethAmount);
        assertEq(usdValue, expectedUsd);
    }

    function testRevertsIfCollateralZero() public {
        vm.startPrank(USER);
        /**
         * 将 AMOUNT_COLLATERAL（这里为 10 ETH）的 WETH 代币批准给 DSCEngine 合约
         * 这样 DSCEngine 合约就可以代表 USER 花费这些代币
         */
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        /**
         * 指定了下一次合约调用预期会回退，并且回退的原因是 DSCEngine 合约中
         * 的错误 DSCEngine_NeedsMoreThanZero
         * DSCEngine_NeedsMoreThanZero.selector 获取的是该错误的选择器
         */
        vm.expectRevert(DSCEngine.DSCEngine_NeedsMoreThanZero.selector);
        //模拟 USER 调用 DSCEngine 合约的 depositCollateral 方法，试图存入 0 个 WETH 作为抵押品
        dsce.depositCollateral(weth, 0);
        vm.stopPrank();
    }

    //因为部署合约的时候，只有wethUsdPriceFeed和wbtcUsdPriceFeed，没有RAN的，所以回报错
    function testRevertsWithUnapprovedCollateral() public {
        ERC20Mock ranToken = new ERC20Mock("RAN", "RAN", USER, AMOUNT_COLLATERAL);
        vm.startPrank(USER);
        vm.expectRevert(DSCEngine.DSCEngine_NotAllowedToken.selector);
        dsce.depositCollateral(address(ranToken), AMOUNT_COLLATERAL);
        vm.stopPrank();
    }

    modifier depositedCollateral() {
        vm.startPrank(USER);
        ERC20Mock(weth).approve(address(dsce), AMOUNT_COLLATERAL);
        //将抵押品存入合约
        dsce.depositCollateral(weth, AMOUNT_COLLATERAL);
        vm.stopPrank();
        _;
    }

    function testCanDepositCollateralAndGetAccountInfo() public depositedCollateral {
        //获取用户的总 DSC 铸造量和抵押品价值
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = dsce.getAccountInformation(USER);
        uint256 expectedTotalDscMinted = 0;
        //将给定的 USD 数量（以 Wei 为单位）转换为指定代币的数量
        uint256 expectedDepositAmount = dsce.getTokenAmountFromUsd(weth, collateralValueInUsd);
        assertEq(totalDscMinted, expectedTotalDscMinted);
        assertEq(AMOUNT_COLLATERAL, expectedDepositAmount);
    }
}
