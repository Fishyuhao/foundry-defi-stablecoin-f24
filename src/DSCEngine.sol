// SPDX-License-Identifier: MIT

import {DecentralizedStableCoin} from "./DecentralizedStableCoin.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

import {console} from "forge-std/console.sol";

pragma solidity ^0.8.18;

contract DSCEngine is ReentrancyGuard {
    error DSCEngine_NeedsMoreThanZero();
    error DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
    error DSCEngine_NotAllowedToken();
    error DSCEngine_TransferFailed();
    error DSCEngine_BreaksHealthFactor(uint256 healthFactor);
    error DSCEngine_MintFailed();
    error DSCEngine_HealthFactorOk();
    error DSCEngine_HealthFactorNotImproved();

    //各个代币地址对应的价格预言机地址
    mapping(address token => address priceFeed) private s_priceFeeds;
    mapping(address user => mapping(address token => uint256 amount)) private s_collateralDeposited;
    mapping(address user => uint256 amountDscMinted) private s_DSCMinted;
    //所有被允许的抵押品的地址列表
    address[] private s_collateralTokens;

    DecentralizedStableCoin private immutable i_dsc;
    uint256 private constant ADDITIONAL_FEED_PRECISION = 1e10; //调整预言机价格的精度
    uint256 private constant PRECISION = 1e18;
    uint256 private constant LIQUIDATION_THRESHOLD = 50; //清算阈值
    uint256 private constant LIQUIDATION_PRECISION = 100; //清算精度
    uint256 private constant MIN_HEALTH_FACTOR = 1e18;
    uint256 private constant LIQUIDATION_BONUS = 10;

    event CollateralDeposited(address indexed user, address indexed token, uint256 indexed amount);
    event CollateralRedeemed(
        address indexed redeemedFrom, address indexed redeemedTo, address indexed token, uint256 amount
    );

    /**
     * 确保存入的数量大于零
     */
    modifier moreThanZero(uint256 amount) {
        if (amount == 0) {
            revert DSCEngine_NeedsMoreThanZero();
        }
        _;
    }

    /**
     * 确保存入的代币地址在允许列表中
     */
    modifier isAllowedToken(address token) {
        //检查代币是否在价格预言机映射中存在
        if (s_priceFeeds[token] == address(0)) {
            revert DSCEngine_NotAllowedToken();
        }
        _;
    }

    /**
     * 初始化参数 --已测试
     * @param tokenAddresses 代币地址列表
     * @param priceFeedAddresses 价格预言机地址列表
     * @param dscAddress 传入的 DecentralizedStableCoin 合约地址
     */
    constructor(address[] memory tokenAddresses, address[] memory priceFeedAddresses, address dscAddress) {
        if (tokenAddresses.length != priceFeedAddresses.length) {
            revert DSCEngine_TokenAddressesAndPriceFeedAddressesMustBeSameLength();
        }
        //将代币地址和对应的价格预言机地址关联存储到 s_priceFeeds 映射中
        for (uint256 i = 0; i < tokenAddresses.length; i++) {
            s_priceFeeds[tokenAddresses[i]] = priceFeedAddresses[i];
            //记录所有被允许的抵押代币
            s_collateralTokens.push(tokenAddresses[i]);
        }
        //初始化 DecentralizedStableCoin 合约实例
        i_dsc = DecentralizedStableCoin(dscAddress);
    }

    /**
     * 存入抵押品 并铸造DSC
     * @param tokenCollateralAddress 要存入的代币地址
     * @param amountCollateral 存入的抵押品数量
     * @param amountDscToMint 需要铸造的DSC数量
     */
    function depositCollateralAndMintDsc(
        address tokenCollateralAddress,
        uint256 amountCollateral,
        uint256 amountDscToMint
    ) external {
        depositCollateral(tokenCollateralAddress, amountCollateral);
        mintDsc(amountDscToMint);
    }

    /**
     * 用户用 DSC（去中心化稳定币）赎回抵押品
     * @param tokenCollateralAddress 抵押代币地址
     * @param amountCollateral 需要赎回的抵押品数量
     * @param amountDscToBurn 需要燃烧的 DSC 数量
     */
    function redeemCollateralForDsc(address tokenCollateralAddress, uint256 amountCollateral, uint256 amountDscToBurn)
        external
    {
        //调用 burnDsc 方法，燃烧指定数量的 DSC
        burnDsc(amountDscToBurn);
        //赎回指定数量的抵押品
        redeemCollateral(tokenCollateralAddress, amountCollateral);
    }

    //已测试
    function getAccountInformation(address user)
        external
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        (totalDscMinted, collateralValueInUsd) = _getAccountInformation(user);
    }

    function getCollateralTokens() external view returns (address[] memory) {
        return s_collateralTokens;
    }

    function getCollateralBalanceOfUser(address user, address token) external view returns (uint256) {
        return s_collateralDeposited[user][token];
    }

    /**
     * 允许用户将抵押品存入合约，并更新抵押品余额 --已测试
     * @param tokenCollateralAddress 要存入的代币地址
     * @param amountCollateral 存入的数量
     */
    function depositCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        isAllowedToken(tokenCollateralAddress)
        nonReentrant
    {
        //更新用户在指定代币上的抵押品余额，a+=b:a=a+b
        s_collateralDeposited[msg.sender][tokenCollateralAddress] += amountCollateral;
        //记录用户、代币地址和存入数量
        emit CollateralDeposited(msg.sender, tokenCollateralAddress, amountCollateral);
        //调用代币合约的 transferFrom 函数，将用户的代币转移到当前合约地址
        bool success = IERC20(tokenCollateralAddress).transferFrom(msg.sender, address(this), amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    /**
     * 用户从合约中赎回一定数量的抵押品
     * @param tokenCollateralAddress 抵押代币地址
     * @param amountCollateral 需要赎回的抵押品数量
     */
    function redeemCollateral(address tokenCollateralAddress, uint256 amountCollateral)
        public
        moreThanZero(amountCollateral)
        nonReentrant
    {
        _redeemCollateral(msg.sender, msg.sender, tokenCollateralAddress, amountCollateral);
        //检查用户的健康因子，确保赎回操作不会破坏用户的健康因子
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    /**
     * 由所有者（或授权的用户）铸造 DSC（Decentralized Stable Coin）
     * @param amountDscToMint 是要铸造的 DSC 数量
     */
    function mintDsc(uint256 amountDscToMint) public moreThanZero(amountDscToMint) nonReentrant {
        //增加用户持有的 DSC 数量
        s_DSCMinted[msg.sender] += amountDscToMint;
        _revertIfHealthFactorIsBroken(msg.sender);
        bool minted = i_dsc.mint(msg.sender, amountDscToMint);
        if (!minted) {
            revert DSCEngine_MintFailed();
        }
    }

    /**
     * 燃烧用户持有的 DSC
     * @param amount 需要燃烧的 DSC 数量
     */
    function burnDsc(uint256 amount) public moreThanZero(amount) {
        _burnDsc(amount, msg.sender, msg.sender);
        //健康因子检查，确保燃烧操作不会破坏用户的健康因子
        _revertIfHealthFactorIsBroken(msg.sender); // I don't think this would ever hit
    }

    /**
     * 将给定的 USD 数量（以 Wei 为单位）转换为指定代币的数量 --已测试
     * price=USD除以ETH=2000*1e8
     * @param token 要转换的代币地址
     * @param usdAmountInWei 要转换的 USD 数量（以 Wei 为单位）
     */
    function getTokenAmountFromUsd(address token, uint256 usdAmountInWei) public view returns (uint256) {
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return (usdAmountInWei * PRECISION) / (uint256(price) * ADDITIONAL_FEED_PRECISION);
    }
    //计算用户在 USD 价值中的所有抵押品的总价值

    function getAccountCollateralValue(address user) public view returns (uint256 totalCollateralValueInUsd) {
        for (uint256 i = 0; i < s_collateralTokens.length; i++) {
            address token = s_collateralTokens[i];
            //获取用户在该抵押品上的抵押量
            uint256 amount = s_collateralDeposited[user][token];
            //调用函数计算抵押品的 USD 价值，并累加到 totalCollateralValueInUsd。
            totalCollateralValueInUsd += getUsdValue(token, amount);
        }
        return totalCollateralValueInUsd;
    }

    /**
     * 计算代币在 USD 价值中的总价值 --已测试
     * 假设预言机返回的price为20000000000（20 USD，相当于价格精度为 1e8）
     * ((20000000000 * 1e10) * 1000) / 1e18
     * 200000 USD
     * 因此，1000 个代币在当前价格下的 USD 价值为 20000 美元
     * @param token 代币的地址
     * @param amount 代币的数量
     */
    function getUsdValue(address token, uint256 amount) public view returns (uint256) {
        //获取价格预言机
        AggregatorV3Interface priceFeed = AggregatorV3Interface(s_priceFeeds[token]);
        (, int256 price,,,) = priceFeed.latestRoundData();
        return ((uint256(price) * ADDITIONAL_FEED_PRECISION) * amount) / PRECISION;
    }

    /**
     * 对健康因子（健康比率）不足的用户进行清算
     * 清算者可以覆盖用户部分的债务（debtToCover），并以折扣价获取用户的抵押品
     * @param collateral 抵押品的代币地址
     * @param user 要清算的用户地址
     * @param debtToCover 要覆盖的债务量（以 USD 为单位）
     */
    function liquidate(address collateral, address user, uint256 debtToCover)
        public
        moreThanZero(debtToCover)
        nonReentrant
    {
        //检查用户的健康因子是否小于 MIN_HEALTH_FACTOR，如果大于等于MIN_HEALTH_FACTOR则不用清算
        uint256 startingUserHealthFactor = _healthFactor(user);
        if (startingUserHealthFactor >= MIN_HEALTH_FACTOR) {
            revert DSCEngine_HealthFactorOk();
        }
        //计算 debtToCover 对应的抵押品数量，比如计算usd相对于eth的数量
        uint256 tokenAmountFromDebtCovered = getTokenAmountFromUsd(collateral, debtToCover);
        //计算清算奖励 bonusCollateral（清算者会得到一定比例的额外奖励）(0.25*10)/100=0.025ETH
        uint256 bonusCollateral = (tokenAmountFromDebtCovered * LIQUIDATION_BONUS) / LIQUIDATION_PRECISION;
        //计算总的要赎回的抵押品数量
        uint256 totalCollateralToRedeem = tokenAmountFromDebtCovered + bonusCollateral;
        _redeemCollateral(user, msg.sender, collateral, totalCollateralToRedeem);
        _burnDsc(debtToCover, user, msg.sender);
        uint256 endingUserHealthFactor = _healthFactor(user);
        if (endingUserHealthFactor <= startingUserHealthFactor) {
            revert DSCEngine_HealthFactorNotImproved();
        }
        _revertIfHealthFactorIsBroken(msg.sender);
    }

    function _redeemCollateral(address from, address to, address tokenCollateralAddress, uint256 amountCollateral)
        private
    {
        //减少用户在指定代币上的抵押品余额a-=b:a=a-b
        s_collateralDeposited[from][tokenCollateralAddress] -= amountCollateral;
        //触发事件: 记录赎回操作
        emit CollateralRedeemed(from, to, tokenCollateralAddress, amountCollateral);
        //使用 IERC20 接口的 transfer 方法，将用户从合约中赎回的抵押品转移到用户的账户
        bool success = IERC20(tokenCollateralAddress).transfer(to, amountCollateral);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
    }

    function _burnDsc(uint256 amountDscToBurn, address onBehalfOf, address dscFrom) private {
        //减少用户持有的 DSC 数量
        s_DSCMinted[onBehalfOf] -= amountDscToBurn;
        //使用 i_dsc 合约的 transferFrom 方法将 DSC 从用户账户转移到合约账户
        bool success = i_dsc.transferFrom(dscFrom, address(this), amountDscToBurn);
        if (!success) {
            revert DSCEngine_TransferFailed();
        }
        //使用 i_dsc 合约的 burn 方法燃烧指定数量的 DSC
        i_dsc.burn(amountDscToBurn);
    }

    /**
     *
     * @param user 获取用户的总 DSC 铸造量和抵押品价值
     * @return totalDscMinted
     * @return collateralValueInUsd
     */
    function _getAccountInformation(address user)
        private
        view
        returns (uint256 totalDscMinted, uint256 collateralValueInUsd)
    {
        //用户的总 DSC 铸造量
        totalDscMinted = s_DSCMinted[user];
        //抵押品价值
        collateralValueInUsd = getAccountCollateralValue(user);
    }
    /**
     * 计算用户的健康因子（用户抵押品价值相对于他们借入的债务的比率）
     * 调整后的抵押品价值：$1000 * 50 / 100 = $500
     * 健康因子：$500 / $500 = 1
     * 如果健康因子小于 1，用户可能会面临清算
     * @param user 用户地址
     */

    function _healthFactor(address user) private view returns (uint256) {
        (uint256 totalDscMinted, uint256 collateralValueInUsd) = _getAccountInformation(user);
        //将抵押品价值乘以清算阈值，再除以清算精度，以得到调整后的抵押品价值
        uint256 collateralAdjustedForThreshold = (collateralValueInUsd * LIQUIDATION_THRESHOLD) / LIQUIDATION_PRECISION;
        return (collateralAdjustedForThreshold * PRECISION) / totalDscMinted;
    }

    /**
     * 如果健康因子低于 MIN_HEALTH_FACTOR（通常为 1），则抛出 DSCEngine_BreaksHealthFactor 错误，仅限当前合约和继承自当前合约的合约可访问
     * @param user 用户地址
     */
    function _revertIfHealthFactorIsBroken(address user) internal view {
        uint256 healthFactor = _healthFactor(user);
        if (healthFactor < MIN_HEALTH_FACTOR) {
            revert DSCEngine_BreaksHealthFactor(healthFactor);
        }
    }
}
