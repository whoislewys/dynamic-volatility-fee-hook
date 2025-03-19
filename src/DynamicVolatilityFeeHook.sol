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

contract DynamicVolatilityFeeHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Keeping track of last time transacted
    uint256 public lastSwappedTimestamp;

    // The target impl vol
    uint24 public targetIv = 1_000_000; // 100% in fee tier units (100ths of bips)

    uint private DECIMALS = 10000;
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
        uint timeSinceLastSwap = block.timestamp - lastSwappedTimestamp;

        if (params.zeroForOne) {
          // exactIn, 0 -> 1
          // TODO: get in range liquidity in t0
          poolManager.updateDynamicLPFee(key, getFee(targetIv, 1 ether, uint256(params.amountSpecified), timeSinceLastSwap));
        } else {
          // exact in, 1 -> 0
          // TODO: get in range liquidity in t1
          poolManager.updateDynamicLPFee(key, getFee(targetIv, 1 ether, uint256(params.amountSpecified), timeSinceLastSwap));
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

    // gets fee in 100ths of a bp for a given token & tick tvl
    function getFee(
        uint256 iv,
        uint256 tickTvlInToken,
        uint256 amount,
        uint256 deltaTSecs
    ) public view returns (uint24) {
        return 69;
    }
}
