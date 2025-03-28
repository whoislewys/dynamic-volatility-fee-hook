// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/utils/BaseHook.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {FullMath} from "v4-core/libraries/FullMath.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./brevis/BrevisApp.sol";
import "./brevis/IBrevisProof.sol";

// ConstantVolatilityAMMHook, with a dynamic IV target using the Brevis ZK Coprocessor to set IV based on on-chain activity.
// IV is calulated using Uniswap IV, shown to closely match (sometimes leading, sometimes lagging, but always close) IV on other venues. More details on Uniswap IV...
// Formulation: https://lambert-guillaume.medium.com/on-chain-volatility-and-uniswap-v3-d031b98143d1
// Comparison of Uniswap IV in ETH/USDC to Deribit's DVOL: https://panoptic.xyz/research/comparing-uniswap-deribit-implied-volatilities
// Brevis was integrated following example from docs:
// https://web.archive.org/web/20250122054233/https://docs.brevis.network/developer-guide/tutorial/writing-the-app-contract
contract IVTargetingFeeHook is BaseHook, BrevisApp, Ownable {
    using StateLibrary for IPoolManager;

    using PoolIdLibrary for PoolKey;

    using LPFeeLibrary for uint24;

    // Storage
    IPoolManager manager;

    // Keeping track of last time transacted
    uint256 public lastSwappedTimestamp;

    // The target impl vol
    uint256 public targetIv = 1_000_000; // 100% in fee tier units (100ths of bips)

    bytes32 public vkHash;

    // Errors
    error MustUseDynamicFee();

    // Events
    event IVUpdated(uint256 iv);

    constructor(IPoolManager _poolManager, address brevisProof)
        BaseHook(_poolManager)
        BrevisApp(IBrevisProof(brevisProof))
        Ownable(msg.sender)
    {
        manager = _poolManager;
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // true
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // true
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `LPFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();

        // TODO: use brevis to initialize volatility target

        return this.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint256 amountSpecified = uint256(params.amountSpecified);
        // Orginal constant volatility fee design accounted only for exactIn swaps, so keep this for now (may be possible to support exactOut too, not sure yet how)
        require(amountSpecified > 0, "Only exact in swaps allowed");

        int24 tick;
        (, tick,,) = manager.getSlot0(key.toId());
        int128 liquidityNet;
        (, liquidityNet) = manager.getTickLiquidity(key.toId(), tick); // skip gross, use net liq as tickTvl
        uint128 liquidity = uint128(liquidityNet);
        // TODO: account for case where two swaps happen in one block so timeSinceLastSwap is 0
        uint256 timeSinceLastSwap = block.timestamp - lastSwappedTimestamp;

        if (params.zeroForOne) {
            // exactIn, 0 -> 1
            uint256 liquidityIn0 = LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + 1), liquidity
            );
            poolManager.updateDynamicLPFee(key, getFee(targetIv, liquidityIn0, amountSpecified, timeSinceLastSwap));
        } else {
            // exact in, 1 -> 0
            uint256 liquidityIn1 = LiquidityAmounts.getAmount0ForLiquidity(
                TickMath.getSqrtPriceAtTick(tick), TickMath.getSqrtPriceAtTick(tick + 1), liquidity
            );
            poolManager.updateDynamicLPFee(key, getFee(targetIv, liquidityIn1, amountSpecified, timeSinceLastSwap));
        }
    }

    function getFee(uint256 iv, uint256 tickTvlInToken, uint256 amount, uint256 deltaTSecs)
        public
        pure
        returns (uint24)
    {
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

    /*
     ____  ____  _______     _____ ____  
    | __ )|  _ \| ____\ \   / /_ _/ ___| 
    |  _ \| |_) |  _|  \ \ / / | |\___ \ 
    | |_) |  _ <| |___  \ V /  | | ___) |
    |____/|_| \_\_____|  \_/  |___|____/ 
                                         
    */
    function handleProofResult(
        bytes32,
        /*_requestId*/
        bytes32 _vkHash,
        bytes calldata _circuitOutput
    ) internal override {
        // We need to check if the verifying key that Brevis used to verify the proof generated by our circuit is indeed
        // our designated verifying key. This proves that the _circuitOutput is authentic
        require(vkHash == _vkHash, "invalid vk");

        targetIv = decodeOutput(_circuitOutput);

        emit IVUpdated(targetIv);
    }

    function decodeOutput(bytes calldata o) internal pure returns (uint256) {
        uint256 _targetIv = uint256(uint248(bytes31(o[0:31]))); // extract _targetIv from circuit uint248 output (248 / 8 = 31 bytes), then convert to uint256

        return _targetIv;
    }

    function setVkHash(bytes32 _vkHash) external onlyOwner {
        vkHash = _vkHash;
    }
}
