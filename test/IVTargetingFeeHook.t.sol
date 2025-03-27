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
import {IVTargetingFeeHook} from "../src/IVTargetingFeeHook.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {console} from "forge-std/console.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {MockBrevisProof} from "../src/brevis/MockBrevisProof.sol";

contract TestGasPriceFeesHook is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    IVTargetingFeeHook hook;

    bytes32 private constant vkHash = 0x658967d179b53c6a25fe83190ba8342c4922ab556e69a87ccc5414d92c84f9e3; // obtained from $HOME/circuitOut dir set in brevis quickstart repo
    MockBrevisProof private brevisProofMock;

    function setUp() public {
        // Deploy v4-core
        deployFreshManagerAndRouters();

        // Deploy, mint tokens, and approve all periphery contracts for two tokens
        deployMintAndApprove2Currencies();

        // mock brevis proof conch
        brevisProofMock = new MockBrevisProof();

        // Deploy our hook with the proper flags
        address hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG |
                    Hooks.BEFORE_SWAP_FLAG
            )
        );

        deployCodeTo(
            "IVTargetingFeeHook.sol",
            abi.encode(manager, address(brevisProofMock)),
            hookAddress
        );
        hook = IVTargetingFeeHook(hookAddress);

        hook.setVkHash(vkHash);

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
        GetFeeTestCase[3] memory testCases = [
            GetFeeTestCase({
                iv: 1_000_000, // 100% annual volatility target in fee units (1 100th of a bp)
                tickTvlInToken: 315 ether, // 315 eth
                amount: 1 ether, // 1 ETH trade
                deltaTSecs: 15, // 15 secs since last trade
                expectedFee: 6120 // matching original medium post & python replication. for more, see: notebooks/constant-volatility-fee-calcs.ipynb
            }),
            GetFeeTestCase({
                iv: 1_000_000,
                tickTvlInToken: 315 ether,
                amount: 1 ether,
                deltaTSecs: 30,
                expectedFee: 8655
            }),
            GetFeeTestCase({
                iv: 1_000_000,
                tickTvlInToken: 315 ether,
                amount: 1000 ether,
                deltaTSecs: 15,
                expectedFee: 193
            })
        ];

        for (uint256 i = 0; i < testCases.length; i++) {
            GetFeeTestCase memory testCase = testCases[i];
            uint24 fee = hook.getFee(
                testCase.iv,
                testCase.tickTvlInToken,
                testCase.amount,
                testCase.deltaTSecs
            );

            console.log("case no", i);
            console.log("fee", fee);
            // assertEq(fee, testCase.expectedFee);

            assertApproxEqAbs(
                fee,
                testCase.expectedFee,
                0.0001 ether // error margin for precision loss
            );
        }
    }

    // TODO: test case where two swaps happen in one block so timeSinceLastSwap is 0
}
