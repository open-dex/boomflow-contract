const { BN, expectRevert, constants } = require('@openzeppelin/test-helpers');
const { ZERO_ADDRESS } = constants;
const INVALID_SIGNATURE = "0x817548bed1e78b347866ab84382c8c9e944d0bc6ab1cdbbae754b68a0f9fd5ed3a54b6945aabc41b37d0b04078c56fd7cc1b5ee17a0fb04a4e5adc1ccf1ec1fe1c"
const POW_10_18 = new BN('10').pow(new BN('18'))
const NEGATIVE = new BN('-1')

const { expect } = require('chai');

const {
    OPCODE,
} = require('boomflow');

const fs = require('fs');
var testcases = JSON.parse(fs.readFileSync(`${__dirname}/boomflow.testcase.json`, 'utf8'));

async function shouldBehaveLikeBoomflowPauseAndResume(boomflow, from) {
    await pause(boomflow, from);
    expect(await boomflow.paused.call()).to.be.true;

    await resume(boomflow, from);
    expect(await boomflow.paused.call()).to.be.false;
}

async function shouldBehaveLikeBoomflowSetTimestamp(boomflow, timestamp, from) {
    await setTimestamp(boomflow, timestamp, from);
    expect(await boomflow.getTimestamp()).to.be.bignumber.equal(new BN(timestamp));
}

async function shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, total, diff, from) {
    let before = await boomflow.getFinishedOrderCount()
    await boomflow.removeObsoleteData(total, {from});
    let after = await boomflow.getFinishedOrderCount()
    expect(before.sub(after)).to.be.bignumber.equal(new BN(diff));
}

async function shouldBehaveLikeBoomflowGetOrder(orderService, boomflow, crcl_1, crcl_2, order, expectation) {
    const signedOrder = await createOrder(
        orderService,
        testcases.privateKeys[order.address],
        order,
        crcl_1.address,
        crcl_2.address, 
        OPCODE.PlaceOrder
    )
    
    let orderInfo = await boomflow.getOrderInfo.call(signedOrder[0]);
    expect(orderInfo.orderStatus).to.equal(expectation.status);
}

async function shouldBehaveLikeBoomflowExecuteTrade(orderService, boomflow, crcl_1, crcl_2, makerOrder, takerOrder, admin, expectation) {
    // Get balances of first and second account before the transactions.
    const makerStartingCRCL1 = await crcl_1.balanceOf.call(makerOrder.address) 
    const makerStartingCRCL2 = await crcl_2.balanceOf.call(makerOrder.address)
    const takerStartingCRCL1 = await crcl_1.balanceOf.call(takerOrder.address)
    const takerStartingCRCL2 = await crcl_2.balanceOf.call(takerOrder.address)

    // Get balances of fee accounts before the transactions.
    const makerFeeStartingCRCL1 = await crcl_1.balanceOf.call(makerOrder.feeAddress)
    const makerFeeStartingCRCL2 = await crcl_2.balanceOf.call(makerOrder.feeAddress)
    const takerFeeStartingCRCL1 = await crcl_1.balanceOf.call(takerOrder.feeAddress)
    const takerFeeStartingCRCL2 = await crcl_2.balanceOf.call(takerOrder.feeAddress)
    
    const signedMakerOrder = await createOrder(
        orderService,
        testcases.privateKeys[makerOrder.address],
        makerOrder,
        crcl_1.address,
        crcl_2.address, 
        OPCODE.PlaceOrder
    )
    
    const signedTakerOrder = await createOrder(
        orderService,
        testcases.privateKeys[takerOrder.address],
        takerOrder,
        crcl_1.address,
        crcl_2.address, 
        OPCODE.PlaceOrder
    )

    // Get order hash.
    const makerOrderHash = (await boomflow.getOrderInfo.call(signedMakerOrder[0])).orderHash;
    const takerOrderHash = (await boomflow.getOrderInfo.call(signedTakerOrder[0])).orderHash;

    // Get order info of the maker and taker order before the transactions.
    const makerOrderStartingData = await boomflow.getOrderData.call(makerOrderHash);
    const takerOrderStartingData = await boomflow.getOrderData.call(takerOrderHash);

    // Invalid Signature
    await expectRevert(
        boomflow.executeTrade(signedMakerOrder[0], signedTakerOrder[0], INVALID_SIGNATURE, signedTakerOrder[1], ZERO_ADDRESS, { from: admin }),
        'INVALID_ORDER_SIGNATURE'
    );

    // Execute the trade.
    await boomflow.executeTrade(signedMakerOrder[0], signedTakerOrder[0], signedMakerOrder[1], signedTakerOrder[1], ZERO_ADDRESS, { from: admin });

    // Replay
    if (expectation.isMakerFullyFilled || expectation.isTakerFullyFilled) {
        await expectRevert(
            boomflow.executeTrade(signedMakerOrder[0], signedTakerOrder[0], signedMakerOrder[1], signedTakerOrder[1], ZERO_ADDRESS, { from: admin }),
            'FULLY_FILLED'
        );
    }

    // Get order info of the maker and taker order after the transactions.
    const makerOrderEndingData = await boomflow.getOrderData.call(makerOrderHash);
    const takerOrderEndingData = await boomflow.getOrderData.call(takerOrderHash);

    expect(new BN(makerOrderEndingData.filled).sub(new BN(makerOrderStartingData.filled))).to.be.bignumber.equal(new BN(expectation.amountFilled));
    expect(new BN(takerOrderEndingData.filled).sub(new BN(takerOrderStartingData.filled))).to.be.bignumber.equal(new BN(expectation.amountFilled).mul(new BN(makerOrder.price)));
    // Get balances of first and second account after the transactions.
    const makerEndingCRCL1 = await crcl_1.balanceOf.call(makerOrder.address)
    const makerEndingCRCL2 = await crcl_2.balanceOf.call(makerOrder.address)
    const takerEndingCRCL1 = await crcl_1.balanceOf.call(takerOrder.address)
    const takerEndingCRCL2 = await crcl_2.balanceOf.call(takerOrder.address)

    // Get balances of fee accounts
    const makerFeeEndingCRCL1 = await crcl_1.balanceOf.call(makerOrder.feeAddress)
    const makerFeeEndingCRCL2 = await crcl_2.balanceOf.call(makerOrder.feeAddress)
    const takerFeeEndingCRCL1 = await crcl_1.balanceOf.call(takerOrder.feeAddress)
    const takerFeeEndingCRCL2 = await crcl_2.balanceOf.call(takerOrder.feeAddress)

    if (takerOrder.side === "Buy") {
        // Check account balances
        //console.log(makerEndingCRCL1.toString(), makerStartingCRCL1.toString())
        expect(takerEndingCRCL1.sub(takerStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.takerFilled));
        expect(makerEndingCRCL1.sub(makerStartingCRCL1)).to.be.bignumber.equal((new BN(expectation.takerFilled).add(new BN(expectation.takerFee))).mul(NEGATIVE));

        expect(makerEndingCRCL2.sub(makerStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.makerFilled));
        expect(takerEndingCRCL2.sub(takerStartingCRCL2)).to.be.bignumber.equal((new BN(expectation.makerFilled).add(new BN(expectation.makerFee))).mul(NEGATIVE));

        // Check fee account balances
        expect(takerFeeEndingCRCL1.sub(takerFeeStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.takerFee));
        expect(makerFeeEndingCRCL2.sub(makerFeeStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.makerFee));
    } else {
        // Check account balances
        expect(makerEndingCRCL1.sub(makerStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.makerFilled));
        expect(takerEndingCRCL1.sub(takerStartingCRCL1)).to.be.bignumber.equal((new BN(expectation.makerFilled).add(new BN(expectation.makerFee))).mul(NEGATIVE));

        expect(takerEndingCRCL2.sub(takerStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.takerFilled));
        expect(makerEndingCRCL2.sub(makerStartingCRCL2)).to.be.bignumber.equal((new BN(expectation.takerFilled).add(new BN(expectation.takerFee))).mul(NEGATIVE));

        // Check fee account balances
        expect(takerFeeEndingCRCL2.sub(takerFeeStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.takerFee));
        expect(makerFeeEndingCRCL1.sub(makerFeeStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.makerFee));
    }
    
    let orderMakerInfo = await boomflow.getOrderInfo.call(signedMakerOrder[0]);
    let orderTakerInfo = await boomflow.getOrderInfo.call(signedTakerOrder[0]);

    expect(orderMakerInfo.orderStatus).to.equal(expectation.isMakerFullyFilled ? "5" : "3");
    expect(orderTakerInfo.orderStatus).to.equal(expectation.isTakerFullyFilled ? "5" : "3");
}

async function shouldBehaveLikeBoomflowInstantExchange(orderService, boomflow, crcl_1, crcl_2, crcl_3, baseMakerOrders, quoteMakerOrders, takerOrder, threshold, admin, expectation) {
    var baseMakerStartingCRCL1 = {}, quoteMakerStartingCRCL1 = {}
    var baseMakerStartingCRCL2 = {}, quoteMakerStartingCRCL2 = {}
    var baseMakerStartingCRCL3 = {}, quoteMakerStartingCRCL3 = {}
    var baseMakerOrderStartingData = [], quoteMakerOrderStartingData = [], baseMakerOrderEndingData = [], quoteMakerOrderEndingData = []
    var baseMakerBoomflowOrders = [], quoteMakerBoomflowOrders = [], baseMakerOrderHashes = [], quoteMakerOrderHashes = [], baseMakerOrderSignatures = [], quoteMakerOrderSignatures = []

    // Get balances of base maker accounts before the transactions.
    for (let i = 0; i < baseMakerOrders.length; i++) {
        baseMakerStartingCRCL1[baseMakerOrders[i].address] = await crcl_1.balanceOf.call(baseMakerOrders[i].address) 
        baseMakerStartingCRCL2[baseMakerOrders[i].address] = await crcl_2.balanceOf.call(baseMakerOrders[i].address) 
        baseMakerStartingCRCL3[baseMakerOrders[i].address] = await crcl_3.balanceOf.call(baseMakerOrders[i].address) 
    };

    // Get balances of quote maker accounts before the transactions.
    for (let i = 0; i < quoteMakerOrders.length; i++) {
        quoteMakerStartingCRCL1[quoteMakerOrders[i].address] = await crcl_1.balanceOf.call(quoteMakerOrders[i].address) 
        quoteMakerStartingCRCL2[quoteMakerOrders[i].address] = await crcl_2.balanceOf.call(quoteMakerOrders[i].address) 
        quoteMakerStartingCRCL3[quoteMakerOrders[i].address] = await crcl_3.balanceOf.call(quoteMakerOrders[i].address) 
    };
    
    const takerStartingCRCL1 = await crcl_1.balanceOf.call(takerOrder.address)
    const takerStartingCRCL2 = await crcl_2.balanceOf.call(takerOrder.address)
    const takerStartingCRCL3 = await crcl_3.balanceOf.call(takerOrder.address)

    // Get balances of base maker accounts before the transactions.
    for (let i = 0; i < baseMakerOrders.length; i++) {
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[baseMakerOrders[i].address],
            baseMakerOrders[i],
            crcl_1.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        baseMakerBoomflowOrders.push(signedMakerOrder[0])
        baseMakerOrderSignatures.push(signedMakerOrder[1])

        let makerOrderHash = (await boomflow.getOrderInfo.call(signedMakerOrder[0])).orderHash;
        baseMakerOrderHashes.push(makerOrderHash)
        baseMakerOrderStartingData.push(await boomflow.getOrderData.call(makerOrderHash));
    };

    // Get balances of quote maker accounts before the transactions.
    for (let i = 0; i < quoteMakerOrders.length; i++) {
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[quoteMakerOrders[i].address],
            quoteMakerOrders[i],
            crcl_3.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        quoteMakerBoomflowOrders.push(signedMakerOrder[0])
        quoteMakerOrderSignatures.push(signedMakerOrder[1])

        let makerOrderHash = (await boomflow.getOrderInfo.call(signedMakerOrder[0])).orderHash;
        quoteMakerOrderHashes.push(makerOrderHash)
        quoteMakerOrderStartingData.push(await boomflow.getOrderData.call(makerOrderHash));
    };

    const signedTakerOrder = await createOrder(
        orderService,
        testcases.privateKeys[takerOrder.address],
        takerOrder,
        crcl_1.address,
        crcl_3.address, 
        OPCODE.PlaceOrder
    )

    // Get taker order hash.
    const takerOrderHash = (await boomflow.getOrderInfo.call(signedTakerOrder[0])).orderHash;

    // Get taker order info of the maker and taker order before the transactions.
    const takerOrderStartingData = await boomflow.getOrderData.call(takerOrderHash);

    // Invalid Signature
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders.concat(quoteMakerBoomflowOrders), INVALID_SIGNATURE, baseMakerOrderSignatures.concat(quoteMakerOrderSignatures), { from: admin }),
        'INVALID_ORDER_SIGNATURE'
    );

    // Record the trade.
    if (expectation.batchRecord) {
        await boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders, signedTakerOrder[1], baseMakerOrderSignatures, { from: admin });
        await boomflow.recordInstantExchangeOrders(signedTakerOrder[0], quoteMakerBoomflowOrders, signedTakerOrder[1], quoteMakerOrderSignatures, { from: admin });
    } else {
        await boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders.concat(quoteMakerBoomflowOrders), signedTakerOrder[1], baseMakerOrderSignatures.concat(quoteMakerOrderSignatures), { from: admin });
    }

    // Execute the trade.
    await boomflow.executeInstantExchangeTrade(signedTakerOrder[0], signedTakerOrder[1], threshold, { from: admin });

    // Replay recordInstantExchangeOrders
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders.concat(quoteMakerBoomflowOrders), signedTakerOrder[1], baseMakerOrderSignatures.concat(quoteMakerOrderSignatures), { from: admin }),
        'FULLY_FILLED'
    );

    // Replay executeInstantExchangeTrade
    await expectRevert(
        boomflow.executeInstantExchangeTrade(signedTakerOrder[0], signedTakerOrder[1], threshold, { from: admin }),
        'FULLY_FILLED'
    );

    // Get balances of base maker accounts before the transactions.
    for (let i = 0; i < baseMakerOrderHashes.length; i++) {
        baseMakerOrderEndingData.push(await boomflow.getOrderData.call(baseMakerOrderHashes[i]));
    };

    // Get balances of quote maker accounts before the transactions.
    for (let i = 0; i < quoteMakerOrderHashes.length; i++) {
        quoteMakerOrderEndingData.push(await boomflow.getOrderData.call(quoteMakerOrderHashes[i]));
    };

    // Get order info of the taker order after the transactions.
    const takerOrderEndingData = await boomflow.getOrderData.call(takerOrderHash);

    expect(new BN(takerOrderEndingData.filled).sub(new BN(takerOrderStartingData.filled))).to.be.bignumber.equal(new BN(expectation.amountFilled).mul(POW_10_18));

    // Get balances of taker account after the transactions.
    const takerEndingCRCL1 = await crcl_1.balanceOf.call(takerOrder.address)
    const takerEndingCRCL2 = await crcl_2.balanceOf.call(takerOrder.address)
    const takerEndingCRCL3 = await crcl_3.balanceOf.call(takerOrder.address)

    if (takerOrder.side === "Buy") {
        // Check account balances
        expect(takerEndingCRCL1.sub(takerStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.takerFilled).mul(POW_10_18));

        expect(takerEndingCRCL3.sub(takerStartingCRCL3)).to.be.bignumber.equal(new BN(sum(expectation.quoteMakerFilled) + sum(expectation.quoteMakerFees)).mul(POW_10_18).mul(NEGATIVE));

        // Check fee account balances
        //expect(takerFeeEndingCRCL1.sub(takerFeeStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.takerFee).mul(POW_10_18));
        //expect(makerFeeEndingCRCL2.sub(makerFeeStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.makerFee).mul(POW_10_18));
    } else {
        // Check account balances
        //expect(makerEndingCRCL1.sub(makerStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.makerFilled).mul(POW_10_18));
        expect(takerEndingCRCL1.sub(takerStartingCRCL1)).to.be.bignumber.equal(new BN(sum(expectation.quoteMakerFilled) + sum(expectation.quoteMakerFees)).mul(POW_10_18).mul(NEGATIVE));

        //expect(makerEndingCRCL2.sub(makerStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.takerFilled + expectation.takerFee).mul(POW_10_18).mul(NEGATIVE));
        expect(takerEndingCRCL3.sub(takerStartingCRCL3)).to.be.bignumber.equal(new BN(expectation.takerFilled).mul(POW_10_18));

        // Check fee account balances
        //expect(takerFeeEndingCRCL2.sub(takerFeeStartingCRCL2)).to.be.bignumber.equal(new BN(expectation.takerFee).mul(POW_10_18));
        //expect(makerFeeEndingCRCL1.sub(makerFeeStartingCRCL1)).to.be.bignumber.equal(new BN(expectation.makerFee).mul(POW_10_18));
    }
}

async function shouldBehaveLikeBoomflowInvalidInstantExchange(orderService, boomflow, crcl_1, crcl_2, crcl_3, baseMakerOrders, quoteMakerOrders, takerOrder, admin) {
    var baseMakerBoomflowOrders = [], quoteMakerBoomflowOrders = [], baseMakerOrderSignatures = [], quoteMakerOrderSignatures = []

    // Get balances of base maker accounts before the transactions.
    for (let i = 0; i < baseMakerOrders.length; i++) {
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[baseMakerOrders[i].address],
            baseMakerOrders[i],
            crcl_1.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        baseMakerBoomflowOrders.push(signedMakerOrder[0])
        baseMakerOrderSignatures.push(signedMakerOrder[1])
    };

    // Get balances of quote maker accounts before the transactions.
    for (let i = 0; i < quoteMakerOrders.length; i++) {
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[quoteMakerOrders[i].address],
            quoteMakerOrders[i],
            crcl_3.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        quoteMakerBoomflowOrders.push(signedMakerOrder[0])
        quoteMakerOrderSignatures.push(signedMakerOrder[1])
    };

    // Taker type has to be Market order
    takerOrder.type = "Limit"
    let signedTakerOrder = await createOrder(
        orderService,
        testcases.privateKeys[takerOrder.address],
        takerOrder,
        crcl_1.address,
        crcl_3.address, 
        OPCODE.PlaceOrder
    )
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders, signedTakerOrder[1], baseMakerOrderSignatures, { from: admin }),
        'INVALID_TAKER_TYPE'
    );

    // Length of makerOrder has to match signatures
    takerOrder.type = "Market"
    signedTakerOrder = await createOrder(
        orderService,
        testcases.privateKeys[takerOrder.address],
        takerOrder,
        crcl_1.address,
        crcl_3.address, 
        OPCODE.PlaceOrder
    )
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders, signedTakerOrder[1], [], { from: admin }),
        'SIGNATURE_LENGTH_MISMATCH'
    );
    
    // Maker type has to be Limit order
    let baseOrders = [], baseSig = []
    for (let i = 0; i < baseMakerOrders.length; i++) {
        baseMakerOrders[i].type = "Market"
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[baseMakerOrders[i].address],
            baseMakerOrders[i],
            crcl_1.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        baseOrders.push(signedMakerOrder[0])
        baseSig.push(signedMakerOrder[1])
    };
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseOrders, signedTakerOrder[1], baseSig, { from: admin }),
        'INVALID_MAKER_TYPE'
    );

    // Make sure all the maker orders share the same quote asset
    boomflow.recordInstantExchangeOrders(signedTakerOrder[0], baseMakerBoomflowOrders, signedTakerOrder[1], baseMakerOrderSignatures, { from: admin });

    let quoteOrders = [], qutoeSig = []
    for (let i = 0; i < quoteMakerOrders.length; i++) {
        const signedMakerOrder = await createOrder(
            orderService,
            testcases.privateKeys[quoteMakerOrders[i].address],
            quoteMakerOrders[i],
            crcl_3.address,
            crcl_1.address, 
            OPCODE.PlaceOrder
        )
        quoteOrders.push(signedMakerOrder[0])
        qutoeSig.push(signedMakerOrder[1])
    };
    await expectRevert(
        boomflow.recordInstantExchangeOrders(signedTakerOrder[0], quoteOrders, signedTakerOrder[1], qutoeSig, { from: admin }),
        'INVALID_QUOTE_ASSET'
    );
};

async function shouldBehaveLikeBoomflowCancelOrders(orderService, boomflow, crcl_1, crcl_2, orders, admin) {
    var boomflowOrders = [], orderInfos = []
    var cancelRequests = [], cancelSignatures = []

    // Get info of orders and requests before the transactions.
    for (let i = 0; i < orders.length; i++) {
        let order = orders[i]

        // Collect order info
        const signedOrder = await createOrder(
            orderService,
            testcases.privateKeys[order.address],
            order,
            crcl_1.address,
            crcl_2.address, 
            OPCODE.PlaceOrder
        )
        boomflowOrders.push(signedOrder[0])

        let orderInfo = await boomflow.getOrderInfo.call(signedOrder[0]);
        orderInfos.push(orderInfo)

        // Collect request info
        order.timestamp = signedOrder[0].salt
        const signedRequest = await createOrder(
            orderService,
            testcases.privateKeys[order.address],
            order,
            crcl_1.address,
            crcl_2.address, 
            OPCODE.Cancel
        )
        cancelRequests.push(signedRequest[0])
        cancelSignatures.push(signedRequest[1])
    };

    // Invalid Signature
    let temp = cancelSignatures[0]
    cancelSignatures[0] = INVALID_SIGNATURE
    await expectRevert(
        boomflow.cancelOrders(cancelRequests, cancelSignatures, { from: admin }),
        'INVALID_CANCEL_SIGNATURE'
    );
    cancelSignatures[0] = temp

    // Cancel the orders.
    await boomflow.cancelOrders(cancelRequests, cancelSignatures, { from: admin });

    // Get info of orders after the transactions.
    for (let i = 0; i < orderInfos.length; i++) {
        expect((await boomflow.getOrderData.call(orderInfos[i].orderHash)).cancelled).to.be.true;
        expect((await boomflow.getOrderInfo.call(boomflowOrders[i])).orderStatus).to.equal("6");
    };
}

async function shouldBehaveLikeBoomflowFinalizeOrder(orderService, boomflow, crcl_1, crcl_2, order, admin) {
    // Get info of orders and requests before the transactions.
    // Collect order info
    const signedOrder = await createOrder(
        orderService,
        testcases.privateKeys[order.address],
        order,
        crcl_1.address,
        crcl_2.address, 
        OPCODE.PlaceOrder
    )

    const orderInfo = await boomflow.getOrderInfo.call(signedOrder[0]);

    // Invalid Signature
    await expectRevert(
        boomflow.finalizeOrder(signedOrder[0], INVALID_SIGNATURE, { from: admin }),
        'INVALID_ORDER_SIGNATURE'
    );

    // Finalize the orders.
    await boomflow.finalizeOrder(signedOrder[0], signedOrder[1], { from: admin });

    // Check order status after the transactions.
    expect((await boomflow.getOrderData.call(orderInfo.orderHash)).cancelled).to.be.true;
}

async function createOrder(orderService, seed, order, baseAssetAddress, quoteAssetAddress, op) {
    await orderService.signin(seed);
  
    let timestamp = orderService.getSystemTime();
    let typedData = await orderService.construct(order, baseAssetAddress, quoteAssetAddress, timestamp, op);
  
    let signature = await orderService.sign(typedData, op);

    return [typedData.message, signature]
}

function pause(boomflow, from) {
    return boomflow.Pause({ from });
}

function resume(boomflow, from) {
    return boomflow.Resume({ from });
}

function setTimestamp(boomflow, timestamp, from) {
    return boomflow.setTimestamp(timestamp, { from });
}

function sum(obj) {
    return Object.keys(obj).reduce((sum,key) => sum + parseFloat(obj[key] || 0), 0);
}
  
module.exports = {
    shouldBehaveLikeBoomflowPauseAndResume,
    shouldBehaveLikeBoomflowSetTimestamp,
    shouldBehaveLikeBoomflowRemoveObsoleteData,
    shouldBehaveLikeBoomflowGetOrder,
    shouldBehaveLikeBoomflowExecuteTrade,
    shouldBehaveLikeBoomflowInstantExchange,
    shouldBehaveLikeBoomflowInvalidInstantExchange,
    shouldBehaveLikeBoomflowCancelOrders,
    shouldBehaveLikeBoomflowFinalizeOrder
};

