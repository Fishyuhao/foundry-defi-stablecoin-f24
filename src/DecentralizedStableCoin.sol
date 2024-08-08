//SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {ERC20Burnable, ERC20} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title 管理和控制 DecentralizedStableCoin 合约的引擎合约。
 * 它负责执行与稳定币相关的核心逻辑，比如管理抵押品、铸造和销毁稳定币等
 * @author Chris
 * @notice
 */
contract DecentralizedStableCoin is ERC20Burnable, Ownable {
    error DecentralizedStableCoin__AmountMustBeMoreThanZero();
    error DecentralizedStableCoin__BurnAmountExceedsBalance();
    error DecentralizedStableCoin__NotZeroAddress();

    /**
     * 调用 ERC20 的构造函数，设置代币的名称为 "DecentralizedStableCoin"，代币符号为 "DSC"
     * 调用 Ownable 的构造函数，设置合约的所有者为 ownerAddress
     * @param ownerAddress 调用者地址
     */
    constructor(address ownerAddress) ERC20("DecentralizedStableCoin", "DSC") Ownable(ownerAddress) {}

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        //检查调用者的余额是否足够销毁_amount
        if (balance < _amount) {
            revert DecentralizedStableCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    /**
     * mint 函数允许合约所有者铸造指定数量的代币并发送到 _to 地址
     * @param _to 发送地址
     * @param _amount 代币数量
     */
    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DecentralizedStableCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DecentralizedStableCoin__AmountMustBeMoreThanZero();
        }
        //调用 _mint 函数铸造代币并发送到 _to 地址。
        _mint(_to, _amount);
        return true;
    }
}
