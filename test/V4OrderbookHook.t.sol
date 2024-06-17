// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.0;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {V4OrderbookHook} from "../src/V4OrderbookHook.sol";
import {HookMiner} from "./utils/HookMiner.sol";
import {MatchingEngine} from "./utils/MatchingEngine.sol";
import {OrderbookFactory} from "./utils/OrderbookFactory.sol";
import {WETH9} from "./utils/WETH9.sol";
import {Utils} from "./utils/Utils.sol";

contract TestV4OrderbookHook is Test, Deployers {
    using CurrencyLibrary for Currency;

    address feeTo = 0x34CCCa03631830cD8296c172bf3c31e126814ce9;

    MockERC20 token;

    Currency ethCurrency = Currency.wrap(address(0));
    Currency tokenCurrency;

    V4OrderbookHook hook;

    address public trader1;
    address[] public users;

    function setUp() public {
        Utils utils = new Utils();
        users = utils.createUsers(4);
        trader1 = users[0];
        vm.label(trader1, "Trader 1");
        // Step 1
        // Deploy MatchingEngine and connect
        OrderbookFactory orderbookFactory = new OrderbookFactory();
        MatchingEngine matchingEngine = new MatchingEngine();
        WETH9 weth = new WETH9();

        matchingEngine.initialize(address(orderbookFactory), address(feeTo), address(weth));

        orderbookFactory.initialize(address(matchingEngine));

        // Step 2
        // Deploy PoolManager and Router contract
        deployFreshManagerAndRouters();

        // Deploy our Token contrat
        token = new MockERC20("Test Token", "TEST", 18);
        tokenCurrency = Currency.wrap(address(token));

        // Mint a bunch of TOKEN to ourselves and to address(1)
        token.mint(address(this), 1000 ether);
        token.mint(address(1), 1000 ether);
        token.mint(address(trader1), 1000 ether);

        address hookAddress = address(uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG));

        deployCodeTo("V4OrderbookHook.sol", abi.encode(manager, address(matchingEngine), address(weth)), hookAddress);

        hook = V4OrderbookHook(payable(hookAddress));

        // Approve our TOKEN for spending on the swap router and modify liquidity router
        // These variables are coming from '`Deployers` contract
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(matchingEngine), type(uint256).max);

        vm.startPrank(trader1);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(matchingEngine), type(uint256).max);
        vm.stopPrank();

        // Initialize a pool
        (key,) = initPool(
            ethCurrency, // Currency 0 = ETH
            tokenCurrency, // Currency 1 = TOKEN
            hook, // Hook
            3000, // Swap Fees
            SQRT_PRICE_1_1, // Initial Sqrt(P) value = 1
            ZERO_BYTES // no additional `initData`
        );

        // Initialize a pair in orderbook
        // 2000e8 = 2000 TOKEN
        matchingEngine.addPair(address(weth), Currency.unwrap(tokenCurrency), 2000e8);
    }

    /*
        currentTick = 0
        We are adding liquidity at tickLower = -60, tickUpper = 60

        New liquidity must not change the token price

        We saw an equation in "Ticks and Q64.96 Numbers" of how to calculate amounts of
        x and y when adding liquidity. Given the three variables - x, y, and L - we need to set value of one.

        We'll set liquidityDelta = 1 ether, i.e. ΔL = 1 ether
        since the `modifyLiquidity` function takes `liquidityDelta` as an argument instead of 
        specific values for `x` and `y`.

        Then, we can calculate Δx and Δy:
        Δx = Δ (L/SqrtPrice) = ( L * (SqrtPrice_tick - SqrtPrice_currentTick) ) / (SqrtPrice_tick * SqrtPrice_currentTick)
        Δy = Δ (L * SqrtPrice) = L * (SqrtPrice_currentTick - SqrtPrice_tick)

        So, we can calculate how much x and y we need to provide
        The python script below implements code to compute that for us
        Python code taken from https://uniswapv3book.com

        ```py
        import math

        q96 = 2**96

        def tick_to_price(t):
            return 1.0001**t

        def price_to_sqrtp(p):
            return int(math.sqrt(p) * q96)

        sqrtp_low = price_to_sqrtp(tick_to_price(-60))
        sqrtp_cur = price_to_sqrtp(tick_to_price(0))
        sqrtp_upp = price_to_sqrtp(tick_to_price(60))

        def calc_amount0(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * q96 * (pb - pa) / pa / pb)

        def calc_amount1(liq_delta, pa, pb):
            if pa > pb:
                pa, pb = pb, pa
            return int(liq_delta * (pb - pa) / q96)

        one_ether = 10 ** 18
         liq = 1 * one_ether
        eth_amount = calc_amount0(liq, sqrtp_upp, sqrtp_cur)
        token_amount = calc_amount1(liq, sqrtp_low, sqrtp_cur)

        print(dict({
        'eth_amount': eth_amount,
        'eth_amount_readable': eth_amount / 10**18,
        'token_amount': token_amount,
        'token_amount_readable': token_amount / 10**18,
        }))
        ```

        {'eth_amount': 2995354955910434, 'eth_amount_readable': 0.002995354955910434, 'token_amount': 2995354955910412, 'token_amount_readable': 0.002995354955910412}

        Therefore, Δx = 0.002995354955910434 ETH and Δy = 0.002995354955910434 Tokens

        NOTE: Python and Solidity handle precision a bit differently, so these are rough amounts. Slight loss of precision is to be expected.

        */

    function test_Add_Liqudity_And_Swap() public {
        // Set no referrer in the hook data
        bytes memory hookData = hook.getHookData(2000e8, 100_000, address(feeTo), true, 2);

        // How we landed on 0.003 ether here is based on computing value of x and y given
        // total value of delta L (liquidity delta) = 1 ether
        // This is done by computing x and y from the equation shown in Ticks and Q64.96 Numbers
        // View the full code for this lesson on Github which has additional comments
        // showing the exact computation and a Python script to do that calculation for you
        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: 0}),
            hookData
        );

        //  Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14 points
        vm.prank(trader1);
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );

        assertEq(token.balanceOf(trader1), 1000 ether);
    }

    function test_Add_Liquidity_And_Swap_With_Referral() public {
        bytes memory hookData = hook.getHookData(2000e8, 100_000, address(feeTo), true, 2);

        modifyLiquidityRouter.modifyLiquidity{value: 0.003 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({tickLower: -60, tickUpper: 60, liquidityDelta: 1 ether, salt: 0}),
            hookData
        );

        //  Now we swap
        // We will swap 0.001 ether for tokens
        // We should get 20% of 0.001 * 10**18 points
        // = 2 * 10**14 points
        // Referrer should get 10% of that so 2 * 10**13 points
        vm.prank(trader1);
        swapRouter.swap{value: 0.001 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether, // exact input for output swap
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            hookData
        );

        assertEq(token.balanceOf(trader1), 1000 ether);
    }
}
