// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;
 
// Foundry libraries
import {Test} from "forge-std/Test.sol";
 
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
 
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
 
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
 
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
 
import {TakeProfitsHook} from "../src/TakeProfitsHook.sol";

 import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
 
contract TakeProfitsHookTest is Test, Deployers, ERC1155Holder {
    // Use the libraries
    using StateLibrary for IPoolManager;
 
    // The two currencies (tokens) from the pool
    Currency token0;
    Currency token1;
 
    TakeProfitsHook hook;
 
	function setUp() public {
        // Deploy v4 core contracts
        deployFreshManagerAndRouters();
    
        // Deploy two test tokens
        (token0, token1) = deployMintAndApprove2Currencies();
    
        // Deploy our hook
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddress = address(flags);
        deployCodeTo(
            "TakeProfitsHook.sol",
            abi.encode(manager, ""),
            hookAddress
        );
        hook = TakeProfitsHook(hookAddress);
    
        // Approve our hook address to spend these tokens as well
        MockERC20(Currency.unwrap(token0)).approve(
            address(hook),
            type(uint256).max
        );
        MockERC20(Currency.unwrap(token1)).approve(
            address(hook),
            type(uint256).max
        );

        //Why ? -> In order to transfer the tokens on behalf of the user
        // In Ethereum, ERC20 tokens require explicit approval before any contract can transfer tokens on behalf of a user

    
        // Initialize a pool with these two tokens
        (key, ) = initPool(token0, token1, hook, 3000, SQRT_PRICE_1_1);
    
        // Add initial liquidity to the pool
    
        // Some liquidity from -60 to +60 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // Some liquidity from -120 to +120 tick range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: -120,
                tickUpper: 120,
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
        // some liquidity for full range
        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 10 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    function test_placeOrder() public {
        // Place a zeroForOne take-profit order
        // for 10e18 token0 tokens
        // at tick 100
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;
    
        // Note the original balance of token0 we have
        uint256 originalBalance = token0.balanceOfSelf();
    
        // Place the order
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
    
        // Note the new balance of token0 we have
        uint256 newBalance = token0.balanceOfSelf();
    
        // Since we deployed the pool contract with tick spacing = 60
        // i.e. the tick can only be a multiple of 60
        // the tickLower should be 60 since we placed an order at tick 100
        assertEq(tickLower, 60);
    
        // Ensure that our balance of token0 was reduced by `amount` tokens
        assertEq(originalBalance - newBalance, amount);
    
        // Check the balance of ERC-1155 tokens we received
        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
    
        // Ensure that we were, in fact, given ERC-1155 tokens for the order
        // equal to the `amount` of token0 tokens we placed the order for
        assertTrue(orderId != 0);
        assertEq(tokenBalance, amount);
    }

    function test_cancelOrder() public {
        // Place an order as earlier
        int24 tick = 100;
        uint256 amount = 10e18;
        bool zeroForOne = true;
    
        uint256 originalBalance = token0.balanceOfSelf();
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
        uint256 newBalance = token0.balanceOfSelf();
    
        assertEq(tickLower, 60);
        assertEq(originalBalance - newBalance, amount);
    
        // Check the balance of ERC-1155 tokens we received
        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, amount);
    
        // Cancel the order
        hook.cancelOrder(key, tickLower, zeroForOne, amount);
    
        // Check that we received our token0 tokens back, and no longer own any ERC-1155 tokens
        uint256 finalBalance = token0.balanceOfSelf();
        assertEq(finalBalance, originalBalance);
    
        tokenBalance = hook.balanceOf(address(this), orderId);
        assertEq(tokenBalance, 0);
    }

    // ------------------ Hook Testing ------------------
    function test_orderExecute_zeroForOne() public {
        int24 tick = 100;
        uint256 amount = 1 ether;
        bool zeroForOne = true;
    
        // Place our order at tick 100 for 10e18 token0 tokens
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);
    
        // Do a separate swap from oneForZero to make tick go up
        // Sell 1e18 token1 tokens for token0 tokens
        SwapParams memory params = SwapParams({
            zeroForOne: !zeroForOne,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });
    
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest
            .TestSettings({takeClaims: false, settleUsingBurn: false});
    
        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
    
        // Check that the order has been executed
        // by ensuring no amount is left to sell in the pending orders
        uint256 pendingTokensForPosition = hook.pendingOrders(
            key.toId(),
            tick,
            zeroForOne
        );
        assertEq(pendingTokensForPosition, 0);
    
        // Check that the hook contract has the expected number of token1 tokens ready to redeem
        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(orderId);
        uint256 hookContractToken1Balance = token1.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractToken1Balance);
    
        // Ensure we can redeem the token1 tokens
        uint256 originalToken1Balance = token1.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken1Balance = token1.balanceOf(address(this));
    
        assertEq(
            newToken1Balance - originalToken1Balance,
            claimableOutputTokens
        );
    }

    function test_orderExecute_oneForZero() public {
        int24 tick = -100;
        uint256 amount = 1 ether;
        bool zeroForOne = false;

        // Place our order at tick -100 for 10e18 token0 tokens
        int24 tickLower = hook.placeOrder(key, tick, zeroForOne, amount);

        // Do a separate swap from zeroForOne to make tick go down
        // Sell 1e18 token0 tokens for token1 tokens
        SwapParams memory params = SwapParams({
            zeroForOne: true,
            amountSpecified: -1 ether,
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        });

        // Router Settings
        PoolSwapTest.TestSettings memory TestSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });

        // Conduct the swap - `afterSwap` should also execute our placed order
        swapRouter.swap(key, params, TestSettings, ZERO_BYTES);
        
        // Now Check if the orders are fulfilled or not
        uint256 tokensLeftToSell = hook.pendingOrders(key.toId(), tick, zeroForOne);
        assertEq(tokensLeftToSell, 0);

        uint256 orderId = hook.getOrderId(key, tickLower, zeroForOne);
        uint256 claimableOutputTokens = hook.claimableOutputTokens(orderId);
        uint256 hookContractTokenBalance = token0.balanceOf(address(hook));
        assertEq(claimableOutputTokens, hookContractTokenBalance);

        // Ensure we can redeem the token0 tokens
        uint256 originalToken0Balance = token0.balanceOf(address(this));
        hook.redeem(key, tick, zeroForOne, amount);
        uint256 newToken0Balance = token0.balanceOf(address(this));

        assertEq(
            newToken0Balance - originalToken0Balance,
            claimableOutputTokens
        );
    }

    function test_multiple_orderExecute_zeroForOne_onlyOne() public {
        // Place Orders at required tick value
        // WE will place same amount of order at tick 0, 60 then make swap such that
        // the tick exceeds 60 but, when the consecutive swap happens then the tick doesn't go down below 0
        uint256 amount = 0.01 ether;
        
        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);
        // Make a swap such that the tick value goes above tick 60 

        // Router Settings: 
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: false, 
            amountSpecified: -0.1 ether,
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE -1 
        });

        swapRouter.swap(key, params, testSettings, ZERO_BYTES);
        

        // Check if the assertions are true
        uint256 tokenLeftToSell = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokenLeftToSell, 0);
        
        // Check if the swap at tick zero happended or not 
        uint256 tokenLeftToSell_1 = hook.pendingOrders(key.toId(), 60, true);
        assertEq(tokenLeftToSell_1, amount);
    }    
    function test_multiple_orderExecute_zeroForOne_both() public {
        //Place Orders
        uint256 amount = 0.01 ether;

        hook.placeOrder(key, 0, true, amount);
        hook.placeOrder(key, 60, true, amount);
        
        //Swap such that the tick doesn't go down enough to stop the other swap
        PoolSwapTest.TestSettings memory testSet = PoolSwapTest.TestSettings({
            takeClaims: false,
            settleUsingBurn: false
        });
        
        SwapParams memory params = SwapParams({
            zeroForOne: false, // Since we want to increase the tick value, implying that we have to increase the value of token 0, so buy token 0
            amountSpecified: -0.5 ether, 
            sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
        });

        swapRouter.swap(key, params, testSet, ZERO_BYTES); 
        
        uint256 tokenLeft = hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokenLeft, 0);
        
        uint256 tokenLeft_2= hook.pendingOrders(key.toId(), 0, true);
        assertEq(tokenLeft_2, 0);

    } 
}