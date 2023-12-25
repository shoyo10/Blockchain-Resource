// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { MyCompoundSetUp } from "./helper/MyCompoundSetUp.sol";
import { MyERC20 } from "../src/MyERC20.sol";
import { CErc20Delegate } from "compound-protocol/contracts/CErc20Delegate.sol";
import { CErc20Delegator } from "compound-protocol/contracts/CErc20Delegator.sol";
import { WhitePaperInterestRateModel } from "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import { InterestRateModel } from "compound-protocol/contracts/InterestRateModel.sol";
import { CToken } from "compound-protocol/contracts/CToken.sol";
import { ComptrollerInterface } from "compound-protocol/contracts/ComptrollerInterface.sol";
import { CTokenInterface } from "compound-protocol/contracts/CTokenInterfaces.sol";
import { CompoundAAVEFlashloan } from "../src/CompoundAAVEFlashloan.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract MyCompoundTest is MyCompoundSetUp {
    address public user1;
    address public user2;

    MyERC20 public tokenB;
    CErc20Delegate public cTokenBDelegate;
    CErc20Delegator public cTokenBDelegator;
    WhitePaperInterestRateModel public tokenBInterestRateModel;

    function setUp() public override {
        super.setUp();

        user1 = payable(makeAddr("user1"));
        user2 = payable(makeAddr("user2"));

        vm.startPrank(admin);
        tokenB = new MyERC20("tokenB", "TB", 18);
        cTokenBDelegate = new CErc20Delegate();
        tokenBInterestRateModel = new WhitePaperInterestRateModel(0, 0);
        cTokenBDelegator = new CErc20Delegator(
            address(tokenB),
            ComptrollerInterface(comptroller),
            InterestRateModel(tokenBInterestRateModel),
            1e18,
            "cTokenB",
            "cTB",
            18,
            admin,
            address(cTokenBDelegate),
            bytes("")
        );

        (uint success) = comptroller._supportMarket(CToken(address(cTokenBDelegator)));
        require(success == 0, "_supportMarket failed");

        priceOracle.setUnderlyingPrice(CToken(address(cERC20Delegator)), 1*10**18);
        priceOracle.setUnderlyingPrice(CToken(address(cTokenBDelegator)), 100*10**18);

        vm.stopPrank();

        vm.label(address(tokenB), "tokenB");
        vm.label(address(cTokenBDelegate), "cTokenBDelegate");
        vm.label(address(cTokenBDelegator), "cTokenBDelegator");
    }

    function test_mint_redeem() public {
        uint256 initialBalance = 100 * 10 ** underlyingToken.decimals();
        deal(address(underlyingToken), user1, initialBalance);

        vm.startPrank(user1);

        // test a user mint cToken
        underlyingToken.approve(address(cERC20Delegator), initialBalance);
        uint256 supplyMarket = 100 * 10 ** underlyingToken.decimals();
        (uint success) = cERC20Delegator.mint(supplyMarket);
        assertEq(success, 0);
        assertEq(underlyingToken.balanceOf(user1) == initialBalance-supplyMarket, true);
        assertEq(cERC20Delegator.balanceOf(user1) == supplyMarket, true);

        // test a user redeem cToken
        (success) = cERC20Delegator.redeem(supplyMarket);
        assertEq(success, 0);
        assertEq(underlyingToken.balanceOf(user1) == supplyMarket, true);
        assertEq(cERC20Delegator.balanceOf(user1) == 0, true);

        vm.stopPrank();
    }

    function test_borrow_repay() public {
       borrow();

       (uint borrowAmount) = cERC20Delegator.borrowBalanceCurrent(user1);
        assertGt(borrowAmount, 0);

        vm.startPrank(user1);
        underlyingToken.approve(address(cERC20Delegator), borrowAmount);
        (uint success) = cERC20Delegator.repayBorrow(borrowAmount);
        assertEq(success, 0);
        vm.stopPrank();

        (borrowAmount) = cERC20Delegator.borrowBalanceCurrent(user1);
        assertEq(borrowAmount, 0);
    }

    function test_liquidition_by_adjust_collateral_factor() public {
        borrow();

        vm.startPrank(admin);
        comptroller._setCollateralFactor(CToken(address(cTokenBDelegator)), 0.4*10**18);
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.1e18);
        vm.stopPrank();

        (uint success, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(user1);
        assertEq(success, 0);
        assertGt(shortfall, 0);
        
        // user2 幫 user1 償還債務，user1 的債務為 50 顆 underlyingToken，close factor 為 0.5，所以 user2 可幫償還 25 顆 underlyingToken
        vm.startPrank(user2);
        uint256 user2BeforeLiquidateUnderlyingTokenBalance = underlyingToken.balanceOf(user2);
        uint repayBorrowAmount = 25 * 10 ** underlyingToken.decimals();
        (success) = cERC20Delegator.liquidateBorrow(
            user1, 
            repayBorrowAmount, CTokenInterface(address(cTokenBDelegator)));
        assertEq(success, 0);
        assertEq(underlyingToken.balanceOf(user2), user2BeforeLiquidateUnderlyingTokenBalance-repayBorrowAmount);
        assertGt(cTokenBDelegator.balanceOf(user2), 0);
        vm.stopPrank();

        (success, liquidity, shortfall) = comptroller.getAccountLiquidity(user1);
        assertEq(success, 0);
        assertGt(liquidity, 0);
    }

    function test_liquidition_by_adjust_oracle_price() public {
        borrow();

        vm.startPrank(admin);
        priceOracle.setUnderlyingPrice(CToken(address(cTokenBDelegator)), 80*10**18);
        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.1e18);
        vm.stopPrank();

        (uint success, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(user1);
        assertEq(success, 0);
        assertGt(shortfall, 0);
        
        // user2 幫 user1 償還債務，user1 的債務為 50 顆 underlyingToken，close factor 為 0.5，所以 user2 可幫償還 25 顆 underlyingToken
        vm.startPrank(user2);
        uint256 user2BeforeLiquidateUnderlyingTokenBalance = underlyingToken.balanceOf(user2);
        uint repayBorrowAmount = 25 * 10 ** underlyingToken.decimals();
        (success) = cERC20Delegator.liquidateBorrow(
            user1, 
            repayBorrowAmount, CTokenInterface(address(cTokenBDelegator)));
        assertEq(success, 0);
        assertEq(underlyingToken.balanceOf(user2), user2BeforeLiquidateUnderlyingTokenBalance-repayBorrowAmount);
        assertGt(cTokenBDelegator.balanceOf(user2), 0);
        vm.stopPrank();
        
        (success, liquidity, shortfall) = comptroller.getAccountLiquidity(user1);
        assertEq(success, 0);
        assertGt(liquidity, 0);
    }

    function test_aave_flashloan() public {
        address USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        address UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;
        // Fork Ethereum mainnet at block 17465000
        string memory rpc = vm.envString("MAINNET_RPC_URL");
        vm.createSelectFork(rpc, 17465000);

        CompoundAAVEFlashloan compoundAAVEFlashloan = new CompoundAAVEFlashloan();

        // 先讓 user2 抵押 USDC, 這樣後面 user1 才能借 USDC
        uint256 user2InitialBalance = 2500 * 10 ** 6;
        deal(compoundAAVEFlashloan.USDC(), user2, user2InitialBalance);
        vm.startPrank(user2);
        (bool success, ) =
            compoundAAVEFlashloan.USDC().call(
                abi.encodeWithSignature("approve(address,uint256)", address(compoundAAVEFlashloan.cUSDCDelegator()), user2InitialBalance)
                );
        require(success, "Approve failed");
        (uint ok) = compoundAAVEFlashloan.cUSDCDelegator().mint(user2InitialBalance);
        require(ok == 0, "Mint failed");
        vm.stopPrank();

        // user1 抵押 UNI, 借 USDC
        vm.startPrank(user1);
        uint256 mintAmount = 1000 * 10 ** ERC20(compoundAAVEFlashloan.UNI()).decimals();
        uint256 borrowAmount = 2500 * 10 ** 6;

        deal(compoundAAVEFlashloan.UNI(), user1, mintAmount);
        (success, ) =
            compoundAAVEFlashloan.UNI().call(
                abi.encodeWithSignature("approve(address,uint256)", address(compoundAAVEFlashloan.cUNIDelegator()), mintAmount)
                );
        require(success, "Approve failed");

        (ok) = compoundAAVEFlashloan.cUNIDelegator().mint(mintAmount);
        require(ok == 0, "Mint failed");

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(compoundAAVEFlashloan.cUNIDelegator());
        compoundAAVEFlashloan.comptroller().enterMarkets(cTokens);
        // user1 借 USDC
        compoundAAVEFlashloan.cUSDCDelegator().borrow(borrowAmount);
        vm.stopPrank();

        // update UNI price
        compoundAAVEFlashloan.updateUNIPrice(4*10**18);

        // user2 幫 user1 償還債務，user1 的債務為 2500 USDC，close factor 為 0.5，所以 user2 可幫償還 1250 USDC
        vm.startPrank(user2);
        compoundAAVEFlashloan.execute(user1, 1250 * 10 ** 6);
        vm.stopPrank();
        // 測試結果可得 63.638693 顆USDC
        console.log("user2 USDC balance: %s", ERC20(compoundAAVEFlashloan.USDC()).balanceOf(user2));        
    }

    function borrow() public {
        vm.startPrank(admin);
        comptroller._setCollateralFactor(CToken(address(cTokenBDelegator)), 0.5*10**18);
        vm.stopPrank();

        uint256 user2InitialBalance = 200 * 10 ** underlyingToken.decimals();
        deal(address(underlyingToken), user2, user2InitialBalance);

        vm.startPrank(user2);
        underlyingToken.approve(address(cERC20Delegator), user2InitialBalance);
        uint256 user2supplyMarket = 100 * 10 ** underlyingToken.decimals();
        (uint success) = cERC20Delegator.mint(user2supplyMarket);
        assertEq(success, 0);
        vm.stopPrank();

        uint256 initialBalance = 1 * 10 ** tokenB.decimals();
        deal(address(tokenB), user1, initialBalance);

        // user1 抵押了 1 個 tokenB，借了 50 個 underlyingToken
        vm.startPrank(user1);

        tokenB.approve(address(cTokenBDelegator), 1000 * 10 ** tokenB.decimals());
        uint256 supplyMarket = 1 * 10 ** tokenB.decimals();
        (success) = cTokenBDelegator.mint(supplyMarket);
        assertEq(success, 0);
        assertEq(cTokenBDelegator.balanceOf(user1) == supplyMarket, true);

        address[] memory cTokens = new address[](1);
        cTokens[0] = address(cTokenBDelegator);
        comptroller.enterMarkets(cTokens);

        (success) = cERC20Delegator.borrow(50*10**underlyingToken.decimals());
        assertEq(success, 0);

        vm.stopPrank();

        assertEq(underlyingToken.balanceOf(user1), 50*10**underlyingToken.decimals());
    }
}