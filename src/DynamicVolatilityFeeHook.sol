// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import "lib/abdk-libraries-solidity/ABDKMath64x64.sol";

import {console} from "forge-std/console.sol";

contract DynamicVolatilityFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Keeping track of last time transacted
    uint256 public lastSwappedTimestamp;

    // The target impl vol
    uint24 public targetIv = 1_000_000; // 100% in fee tier units (100ths of bips)

    uint256 private DECIMALS = 10000;
    /// from LPFeeLibrary.sol | @notice the lp fee is represented in hundredths of a bip, so the max is 100%
    // uint24 public constant MAX_LP_FEE = 1000000;

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: true, // true
                afterInitialize: false,
                beforeAddLiquidity: false,
                beforeRemoveLiquidity: false,
                afterAddLiquidity: false,
                afterRemoveLiquidity: false,
                beforeSwap: true, // true
                afterSwap: true, // true
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    function _beforeInitialize(
        address,
        PoolKey calldata key,
        uint160
    ) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `LPFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        // TODO: use brevis to initialize volatility target

        return this.beforeInitialize.selector;
    }

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // Orginal constant volatility fee design accounted only for exactIn swaps, so keep this for now (may be possible to support exactOut too, not sure yet how)
        require(params.amountSpecified > 0, "Only exact in swaps allowed");

        // TODO: account for case where two swaps happen in one block so timeSinceLastSwap is 0
        uint256 timeSinceLastSwap = block.timestamp - lastSwappedTimestamp;

        if (params.zeroForOne) {
            // exactIn, 0 -> 1
            // TODO: get in range liquidity in t0
            poolManager.updateDynamicLPFee(
                key,
                getFee(
                    targetIv,
                    1 ether,
                    uint256(params.amountSpecified),
                    timeSinceLastSwap
                )
            );
        } else {
            // exact in, 1 -> 0
            // TODO: get in range liquidity in t1
            poolManager.updateDynamicLPFee(
                key,
                getFee(
                    targetIv,
                    1 ether,
                    uint256(params.amountSpecified),
                    timeSinceLastSwap
                )
            );
        }
    }

    // TODO: remove afterSwap ability?
    function _afterSwap(
        address,
        PoolKey calldata,
        IPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal override returns (bytes4, int128) {
        return (this.afterSwap.selector, 0);
    }

    // Fixed point 1st attempt - too innaccurate
    // Calculates fee on amountIn such that the volatility of the pool in response to the swap equals the target volatility
    // fee = iv_per_year / (2 * math.sqrt(365 * 24 * 60 * 60)) * math.sqrt(tick_tvl / amount0) * math.sqrt(deltaT_secs)
    // function getFee(uint256 iv, uint256 tickTvlInToken, uint256 amount, uint256 deltaTSecs)
    //     public
    //     pure
    //     returns (uint24)
    // {

    //     console.log("iv_seconds: ", iv/11231);
    //     uint256 iv_seconds = iv / 11231;

    //     uint256 liq_swap_ratio = tickTvlInToken / amount;
    //     console.log("liq_swap_ratio", liq_swap_ratio);

    //     uint256 sqrt_liq_swap_ratio = FixedPointMathLib.sqrt(tickTvlInToken / amount);
    //     console.log("sqrt_liq_swap_ratio: ", sqrt_liq_swap_ratio);

    //     uint256 sqrt_delta_t = FixedPointMathLib.sqrt(deltaTSecs);
    //     console.log("sqrt_delta_t: ", sqrt_delta_t);

    //     // return uint24(iv / 11231 * FixedPointMathLib.sqrt(tickTvlInToken / amount) * FixedPointMathLib.sqrt(deltaTSecs));
    //     return uint24(iv_seconds * sqrt_liq_swap_ratio * sqrt_delta_t);
    // }

    // Floating pt attempt working for test 1 & 2
    // Calculates fee on amountIn such that the volatility of the pool in response to the swap equals the target volatility
    // fee = iv_per_year / (2 * math.sqrt(365 * 24 * 60 * 60)) * math.sqrt(tick_tvl / amount0) * math.sqrt(deltaT_secs)
    // function getFee(uint256 iv, uint256 tickTvlInToken, uint256 amount, uint256 deltaTSecs)
    //     public
    //     pure
    //     returns (uint24)
    // {
    //     int128 ivSeconds = ABDKMath64x64.div(ABDKMath64x64.fromUInt(iv), ABDKMath64x64.fromUInt(11231));

    //     uint256 liqSwapRatio = tickTvlInToken / amount;
    //     console.log("liqSwapRatio", liqSwapRatio);

    //     int128 sqrtLiqSwapRatio = ABDKMath64x64.sqrt(ABDKMath64x64.fromUInt(liqSwapRatio));

    //     int128 sqrtDeltaT = ABDKMath64x64.sqrt(ABDKMath64x64.fromUInt(deltaTSecs));

    //     int128 fee = ABDKMath64x64.mul(ABDKMath64x64.mul(ivSeconds, sqrtLiqSwapRatio), sqrtDeltaT);

    //     // TODO: add a floor fee for when tick tvl gets exhausted by 1 swap
    //     // TODO: add a max fee for when deltaTSecs gets v large

    //     return uint24(ABDKMath64x64.toUInt(fee));
    // }

    function getFee(
        uint256 iv,
        uint256 tickTvlInToken,
        uint256 amount,
        uint256 deltaTSecs
    ) public pure returns (uint24) {
        uint256 ivSeconds = iv / 11231;

        // Calculate sqrt(tickTvlInToken/amount) with scaling for precision
        uint256 scale = 1e18;
        uint256 sqrtRatio;

        sqrtRatio = FixedPointMathLib.sqrt((tickTvlInToken * scale) / amount);

        // Calculate sqrt(deltaT)
        uint256 sqrtDeltaT = FixedPointMathLib.sqrt(deltaTSecs * scale);

        uint256 fee = (ivSeconds * sqrtRatio * sqrtDeltaT) / (scale);

        return uint24(fee);
    }
}
