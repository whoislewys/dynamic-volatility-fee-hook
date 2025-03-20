// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "v4-core/PoolManager.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {DynamicVolatilityFeeHook} from "../src/DynamicVolatilityFeeHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    DynamicVolatilityFeeHook hook;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG |
                    Hooks.AFTER_SWAP_FLAG
            )
        );

        deployCodeTo("DynamicVolatilityFeeHook.sol", abi.encode(manager), hookAddress);
        hook = DynamicVolatilityFeeHook(hookAddress);

        // Initialize a pool
        (key, ) = initPool(
            currency0,
            currency1,
            hook,
            LPFeeLibrary.DYNAMIC_FEE_FLAG, // Set the `DYNAMIC_FEE_FLAG` in place of specifying a fixed fee
            SQRT_PRICE_1_1
        );

        // Add 100 eth of liquidity
        modifyLiquidityRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -60,
                tickUpper: 60,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /*
    Tests for getFee should start with:
    # Example 1: 1 ETH trade with 100% annual volatility target
    # Example 2: 1 ETH trade with 100% annual volatility target
    # Example 3: 1000 ETH whale trade
    # Example 4: 1 ETH with .69% volatility
    */
    struct GetFeeTestCase {
        // getFee inputs
        uint256 iv;
        uint256 tickTvlInToken;
        uint256 amount;
        uint256 deltaTSecs;
        // getFee outputs
        uint24 expectedFee;
        
    }

    function test_getFee() public {
        GetFeeTestCase memory testCase = GetFeeTestCase({
            iv: 1_000_000, // 100% annual volatility target in fee units (1 100th of a bp)
            tickTvlInToken: 315 ether, // 315 eth
            amount: 1 ether, // 1 ETH trade
            deltaTSecs: 15, // 15 secs since last trade
            expectedFee: 6120 // matching original medium post & python replication. for more, see: notebooks/constant-volatility-fee-calcs.ipynb
        });

        uint24 fee = hook.getFee(
            testCase.iv,
            testCase.tickTvlInToken, 
            testCase.amount,
            testCase.deltaTSecs
        );

        assertEq(fee, testCase.expectedFee);
    }

    // TODO: test case where two swaps happen in one block so timeSinceLastSwap is 0
}
