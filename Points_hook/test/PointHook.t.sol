
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {PoolManager} from "v4-core/PoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/types/PoolOperation.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId} from "v4-core/types/PoolId.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-core/libraries/SqrtPriceMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {ERC1155TokenReceiver} from "solmate/src/tokens/ERC1155.sol";

import "forge-std/console.sol";
import {PointsHook} from "../src/PointsHook.sol";

contract TestPointsHook is Test, Deployers, ERC1155TokenReceiver {
	MockERC20 token; // our token to use in the ETH-TOKEN pool

	// Native tokens are represented by address(0)
    // type currency is address with some extra helper functions
	Currency ethCurrency = Currency.wrap(address(0));
	Currency tokenCurrency;

	PointsHook hook;

    function setUp() public {
        
        // 1. deploy uniswap v4 itself
        deployFreshManagerAndRouters();

        // 2. Deploy some fake TOKEN ERC1155 (mint a bunch of it ourselves so we can use it to add liquidity)
        token = new MockERC20("Test Token","TOKEN", 18);
        // ERC20 token with the name, symbol and number of decimal places
        tokenCurrency = Currency.wrap(address(token));
        
        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);
        
        // 3. Deploy your hook contract
        // Currently only on the test net so we can choose the contract address (20 Bytes/ 160 bits long)

        // An address is of 160 bits
        uint160 flags = uint160(Hooks.AFTER_SWAP_FLAG); // Just extending the default bitmap for the after swap to be called
        // 160 bits out of it 1 bit is 1 and all the others are 0's

        // converting into an address
        address hookAddress = address(flags);
        deployCodeTo("PointsHook.sol", abi.encode(manager), hookAddress);
        hook = PointsHook(hookAddress);

        // Note: In mainnet we have to mine the right address for the contract to fine tune the hook functions that are being called. 

        // 4. Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from the `Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        

        // 5. Initialize a pool on uniswap
        (key, ) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook Contract
            3000, // Swap Fees
            SQRT_PRICE_1_1 // Initial Sqrt(P) value = 1
        );

        // add some liquidity to the pool on uniswap
         // Add some liquidity to the pool
        uint160 sqrtPriceAtTickLower = TickMath.getSqrtPriceAtTick(-60);
        uint160 sqrtPriceAtTickUpper = TickMath.getSqrtPriceAtTick(60);

        uint256 ethToAdd = 0.003 ether;
        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmount0(
            SQRT_PRICE_1_1,
            sqrtPriceAtTickUpper,
            ethToAdd
        );

        modifyLiquidityRouter.modifyLiquidity{value: ethToAdd}(
        key,
        ModifyLiquidityParams({
            tickLower: -60,
            tickUpper: 60,
            liquidityDelta: int256(uint256(liquidityDelta)),
            salt: bytes32(0)
        }),
        ZERO_BYTES
    );
}

    function testSwap() public{
        // 1. Check the pointsBalance before the swap
        uint256 poolIduint = uint256(PoolId.unwrap(key.toId()));
        // balanceOf is a mapping in the ERC1155
        uint256 pointsBalanceOrg = hook.balanceOf(
            address(this),
            poolIduint
        );

        // 2. Perform the required swap
        // a. user address set in the hookdata
        bytes memory hookdata = abi.encode(address(this)); 

        // b. perform the swap using the swapRouter
        swapRouter.swap{value: 0.001 ether}(
            key,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // exact input swap 
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1 
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookdata
        );
        

        // Check if the points balance changed or not
        uint256 pointsBalanceAfter = hook.balanceOf(
            address(this),
            poolIduint
        );
        assertEq(pointsBalanceAfter - pointsBalanceOrg, 2 * 10 ** 14);
        // 20 % of 0.001 ether is 2e14, since 1 ether is equal to 1e18 wei
    }
}