//SPDX-license-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";



contract TakeProfitsHook is BaseHook, ERC1155{
    // Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    using StateLibrary for IPoolManager;

    error NotEnoughToClaim();
    error NothingToClaim();

    constructor(
        IPoolManager _manager,
        string memory _uri
    ) BaseHook(_manager) ERC1155(_uri) {}
    
    function getHookPermissions() public pure override returns (Hooks.Permissions memory){
        return Hooks.Permissions({
        beforeInitialize: false,
        afterInitialize: true,
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

    // Functionalities:
    /* 1. Placing Orders
        2. Cancelling Orders
        3. Redeeming Output tokens
        4. Executing Orders
    */

    // ---------------- 1. Placing Orders -------------------
    // ------------------------------------------------------
    // ------------------------------------------------------
    // Helper Functions
    function getLowerUsableTick(
        int24 ticks,
        int24 tickSpacing
    ) internal pure returns (int24) {
        int24 interval = ticks / tickSpacing;

        // Since the tickSpacing is rounded down to the lowest feasible tick
        if(ticks < 0 && ticks % tickSpacing != 0) interval--;

        // The final tick = interval * tickspacing
        return interval * tickSpacing;
    }

    // Storing the orders in the mapping
    mapping(PoolId poolId =>
        mapping(int24 tickstoSellat => 
            mapping(bool zeroForOne => uint256 inputAmount)))
                public pendingOrders;

    //Storing the amount of claimTokens respect to the orderID
    mapping(uint256 orderId => uint256 claimsSupply)
        public claimTokensSupply;

    function getOrderId(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne
    ) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    // Main Placing Order Function 
    function placeOrder(
        PoolKey calldata key, 
        int24 ticktoSellAt,
        bool zeroForOne,
        uint256 inputAmount
    ) external returns (int24) {
        
        // Get the viable tick for placing order
        int24 tick =  getLowerUsableTick(ticktoSellAt, key.tickSpacing);
        // Add it to the pendingOrders to executed
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;
        
        // Mint claim tokens to user equal to their `inputAmount` based on the order id
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        claimTokensSupply[orderId] += inputAmount;
        _mint(msg.sender, orderId, inputAmount, "");
        
        // Depending on direction of swap, we select the proper input token
        address sellToken = zeroForOne 
            ? Currency.unwrap(key.currency0)
            : Currency.unwrap(key.currency1);
        // Inorder to get the address of the the currency being sold
        // and request a transfer of those tokens to the hook contract
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        return tick;
    }
    
    function cancelOrder(
        PoolKey calldata key,
        int24 tickToSellAt, 
        bool zeroForOne,
        uint256 amountToCancel
    ) external {
        // Get the lower viable tick
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);

        // Check if the amount asked is viable
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 positionTokens = balanceOf(msg.sender, orderId);
        if(positionTokens < amountToCancel) revert NotEnoughToClaim();

        // Remove the amtToCancel from pendingOrders and ClaimSupplyTokens
        pendingOrders[key.toId()][tickToSellAt][zeroForOne] -= amountToCancel;

        claimTokensSupply[orderId] -= amountToCancel;
        _burn(msg.sender, orderId, amountToCancel);
    

        // Give the tokens back from the contract to the user
        Currency Token = zeroForOne ? key.currency0 : key.currency1;
        
        Token.transfer(msg.sender, amountToCancel); 
    }

    //----------------- Reedem the Order once fulfilled ---------------------------
    // Storing the amount reedemed from the claim tokens
    mapping(uint256 orderId => uint256 outputClaimable)
        public claimableOutputTokens;

    function redeem(
        PoolKey calldata key,
        int24 tickToSellAt,
        bool zeroForOne,
        uint256 inputAmountToClaimFor
    ) external {
            // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 orderId = getOrderId(key, tick, zeroForOne);
    
        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[orderId] == 0) revert NothingToClaim();
 

        uint256 totalClaimableForPosition = claimableOutputTokens[orderId];
        uint256 totalInputAmountForPosition = claimTokensSupply[orderId];

        // Proportional Claiming of tokens
        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(
            totalClaimableForPosition,
            totalInputAmountForPosition
        );

            // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[orderId] -= outputAmount;
        claimTokensSupply[orderId] -= inputAmountToClaimFor;
        _burn(msg.sender, orderId, inputAmountToClaimFor);
    
        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }


    // ---------------- Executing Orders ----------------
    
// -------------------Helper Functions ----------------------
    // Note calldata is more efficien than memory 
    function swapAndSettleBalances(
        PoolKey calldata key,
        SwapParams memory params
    ) internal returns (BalanceDelta) {
        // Conduct the swap inside the Pool Manager
        BalanceDelta delta = poolManager.swap(key, params, "");
        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // Settle with PoolManager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }
            // Positive Value => Money coming into user's wallet
            // Take from PM
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }

            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
            }
            return delta;
    }

    //These terminologies are Tradfi terms 
    // SettleMent: When you give money to someone you owe money to
    // Take: When you take money from someone that owed you money
    // Here the someone is Uniswap
    function _settle(Currency currency, uint128 amount) internal {
        poolManager.sync(currency); // Tell the PM to check the current balance of 'currency' it owns
        currency.transfer(address(poolManager), amount); // send the currency 
        poolManager.settle();   // PM check if I settled all the 'currency' I owed you.
    }
    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        poolManager.take(currency, address(this), amount);
    }

// --------------------- Main Function ---------------------------
// The below function is performing the function that normally would be performed by 'swap router' 
    function executeOrder(
        PoolKey calldata key,
        int24 tick,
        bool zeroForOne,
        uint256 inputAmount
    ) internal {
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.MIN_SQRT_PRICE + 1
                    : TickMath.MAX_SQRT_PRICE - 1
            })
        );
        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;
        uint256 orderId = getOrderId(key, tick, zeroForOne);
        uint256 outputAmount = zeroForOne
            ? uint256(int256(delta.amount1()))
            : uint256(int256(delta.amount0()));
        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[orderId] += outputAmount;
    }

    // -------------------Hooks---------------------------

    // Storing the last tick values: 
    mapping (PoolId poold => int24 tick) public lastTicks;
    function _afterInitialize(
        address, 
        PoolKey calldata key, 
        uint160, 
        int24 tick)internal override returns (bytes4) {
            lastTicks[key.toId()] = tick;
            return this.afterInitialize.selector;
    }

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        // `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        if (sender == address(this)) return (this.afterSwap.selector, 0);
    
        // Should we try to find and execute orders? True initially
        bool tryMore = true;
        int24 currentTick;
    
        while (tryMore) {
            // Try executing pending orders for this pool
    
            // `tryMore` is true if we successfully found and executed an order
            // which shifted the tick value
            // and therefore we need to look again if there are any pending orders
            // within the new tick range
    
            // `tickAfterExecutingOrder` is the tick value of the pool
            // after executing an order
            // if no order was executed, `tickAfterExecutingOrder` will be
            // the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(
                key,
                !params.zeroForOne
            );
        }
 
        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

        function tryExecutingOrders(
        PoolKey calldata key,
        bool executeZeroForOne
    )   internal returns (bool tryMore, int24 newTick) {
        (, int24 currentTick, , ) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];
    
        // Given `currentTick` and `lastTick`, 2 cases are possible:
    
        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`
    
        // If tick increases => Token 0 price has increased
        // => We should check if we have orders looking to sell Token 0
        // i.e. orders with zeroForOne = true
    
        // ------------
        // Case (1)
        // ------------
    
        // Tick has increased i.e. people bought Token 0 by selling Token 1
        // i.e. Token 0 price has increased
        // e.g. in an ETH/USDC pool, people are buying ETH for USDC causing ETH price to increase
        // We should check if we have any orders looking to sell Token 0
        // at ticks `lastTick` to `currentTick`
        // i.e. check if we have any orders to sell ETH at the new price that ETH is at now because of the increase
        if (currentTick > lastTick) {
            // Loop over all ticks from `lastTick` to `currentTick`
            // and execute orders that are looking to sell Token 0
            for (
                int24 tick = lastTick;
                tick < currentTick;
                tick += key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    // An order with these parameters can be placed by one or more users
                    // We execute the full order as a single swap
                    // Regardless of how many unique users placed the same order
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
    
                    // Return true because we may have more orders to execute
                    // from lastTick to new current tick
                    // But we need to iterate again from scratch since our sale of ETH shifted the tick down
                    return (true, currentTick);
                }
            }
        }
        // ------------
        // Case (2)
        // ------------
        // Tick has gone down i.e. people bought Token 1 by selling Token 0
        // i.e. Token 1 price has increased
        // e.g. in an ETH/USDC pool, people are selling ETH for USDC causing ETH price to decrease (and USDC to increase)
        // We should check if we have any orders looking to sell Token 1
        // at ticks `currentTick` to `lastTick`
        // i.e. check if we have any orders to buy ETH at the new price that ETH is at now because of the decrease
        else {
            for (
                int24 tick = lastTick;
                tick > currentTick;
                tick -= key.tickSpacing
            ) {
                uint256 inputAmount = pendingOrders[key.toId()][tick][
                    executeZeroForOne
                ];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }
    
        return (false, currentTick);
    }
}