const {
    isValidSignature,
} = require('boomflow');

const boomflow = require('../build/contracts/Boomflow.json');
const { Conflux } = require("js-conflux-sdk");
const cfx = new Conflux({
  url: "http://wallet-mainnet-jsonrpc.conflux-chain.org:12537"
});

async function main() {
    const tx = await cfx.getTransactionByHash(process.argv[2])
    const bf = cfx.Contract({
        address: tx.to,
        abi: boomflow.abi
    });

    const msg = await bf.abi.decodeData(tx.data)

    switch(msg.name) {
        case "executeTrade":
            let result = await bf.getOrderInfo(msg.object.makerOrder)
            let signature_byte = Buffer.from(msg.object.makerSignature, "hex");
            if (!(await isValidSignature(bf, result.orderHash, msg.object.makerOrder[0], signature_byte))) {
                console.log("wrong signature address (maker):", msg.object.makerOrder[0])
            }
    
            result = await bf.getOrderInfo(msg.object.takerOrder)
            signature_byte = Buffer.from(msg.object.takerSignature, "hex");
            if (!(await isValidSignature(bf, result.orderHash, msg.object.takerOrder[0], signature_byte))) {
                console.log("wrong signature address (taker):", msg.object.takerOrder[0])
            }
            break;
        case "batchExecuteTrade":
            for (let i = 0; i < msg.object.makerOrders.length; i++){
                console.log("==================")
                let result = await bf.getOrderInfo(msg.object.makerOrders[i])
                let signature_byte = Buffer.from(msg.object.makerSignatures[i], "hex");
                if (!(await isValidSignature(bf, result.orderHash, msg.object.makerOrders[i][0], signature_byte))) {
                    console.log("wrong signature address (maker):", msg.object.makerOrders[i][0])
                }
        
                result = await bf.getOrderInfo(msg.object.takerOrders[i])
                signature_byte = Buffer.from(msg.object.takerSignatures[i], "hex");
                if (!(await isValidSignature(bf, result.orderHash, msg.object.takerOrders[i][0], signature_byte))) {
                    console.log("wrong signature address (taker):", msg.object.takerOrders[i][0])
                }
            }
            break;
        default: 
            console.log("unrecognized ops:", msg.name)
    }
}

main()