//SPDX-license-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";


contract GasPriceFeesHook is BaseHook {

    using LPFeeLibrary for uint24;
 
    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAverageGasPriceCount;
 
    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // 0.5%
 
    error MustUseDynamicFee();
    constructor(IPoolManager _manager) BaseHook(_manager) {
        updateMovingAverage();
    }

    // 3 Hooks in use beforeSwap, AfterSwap, beforeInitialize
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        // TODO: Only for those pools that have the dynamic lpfee applicable
        // `.isDynamicFee()` function comes from using
        // the `LPFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);
    
        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) /
            (movingAverageGasPriceCount + 1);
    
        movingAverageGasPriceCount++;
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    //Here the uint24 is the FEE_Override aka, the swap fees charged for the swap 
    //It is a ephemeral update, only applies for the single swap.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns ( bytes4, BeforeSwapDelta, uint24)
    {
        // TODO: Giving the swap fees to the user making the swap comparing the gas pice with the moving average 
        uint24 fee = getFee();
        // Case1: If we wanted to generally update LP fee for a longer-term than per-swap
        // Permanent Change untill the next time you update it.
        // poolManager.updateDynamicLPFee(key, fee);

        // Masked fees inorder to solve the ambiguity problem of specifying no change in the override fees
        // So for no change the maskedFee / feewithFlag will be literally be 0, as no change with the bitmasking function 
        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;

        //  Note: Override Fee Flag in its binary representation is equal to all 0's just the 23rd bit is 1
        return (
            this.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            feeWithFlag
        );
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);
    
        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }
    
        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }
    
        return BASE_FEE;
    }
}

