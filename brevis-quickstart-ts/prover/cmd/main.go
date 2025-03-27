package main

import (
	"flag"
	"fmt"
	"os"

	"prover/circuits"

	"github.com/brevis-network/brevis-sdk/sdk/prover"
)

var port = flag.Uint("port", 33247, "the port to start the service at")

func main() {
	flag.Parse()

	alchemyKey := os.Getenv("ALCHEMY_API_KEY")
	if alchemyKey == "" {
		fmt.Println("ALCHEMY_API_KEY environment variable is not set")
		os.Exit(1)
	}
	// fmt.Printf("Using Alchemy API Key: %s\n", alchemyKey[:6]+"..."+alchemyKey[len(alchemyKey)-4:])

	proverService, err := prover.NewService(&circuits.AppCircuit{}, prover.ServiceConfig{
		SetupDir: "$HOME/circuitOut",
		SrsDir:   "$HOME/kzgsrs",
		// RpcURL:   "https://eth.llamarpc.com",
		RpcURL:  fmt.Sprintf("https://eth-mainnet.g.alchemy.com/v2/%s", os.Getenv("ALCHEMY_API_KEY")),
		ChainId: 1,
	})
	if err != nil {
		fmt.Println(err)
		os.Exit(1)
	}
	proverService.Serve("", *port)
}
