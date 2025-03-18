// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
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
    uint256 public lastSwappedBlock;

    // The target impl vol
    uint24 public targetIv = 1000; // denominated in bips (100% = 1000 bps)

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
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        uint timeSinceLastSwap = block.timestamp - lastSwappedTimestamp;
        poolManager.updateDynamicLPFee(key, getFee());

        if (block.number > lastSwappedBlock) {
            // TODO: can't do it per block, have to do it by size. But DO update timestamp and last swapped block every swap
            // If no swaps have happened this block, calc new fee for the block
            lastSwappedTimestamp = block.timestamp;
            lastSwappedBlock = block.number;
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
    function getFee(uint256 tick_tvl, uint256 amount, uint256 deltaT_secs) internal view returns (uint24) {
        // Convert IV_per_year to fixed point with 18 decimals for precision
        uint256 IV_per_year = 100e18; // Example value, should be passed in or stored
        
        // Calculate sqrt of seconds in a year (365 * 24 * 60 * 60) = 31536000
        uint256 SQRT_SECONDS_PER_YEAR = 5615;
        
        // Calculate feeTier using the formula:
        // feeTier = IV_per_year / (2 * sqrt(365*24*60*60)) * sqrt(tick_tvl/amount) * sqrt(deltaT_secs)
        
        // First calculate sqrt(tick_tvl/amount) using fixed point math
        uint256 tvl_ratio = (tick_tvl * 1e18) / amount; // Scale up for precision
        uint256 sqrt_tvl_ratio = Math.sqrt(tvl_ratio);
        
        // Calculate sqrt(deltaT_secs)
        uint256 sqrt_deltaT = Math.sqrt(deltaT_secs * 1e18);
        
        // Put it all together
        uint256 feeTier = (IV_per_year * sqrt_tvl_ratio * sqrt_deltaT) / (2 * SQRT_SECONDS_PER_YEAR * 1e18);
        
        // Convert to uint24 and return
        return uint24(feeTier);
    }
}
