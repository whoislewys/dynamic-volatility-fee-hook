// Note to self, max constraints: 2^26 (source:https://web.archive.org/web/20250122054233mp_/https://docs.brevis.network/developer-resources/limits-and-performance)
// 67108864
package circuits

import (
	"fmt"

	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/ethereum/go-ethereum/common"
)

type AppCircuit struct{}

// mainnet
var usdcWeth5BpsPool = common.HexToHash("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640")

var _ sdk.AppCircuit = &AppCircuit{}

func (c *AppCircuit) Allocate() (maxReceipts, maxStorage, maxTransactions int) {
	// Allocate n receipts for swaps to calc volume and 2 storage inputs - 1 for current tick and 1 for liquidity
	// according to error messages, allocated space must be an integral multiple of 32 kek

	// unit test allocation
	return 32, 32, 0

	// prod allocation
	// return 3840, 32, 0
}

// Calculate IV
// IV will be calculated in this circuit, then pushed to the smart contract to update the target IV.
// So, what do we need? IV can be calculated from Uniswap data as such:
// iv = 2 * (feeTier / 10 ** 6) * (dailyVolume / tickTvl) ** 0.5 * Math.sqrt(365)
// The other input besides tickTvl is volume, which can be easily summed up from swap events
func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
	// Start by getting volume by summing abs(amount1)
	swapReceipts := sdk.NewDataStream(api, in.Receipts)
	amount1Volumes := sdk.Map(swapReceipts, func(r sdk.Receipt) sdk.Uint248 {
		valInt := api.ToInt248(r.Fields[0].Value)
		absVal := api.Int248.ABS(valInt)
		fmt.Printf("Amount1 volume: %s\n", absVal.String())
		return absVal
	})

	totalVolume := sdk.Sum(amount1Volumes)
	fmt.Printf("Total volume: %s\n", totalVolume.String())

	// Now read storage slots to get current tick and liquidity
	storageSlots := sdk.NewDataStream(api, in.StorageSlots)
	slot0 := sdk.GetUnderlying(storageSlots, 0)

	currentTickBits := api.Int248.ToBinary(api.ToInt248(slot0.Value))[160:184] // bits 160 : 184 store `tick` in slot0
	currentTick := api.Uint248.FromBinary(currentTickBits...)
	// fmt.Println(currentTick.String(), currentTickBytes.String())

	slot4 := sdk.GetUnderlying(storageSlots, 1)
	liquidity := api.ToUint248(slot4.Value) // Extract uint128 liquidity
	fmt.Printf("Liquidity: %s\n", liquidity.String())

	// Calculate iv

	// Calculate IV, but don't divide by fee tier decimals to leave IV in fee tier units. this is how the target_iv is represented in the smart contract
	// Calculate daily volume from total volume
	dailyVolume := api.ToUint248(totalVolume)

	// approximate tickTvl by taking in range liquidity and calculating it all in token1 in a 1 tick wide range
	tickTvlIn1 := GetAmount1ForLiquidity(api, currentTick, api.Uint248.Add(currentTick, sdk.ConstUint248(1)), liquidity)

	// Calculate square root of (dailyVolume/tickTvl)
	volTvlRatio, _ := api.Uint248.Div(dailyVolume, tickTvlIn1)
	sqrtVolTvl := api.Uint248.Sqrt(volTvlRatio)

	// sqrt(365)
	sqrtOf365 := sdk.ConstUint248(19) // sqrt(365) = 19.1049731745428

	// Calculate IV: 2 * feeTier * sqrt(dailyVolume/tickTvl) * sqrt(365)
	// Fee tier is 500 bps (0.05%)
	feeTierU248 := sdk.ConstUint248(500)
	iv := api.Uint248.Mul(api.Uint248.Mul(api.Uint248.Mul(sdk.ConstUint248(2), feeTierU248), sqrtVolTvl), sqrtOf365)

	// Outputs
	// Will be able to decode like this:
	// function decodeOutput(bytes calldata o) internal pure returns (uint256) {
	// 	uint256 target_iv = uint256(uint248(bytes31(o[0:31]))); // start with iv uint248 (248 / 8 = 31 bytes)
	// 	return target_iv;
	// }

	api.OutputUint(248, iv)

	return nil
}

// getAmount1ForLiquidity, but operate in tick space rather than sqrt price space, since there are no power functions in brevis circuit api
// See section 2.1, equation 2, but without squareroots around the prices. https://atiselsts.github.io/pdfs/uniswap-v3-liquidity-math.pdf
func GetAmount1ForLiquidity(api *sdk.CircuitAPI, tickA sdk.Uint248, tickB sdk.Uint248, liquidity sdk.Uint248) sdk.Uint248 {
	isGreater := api.Uint248.IsGreaterThan(tickA, tickB)

	finalTickA := api.Uint248.Select(isGreater, tickB, tickA)
	finalTickB := api.Uint248.Select(isGreater, tickA, tickB)

	tickDiff := api.Uint248.Sub(finalTickB, finalTickA)

	amount1 := api.Uint248.Mul(liquidity, tickDiff)

	return amount1
}
