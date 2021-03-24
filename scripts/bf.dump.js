const boomflow = require('../build/contracts/Boomflow.json');

const STATUS = [
    "INVALID",                    // Default value
    "INVALID_AMOUNT",             // Order does not have a valid amount
    "INVALID_PRICE",              // Order does not have a valid price
    "FILLABLE",                   // Order is fillable
    "EXPIRED",                    // Order has already expired
    "FULLY_FILLED",               // Order is fully filled
    "CANCELLED",                  // Order is cancelled
    "INVALID_TYPE"
]

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
            console.log("maker:")
            let result = await bf.getOrderInfo(msg.object.makerOrder)
            console.log("Order Status:\t", STATUS[result.orderStatus.toString()]) 
            console.log("Filled Amount:\t", result.filledAmount.toString())

            result = await bf.getOrderData(result.orderHash)
            console.log("Max Amount:\t", result.max.toString())
            console.log("Cancelled:\t", result.cancelled)
            console.log("Instant Ex:\t", result.flag)

            console.log("\ntaker:")
            result = await bf.getOrderInfo(msg.object.takerOrder)
            console.log("Order Status:\t", STATUS[result.orderStatus.toString()]) 
            console.log("Filled Amount:\t", result.filledAmount.toString())

            result = await bf.getOrderData(result.orderHash)
            console.log("Max Amount:\t", result.max.toString())
            console.log("Cancelled:\t", result.cancelled)
            console.log("Instant Ex:\t", result.flag)
            break;
        case "batchExecuteTrade":
            for (let i = 0; i < msg.object.makerOrders.length; i++){
                console.log("==================")
                console.log("maker:")
                let result = await bf.getOrderInfo(msg.object.makerOrders[i])
                console.log("Order Status:\t", STATUS[result.orderStatus.toString()]) 
                console.log("Filled Amount:\t", result.filledAmount.toString())

                result = await bf.getOrderData(result.orderHash)
                console.log("Max Amount:\t", result.max.toString())
                console.log("Cancelled:\t", result.cancelled)
                console.log("Instant Ex:\t", result.flag)

                console.log("\ntaker:")
                result = await bf.getOrderInfo(msg.object.takerOrders[i])
                console.log("Order Status:\t", STATUS[result.orderStatus.toString()]) 
                console.log("Filled Amount:\t", result.filledAmount.toString())

                result = await bf.getOrderData(result.orderHash)
                console.log("Max Amount:\t", result.max.toString())
                console.log("Cancelled:\t", result.cancelled)
                console.log("Instant Ex:\t", result.flag)
            }
            break;
        default: 
            console.log("unrecognized ops:", msg.name)
    }
}

main()