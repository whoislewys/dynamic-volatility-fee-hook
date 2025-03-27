// Note to self, max constraints: 2^26
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
	return 32, 32, 0
}

// func (c *AppCircuit) Define(api *sdk.CircuitAPI, in sdk.DataInput) error {
// 	receipts := sdk.NewDataStream(api, in.Receipts)
// 	receipt := sdk.GetUnderlying(receipts, 0)

// 	// Check logic
// 	// The first field exports `from` parameter from Transfer Event
// 	// It should use the second topic in Transfer Event log
// 	api.Uint248.AssertIsEqual(receipt.Fields[0].Contract, USDCTokenAddr)
// 	api.Uint248.AssertIsEqual(receipt.Fields[0].IsTopic, sdk.ConstUint248(1))
// 	api.Uint248.AssertIsEqual(receipt.Fields[0].Index, sdk.ConstUint248(1))

// 	// Make sure two fields uses the same log to make sure account address linking with correct volume
// 	api.Uint32.AssertIsEqual(receipt.Fields[0].LogPos, receipt.Fields[1].LogPos)

// 	// The second field exports `Volume` parameter from Transfer Event
// 	// It should use Data in Transfer Event log
// 	api.Uint248.AssertIsEqual(receipt.Fields[1].IsTopic, sdk.ConstUint248(0))
// 	api.Uint248.AssertIsEqual(receipt.Fields[1].Index, sdk.ConstUint248(0))

// 	api.Uint248.AssertIsLessOrEqual(minimumVolume, api.ToUint248(receipt.Fields[1].Value))

//		// Outputs
//		api.OutputUint(64, api.ToUint248(receipt.BlockNum))
//		api.OutputAddress(api.ToUint248(receipt.Fields[0].Value))
//		api.OutputBytes32(receipt.Fields[1].Value)
//		return nil
//	}

// Calculate IV
// IV will be calculated in this circuit, then pushed to the smart contract to update the target IV.
// So, what do we need? IV can be calculated from Uniswap data as such:
// iv = 2 * (feeTier / 10 ** 6) * (dailyVolume / tickTvl) ** 0.5 * Math.sqrt(365)
// The other input besides tickTvl is volume, which can be easily summed up from swap events

// For calculating tickTvl in the circuit, can approximate tickTvl very closely, without calling view functions (which is very difficult in brevis), with:
// ((liquidity + 1) * feeTier * d0) / (1.0001 ** (tick / 2) * 10 ** (decs0 + 6))
// d0 is derivedEth value which for weth=1. decs0=18 for weth
// ((liquidity + 1) * 500 * 1) / (1.0001 ** (tick / 2) * 10 ** (18 + 6))
// (a more robust version of this methodology is [detailed here](https://lambert-guillaume.medium.com/on-chain-volatility-and-uniswap-v3-d031b98143d1) and used in production at panoptic)
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
	currentTick := api.Int248.FromBinary(currentTickBits...)
	currentTickBytes := api.Bytes32.FromBinary(currentTickBits...)
	fmt.Println("current tick, currenttickbytes")
	fmt.Println(currentTick, currentTickBytes)

	slot4 := sdk.GetUnderlying(storageSlots, 1)

	// Calculate iv
	iv := sdk.ConstUint248(69)

	// Outputs
	api.OutputUint(248, iv)

	return nil
}
