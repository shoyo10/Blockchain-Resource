// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "forge-std/Test.sol";
import { CErc20 } from "compound-protocol/contracts/CErc20.sol";
import { EIP20Interface } from "compound-protocol/contracts/EIP20Interface.sol";
import { Unitroller } from "compound-protocol/contracts/Unitroller.sol";
import { Comptroller } from "compound-protocol/contracts/Comptroller.sol";
import { ComptrollerInterface } from "compound-protocol/contracts/ComptrollerInterface.sol";
import { SimplePriceOracle } from "compound-protocol/contracts/SimplePriceOracle.sol";
import { CErc20Delegate } from "compound-protocol/contracts/CErc20Delegate.sol";
import { CErc20Delegator } from "compound-protocol/contracts/CErc20Delegator.sol";
import { CToken } from "compound-protocol/contracts/CToken.sol";
import { WhitePaperInterestRateModel } from "compound-protocol/contracts/WhitePaperInterestRateModel.sol";
import { InterestRateModel } from "compound-protocol/contracts/InterestRateModel.sol";
import { CTokenInterface } from "compound-protocol/contracts/CTokenInterfaces.sol";
import {ERC20} from "openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import {
  IFlashLoanSimpleReceiver,
  IPoolAddressesProvider,
  IPool
} from "aave-v3-core/contracts/flashloan/interfaces/IFlashLoanSimpleReceiver.sol";
import { ISwapRouter } from 'v3-periphery/interfaces/ISwapRouter.sol';
import { TransferHelper } from  'v3-periphery/libraries/TransferHelper.sol';

contract CompoundAAVEFlashloan is Test, IFlashLoanSimpleReceiver {
    address public USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public UNI = 0x1f9840a85d5aF5bf1D1762F925BDADdC4201F984;

    address constant AAVE_POOL_ADDRESSES_PROVIDER = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    
    Unitroller public unitroller;
    Comptroller public comptroller;
    SimplePriceOracle public priceOracle;
    CErc20Delegate public cUSDCDelegate;
    CErc20Delegator public cUSDCDelegator;
    CErc20Delegate public cUNICDelegate;
    CErc20Delegator public cUNIDelegator;
    WhitePaperInterestRateModel public cUSDCInterestRateModel;
    WhitePaperInterestRateModel public cUNICInterestRateModel;

    constructor() {
        unitroller = new Unitroller();
        comptroller = new Comptroller();
        priceOracle = new SimplePriceOracle();
        (uint success) = comptroller._setPriceOracle(priceOracle);
        require(success == 0, "_setPriceOracle failed");

        (success) = unitroller._setPendingImplementation(address(comptroller));
        require(success == 0, "_setPendingImplementation failed");
        comptroller._become(unitroller);

        cUSDCInterestRateModel = new WhitePaperInterestRateModel(0, 0);
        cUSDCDelegate = new CErc20Delegate();
        cUSDCDelegator = new CErc20Delegator(
            USDC,
            ComptrollerInterface(comptroller),
            InterestRateModel(cUSDCInterestRateModel),
            1e18,
            "cUSDC",
            "cUSDC",
            18,
            payable(msg.sender),
            address(cUSDCDelegate),
            bytes("")
        );

        cUNICInterestRateModel = new WhitePaperInterestRateModel(0, 0);
        cUNICDelegate = new CErc20Delegate();
        cUNIDelegator = new CErc20Delegator(
            UNI,
            ComptrollerInterface(comptroller),
            InterestRateModel(cUNICInterestRateModel),
            1e18,
            "cUNI",
            "cUNI",
            18,
            payable(msg.sender),
            address(cUNICDelegate),
            bytes("")
        );

        (success) = comptroller._supportMarket(CToken(address(cUSDCDelegator)));
        require(success == 0, "cUSDC _supportMarket failed");
        (success) = comptroller._supportMarket(CToken(address(cUNIDelegator)));
        require(success == 0, "cUNI _supportMarket failed");

        priceOracle.setUnderlyingPrice(CToken(address(cUSDCDelegator)), 1*10**30);
        priceOracle.setUnderlyingPrice(CToken(address(cUNIDelegator)), 5*10**18);

        comptroller._setCloseFactor(0.5e18);
        comptroller._setLiquidationIncentive(1.08e18);
        comptroller._setCollateralFactor(CToken(address(cUNIDelegator)), 0.5*10**18);
    }

    function updateUNIPrice(uint price) public {
        priceOracle.setUnderlyingPrice(CToken(address(cUNIDelegator)), price);
    }

    function execute(address borrower, uint256 repayAmount) external {
        bytes memory params = abi.encode(msg.sender, borrower, repayAmount);
        POOL().flashLoanSimple(address(this), USDC, repayAmount, params, 0);
    }

    function executeOperation(
        address asset,
        uint256 amount,
        uint256 premium,
        address initiator,
        bytes calldata params
    ) external returns (bool) {
        (address receiver, address borrower, uint256 repayAmount) = abi.decode(params, (address, address, uint256));
        // 避免 stack too deep issue
        {
            (uint success, uint liquidity, uint shortfall) = comptroller.getAccountLiquidity(borrower);
            require(success == 0, "getAccountLiquidity failed");
            require(shortfall > 0, "account is not underwater");
        }

        ERC20(asset).approve(address(cUSDCDelegator), repayAmount);

        // 償還 borrower 債務
        (uint success) = cUSDCDelegator.liquidateBorrow(
            borrower, 
            repayAmount, CTokenInterface(address(cUNIDelegator)));
        require(success == 0, "liquidateBorrow failed");
        // redeem cUNI
        (success) = cUNIDelegator.redeem(cUNIDelegator.balanceOf(address(this)));
        require(success == 0, "redeem failed");

        ISwapRouter swapRouter = ISwapRouter(0xE592427A0AEce92De3Edee1F18E0157C05861564);
        TransferHelper.safeApprove(UNI, address(swapRouter), ERC20(UNI).balanceOf(address(this)));
        ISwapRouter.ExactInputSingleParams memory swapParams =
            ISwapRouter.ExactInputSingleParams({
                tokenIn: UNI,
                tokenOut: USDC,
                fee: 3000, // 0.3%
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: ERC20(UNI).balanceOf(address(this)),
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
        
        uint256 amountOut = swapRouter.exactInputSingle(swapParams);
        uint256 needReturn = amount + premium;
        ERC20(USDC).transfer(receiver, ERC20(USDC).balanceOf(address(this)) - needReturn);

        ERC20(asset).approve(address(POOL()), needReturn);

        return true;
    }

    function ADDRESSES_PROVIDER() public view returns (IPoolAddressesProvider) {
        return IPoolAddressesProvider(AAVE_POOL_ADDRESSES_PROVIDER);
    }

    function POOL() public view returns (IPool) {
        return IPool(ADDRESSES_PROVIDER().getPool());
    }
}