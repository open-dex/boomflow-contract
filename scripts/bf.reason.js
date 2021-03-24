//curl -X POST -H "Content-Type: application/json" --data '{"method":"cfx_call","id":1,"jsonrpc":"2.0","params":[{"from":"0x13f1102173449e94e3ce5d9bb5a8a6a251027247","to":"0x89a616d79c6cb7c7dce6fc244ede288b41789398","data":"0xba6ea60a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000000000000000000000000000000000000000000000000000000003000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000020000000000000000000000000000000000000000000000000000000000000003","gasPrice":"0xa", "nonce": "0x12B"}]}' http://mainnet-jsonrpc.conflux-chain.org:12537 | node -e "console.log( JSON.stringify( JSON.parse(require('fs').readFileSync(0) ), 0, 1 ))"
const boomflow = require('../build/contracts/Boomflow.json');
const request = require('request');
const { Conflux } = require("js-conflux-sdk");
const cfx = new Conflux({
    url: "http://mainnet-jsonrpc.conflux-chain.org:12537"
});

function hex_to_ascii(str1) {
	var hex  = str1.toString();
	var str = '';
	for (var n = 0; n < hex.length; n += 2) {
		str += String.fromCharCode(parseInt(hex.substr(n, 2), 16));
	}
	return str;
 }

async function reason(code) {
    let reason = hex_to_ascii(code.substr(138))
    console.log('Reason:\t', reason ? reason : "Possibly Out of Gas")
}

async function main() {
    const tx = await cfx.getTransactionByHash(process.argv[2])
    const bf = cfx.Contract({
        address: tx.to,
        abi: boomflow.abi
    });

    let options = {
        url: "http://mainnet-jsonrpc.conflux-chain.org:12537",
        method: "post",
        headers:
        { 
         "content-type": "application/json"
        },
        body: JSON.stringify({
            "jsonrpc": "2.0",
            "id": 1,
            "method": "cfx_call",
            "params": [{
                "from": tx.from,
                "to": tx.to,
                "data": tx.data,
                "nonce": "0x" + tx.nonce.toString(16),
                "value": "0x" + tx.value.toString(16),
                "gas": "0x" + tx.gas.toString(16)
            }]
        })
    };
    
    request(options, (error, response, body) => {
        if (error) {
            console.error('An error has occurred: ', error);
        } else {
            let res = JSON.parse(body)
            if (res.error) {
                console.log('Code:\t', res.error.code);
                console.log('Msg:\t', res.error.message);

                reason(res.error.data.substring(1, res.error.data.length - 1))
            } else {
                console.log('Transaction succeeded...');
                console.log('Result: ', res.result);
            }
        }
    });
}

main()