// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";

import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";

import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {ERC1155} from "solmate/src/tokens/ERC1155.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";


contract PointsHook is BaseHook, ERC1155 {
    constructor (IPoolManager _manager) BaseHook(_manager) {}    
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({ 
        beforeInitialize: false,
        afterInitialize: false,
        beforeAddLiquidity: false,
        afterAddLiquidity: false,
        beforeRemoveLiquidity: false,
        afterRemoveLiquidity: false,
        beforeSwap: false,
        afterSwap: true,
        beforeDonate: false,
        afterDonate: false,
        beforeSwapReturnDelta: false,
        afterSwapReturnDelta: false,
        afterAddLiquidityReturnDelta: false,
        afterRemoveLiquidityReturnDelta: false

        });
    }

    function uri(uint256) public view virtual override returns (string memory) {
        return "";
    }
    

    // From the BaseHook abstract contract
    // address sender <- Note 
    function _afterSwap(
        address, 
        PoolKey calldata key, 
        SwapParams calldata params, 
        BalanceDelta delta, 
        bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        // bytes4 return value for every hook function = the function selector itself 
        // Why ? ->  to signify the success of the call.
        // second value is related to the return delta hooks(to be studied later)

        // Workflow 
        /*
            1. make sure we are in a ETH/Token pool i.e ETh is one of the tokens in the pool
            2. Ensure that the swap from ETH -> Token is made, not the other way around
            3. Calculate the amount of eth spent, (balanceDelta) 
            4. minitng the points to the user
         */

        // 1. We check using the poolKey if the currencyZero is Eth
        // Eth = address(0), since it is the native cryptocurrency of ethereum
        // Note: In solidity the params for a function call are passed by param.function()
        // for a function(int param);
        if(!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);
        

        // 2. Direction of the swap using SwapParams
        // zeroForOne boolean  variable in it
        // "spending Token0 for token1" 
        // we want spend eth to get new token therefore true

        if(!params.zeroForOne) return (this.afterSwap.selector, 0); 

        // 3. Calculate the amount of eth spent using BalanceDelta
        /* 
        struct BalanceDelta {
            int128 amount0,
            int128 amount1,
        }
        All this is amount is user's wallet perspective 
        leaving the user's wallet => -ve
        entering the user's wallet => +ve
        Since its a zeroForOne swap:
            if amountSpecified < 0:
                this is an "exact input for output" swap
                amount of ETH they spent is equal to |amountSpecified|
            if amountSpecified > 0:
                this is an "exact output for input" swap
                amount of ETH they spent is equal to BalanceDelta.amount0()
         */
         // Note we can't directly convert int128 to uint256 
        uint256 amountEthSpent = uint256(int256(-delta.amount0()));
        
        uint256 pointsToGive = amountEthSpent / 5;
        
        // key.toId() from the PoolIdLibrary inside the PoolKey contract 
        _assignPoints(key.toId(), hookData, pointsToGive);
        
        return (this.afterSwap.selector, 0);
    }


    // Helper function to mint tokens to the user when it is time to assign points.
    function _assignPoints(
        PoolId poolId,
        bytes calldata hookData,
        uint256 points
    ) internal {
        // If no hookData was provided by the user
        if(hookData.length == 0) return;
        
        //Extracting the user address from the hookdata
        address user = abi.decode(hookData, (address)); 
        
        // Check for the validity of the decoded address by checking to zero address
        if(user == address(0)) return;

        //mint ERC-1155 token
        //PoolId = keccak(PoolKey)
        //we can type cast the bytes32 poolID to uint why ? -> inorder to be passed into the mint function 
        uint poolIDasuint = uint256(PoolId.unwrap(poolId));
        _mint(user, poolIDasuint, points, "");  
    }
}