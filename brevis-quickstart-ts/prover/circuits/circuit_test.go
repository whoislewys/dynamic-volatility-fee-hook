package circuits

import (
	"fmt"
	"math/big"
	"os"
	"testing"

	"github.com/brevis-network/brevis-sdk/sdk"
	"github.com/brevis-network/brevis-sdk/test"
	"github.com/ethereum/go-ethereum/common"
)

// run tiwth
// ALCHEMY_API_KEY=<key> go test -run TestCircuit
func TestCircuit(t *testing.T) {
	// rpc := "RPC_URL"
	// rpc := "https://mainnet.drpc.org"
	localDir := "$HOME/circuitOut/myBrevisApp"
	var chainId uint64
	chainId = 1
	rpc := fmt.Sprintf("https://eth-mainnet.g.alchemy.com/v2/%s", os.Getenv("ALCHEMY_API_KEY"))
	app, err := sdk.NewBrevisApp(chainId, rpc, localDir)
	check(err)

	// mainnet addr
	var usdcWeth5BpsPool = common.HexToAddress("0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640")

	// two swap logs with only one field: amount1
	// Largest volume log: {
	// 	eventName: 'Swap',
	// 	args: {
	// 	  sender: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
	// 	  recipient: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
	// 	  amount0: -3171955626553n,
	// 	  amount1: 1564800000000000000000n,
	// 	  sqrtPriceX96: 1762715888601403059356729825550383n,
	// 	  liquidity: 17349088537671101965n,
	// 	  tick: 200210
	// 	},
	// 	address: '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
	// 	blockHash: '0x1ce7dc448fa7262e0aed8f9a0e31a0ef8b26bcc38d66673a0b0392418b76d871',
	// 	blockNumber: 22131566n,
	// 	data: '0xfffffffffffffffffffffffffffffffffffffffffffffffffffffd1d78b62dc7000000000000000000000000000000000000000000000054d3f65d559340000000000000000000000000000000000000000056e89a387d81e185fba8b453e02f000000000000000000000000000000000000000000000000f0c4581b08afee0d0000000000000000000000000000000000000000000000000000000000030e12',
	// 	logIndex: 28,
	// 	removed: false,
	// 	topics: [
	// 	  '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67',
	// 	  '0x00000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af',
	// 	  '0x00000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af'
	// 	],
	// 	transactionHash: '0xf9956ea4bcedfe7031cb3b45d4a44fa19eb70ae819ae724e073c44a60aaefc7f',
	// 	transactionIndex: 5
	//   }
	app.AddReceipt(sdk.ReceiptData{
		TxHash: common.HexToHash("0xf9956ea4bcedfe7031cb3b45d4a44fa19eb70ae819ae724e073c44a60aaefc7f"),
		Fields: []sdk.LogFieldData{
			{
				EventID:    common.HexToHash("0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"), // Swap topic0
				LogPos:     3,                                                                                      // NOTE: not log index, log "position" in receipt
				IsTopic:    false,
				FieldIndex: 1, // fieldIndex 1 because amount1 is the second field in RLP encoded log data
				Value:      common.HexToHash("0xfffffffffffffffffffffffffffffffffffffffffffffffffffffd1d78b62dc7000000000000000000000000000000000000000000000054d3f65d559340000000000000000000000000000000000000000056e89a387d81e185fba8b453e02f000000000000000000000000000000000000000000000000f0c4581b08afee0d0000000000000000000000000000000000000000000000000000000000030e12"),
			},
		},
	})

	// Second largest volume log: {
	// 	eventName: 'Swap',
	// 	args: {
	// 	  sender: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
	// 	  recipient: '0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af',
	// 	  amount0: -2980661744350n,
	// 	  amount1: 1469250000000000000000n,
	// 	  sqrtPriceX96: 1761742477292180887569031705248873n,
	// 	  liquidity: 17264120365222369084n,
	// 	  tick: 200199
	// 	},
	// 	address: '0x88e6a0c2ddd26feeb64f039a2c41296fcb3f5640',
	// 	blockHash: '0x6f8ebeddb400d7717b84d8693f1ee99cc3b6870a47a21ea6abe7bd890a25aff3',
	// 	blockNumber: 22131577n,
	// 	data: '0xfffffffffffffffffffffffffffffffffffffffffffffffffffffd4a02b72d2200000000000000000000000000000000000000000000004fa5f0929472ad000000000000000000000000000000000000000056dc50f586f8d95c13083e3dc469000000000000000000000000000000000000000000000000ef967a00c0aa973c0000000000000000000000000000000000000000000000000000000000030e07',
	// 	logIndex: 3,
	// 	removed: false,
	// 	topics: [
	// 	  '0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67',
	// 	  '0x00000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af',
	// 	  '0x00000000000000000000000066a9893cc07d91d95644aedd05d03f95e1dba8af'
	// 	],
	// 	transactionHash: '0x66ad5fe1863f10c0f89cb1e2aa21a4f18eb5c64d7fb3bd3e18aa2d404eb588b5',
	// 	transactionIndex: 0
	//   }
	app.AddReceipt(sdk.ReceiptData{
		TxHash: common.HexToHash("0x66ad5fe1863f10c0f89cb1e2aa21a4f18eb5c64d7fb3bd3e18aa2d404eb588b5"),
		Fields: []sdk.LogFieldData{
			{
				EventID:    common.HexToHash("0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"), // Swap topic0
				LogPos:     3,
				IsTopic:    false,
				FieldIndex: 1, // fieldIndex 1 because amount1 is the second field in RLP encoded log data
				Value:      common.HexToHash("0xfffffffffffffffffffffffffffffffffffffffffffffffffffffd4a02b72d2200000000000000000000000000000000000000000000004fa5f0929472ad000000000000000000000000000000000000000056dc50f586f8d95c13083e3dc469000000000000000000000000000000000000000000000000ef967a00c0aa973c0000000000000000000000000000000000000000000000000000000000030e07"),
			},
		},
	})

	// slot 0
	app.AddStorage(
		sdk.StorageData{
			BlockNum: big.NewInt(22135817),
			Address:  usdcWeth5BpsPool,
			Slot:     common.HexToHash("0x0"),
			Value:    common.HexToHash("0x00010002d302d30140030de900000000000056bac52c49e2000000001151dbd7"), // tick of ~200161
		},
	)

	// slot 4 (contains liquidity)
	app.AddStorage(
		sdk.StorageData{
			BlockNum: big.NewInt(22135817),
			Address:  usdcWeth5BpsPool,
			Slot:     common.HexToHash("0x4"),
			Value:    common.HexToHash("0x000000000000000000000000000000000000000000000000f336f69b81b8268e"), // liquidity of ~17525466147715557006
		},
	)

	appCircuit := &AppCircuit{}
	appCircuitAssignment := &AppCircuit{}

	circuitInput, err := app.BuildCircuitInput(appCircuit)
	check(err)

	///////////////////////////////////////////////////////////////////////////////
	// Testing
	///////////////////////////////////////////////////////////////////////////////

	test.ProverSucceeded(t, appCircuit, appCircuitAssignment, circuitInput)
}

func check(err error) {
	if err != nil {
		panic(err)
	}
}
