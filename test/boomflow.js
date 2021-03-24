const { BN, expectEvent, expectRevert, singletons } = require('@openzeppelin/test-helpers');

const POW_10_18 = new BN('10').pow(new BN('18'))

const Boomflow = artifacts.require("Boomflow");
const ERC777 = artifacts.require("TokenBase");
const CRCL = artifacts.require("CRCL");

const {
  CRCLDeposit,
} = require('./CRCL.behavior');

const {
  shouldBehaveLikeBoomflowPauseAndResume,
  shouldBehaveLikeBoomflowSetTimestamp,
  shouldBehaveLikeBoomflowRemoveObsoleteData,
  shouldBehaveLikeBoomflowGetOrder,
  shouldBehaveLikeBoomflowExecuteTrade,
  shouldBehaveLikeBoomflowInstantExchange,
  shouldBehaveLikeBoomflowInvalidInstantExchange,
  shouldBehaveLikeBoomflowCancelOrders,
  shouldBehaveLikeBoomflowFinalizeOrder
} = require('./Boomflow.behavior');

const {
  jsonToTuple,
  OrderService,
  OPCODE,
} = require('boomflow');

const { expect } = require('chai');

const fs = require('fs');
var testcases = JSON.parse(fs.readFileSync(`${__dirname}/boomflow.testcase.json`, 'utf8'));

var orderService = new OrderService.OrderService({ dexURL: 'https://api.matchflow.io', eth: true, });

contract('boomflow', (users) => {
  var accounts
  var erc777_1, erc777_2, crcl_1, crcl_2, crcl_3, boomflow
  var baseAssetAddress, quoteAssetAddress

  before(async function () {
    await singletons.ERC1820Registry(users[0]);

    await orderService.init({
      name: "Boomflow",   // Contract name
      version: "1.0",     // Contract version
      chainId: 1,         // Chain ID
    })
    await orderService.signin("27081114c41304108a8204fabda1723f973a0a54385042fc40a415526a62a97a");
    accounts = await orderService.getAccounts()

    /** Contract Setup */
    erc777_1 = await ERC777.new("erc777_1", "erc777_1", [], {from: users[0]});
    erc777_2 = await ERC777.new("erc777_2", "erc777_2", [], {from: users[0]});
    erc777_3 = await ERC777.new("erc777_3", "erc777_3", [], {from: users[0]});

    crcl_1 = await CRCL.new("crcl_1", "crcl_1", 18, erc777_1.address, 30, {from: users[0]});
    crcl_2 = await CRCL.new("crcl_2", "crcl_2", 18, erc777_2.address, 30, {from: users[0]});
    crcl_3 = await CRCL.new("crcl_3", "crcl_3", 18, erc777_3.address, 30, {from: users[0]});

    boomflow = await Boomflow.new({from: users[0]});
  
    await crcl_1.addWhitelisted(boomflow.address, {from: users[0]});
    await crcl_2.addWhitelisted(boomflow.address, {from: users[0]});
    await crcl_3.addWhitelisted(boomflow.address, {from: users[0]});
  
    await boomflow.Resume({from: users[0]});
    /** End Contract Setup */

    orderService.setLocalBoomflow(boomflow.address);

    baseAssetAddress = crcl_1.address;
    quoteAssetAddress = crcl_2.address;
  });
  
  it('should validate PlaceOrder signature', async () => {
    let order = {
      address: accounts[0],
      product: "EOS-CNY",
      amount: 1.67,
      price: 1.234,
      type: "Limit",
      side: "Buy",
      feeAddress: accounts[0],
      feeRateMaker: 0,
      feeRateTaker: 0.0005
    }

    let timestamp = orderService.getSystemTime()
    let typeData = await orderService.construct(order, baseAssetAddress, quoteAssetAddress, timestamp, OPCODE.PlaceOrder)
    let signature = await orderService.sign(typeData, OPCODE.PlaceOrder)
    let bfOrder = await orderService.dex2Chain(order, baseAssetAddress, quoteAssetAddress, timestamp)

    const orderInfo = await boomflow.getOrderInfo.call(bfOrder);
    assert(await boomflow.isValidSignature.call(orderInfo.orderHash, accounts[0], signature));
  });

  it('should validate CancelOrder signature', async () => {
    let order = {
      address: accounts[0],
      product: "EOS-CNY",
      amount: 1.67,
      price: 1.234,
      type: "Limit",
      side: "Buy",
      feeAddress: accounts[0],
      feeRateMaker: 0,
      feeRateTaker: 0.0005
    }
    let timestamp = orderService.getSystemTime()
    order.timestamp = timestamp;
    let timestamp2 = orderService.getSystemTime();

    let typeData = await orderService.construct(order, baseAssetAddress, quoteAssetAddress, timestamp2, OPCODE.Cancel)
    let signature = await orderService.sign(typeData, OPCODE.Cancel)
    let bfOrder = await orderService.dex2Chain(order, baseAssetAddress, quoteAssetAddress, timestamp)
    let request = [jsonToTuple(bfOrder), timestamp2]

    const requestHash = await boomflow.getRequestHash.call(request);
    assert(await boomflow.isValidSignature.call(requestHash, accounts[0], signature));
  });

  context('for boomflow admin', function () {
    describe('operational', function () {
      it(`should pause and resume`, async () => {
        await shouldBehaveLikeBoomflowPauseAndResume(boomflow, users[0]);
      });

      it(`should increment boomflow order version from 0 to 1 with no data deletion`, async () => {
        await shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, 1, 0, users[0]);
        await shouldBehaveLikeBoomflowSetTimestamp(boomflow, 1, users[0]);
        await shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, 10, 0, users[0]);
      });
    });
  });

  context('for trade execution', function () {
    before(async () => {
      for (let i = 1; i < users.length; i++) {
          await CRCLDeposit(erc777_1, crcl_1, users[0], users[i], users[i], new BN('1000000').mul(POW_10_18))  
          await CRCLDeposit(erc777_2, crcl_2, users[0], users[i], users[i], new BN('1000000').mul(POW_10_18))        
          await CRCLDeposit(erc777_3, crcl_3, users[0], users[i], users[i], new BN('1000000').mul(POW_10_18))
      }
    })

    describe('order sanity', function () {
      testcases.orderSanity.forEach(function(test) {
        it(`${test.id} should have status ${test.description}`, async () => {
          await shouldBehaveLikeBoomflowGetOrder(
            orderService, 
            boomflow, crcl_1, crcl_2, 
            test.order,
            test.expectation);
        });
      });
    });

    describe('execute trade', function () {
      testcases.executeTrade.forEach(function(test) {
        it(`${test.id} should ${test.description}`, async () => {
          await shouldBehaveLikeBoomflowExecuteTrade(
            orderService, 
            boomflow, crcl_1, crcl_2, 
            test.makerOrder, test.takerOrder, users[0], 
            test.expectation
          )
        });
      });
    });

    describe('instant exchange', function () {
      testcases.instantExchange.forEach(function(test) {
        it(`${test.id} should batch record and ${test.description}`, async () => {
          await shouldBehaveLikeBoomflowInstantExchange(
            orderService, 
            boomflow, crcl_1, crcl_2, crcl_3, 
            test.baseMakerOrders, test.quoteMakerOrders, test.takerOrder, test.threshold, users[0], 
            test.expectation
          )
        });
      });

      testcases.instantExchange.slice(0, 2).forEach(function(test) {
        it(`${test.id} should record and ${test.description}`, async () => {
          let expectation = test.expectation
          expectation.batchRecord = true
          await shouldBehaveLikeBoomflowInstantExchange(
            orderService, 
            boomflow, crcl_1, crcl_2, crcl_3, 
            test.baseMakerOrders, test.quoteMakerOrders, test.takerOrder, test.threshold, users[0], 
            expectation
          )
        });
      });

      it(`should revert`, async () => {
        let test = testcases.instantExchange[0]
        await shouldBehaveLikeBoomflowInvalidInstantExchange(
          orderService, 
          boomflow, crcl_1, crcl_2, crcl_3, 
          test.baseMakerOrders, test.quoteMakerOrders, test.takerOrder, users[0]
        )
      });
    });

    describe('cancel orders', function () {
      testcases.executeTrade.forEach(function(test) {
        it(`${test.id} should cancel new orders`, async () => {
          await shouldBehaveLikeBoomflowCancelOrders(
            orderService, 
            boomflow, crcl_1, crcl_2, 
            [test.makerOrder, test.takerOrder], users[0]
          )
        });
      });
    });

    describe('finalize orders', function () {
      testcases.executeTrade.forEach(function(test) {
        it(`${test.id} should finalize new orders`, async () => {
          await shouldBehaveLikeBoomflowFinalizeOrder(
            orderService, 
            boomflow, crcl_1, crcl_2, 
            test.makerOrder, users[0]
          )
          await shouldBehaveLikeBoomflowFinalizeOrder(
            orderService, 
            boomflow, crcl_1, crcl_2, 
            test.takerOrder, users[0]
          )
        });
      });
    });

    describe('remove obsolete orders', function () {
      it(`should remove no order`, async () => {
        await shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, 1, 0, users[0]);
      });

      it(`should remove one order`, async () => {
        await shouldBehaveLikeBoomflowSetTimestamp(boomflow, new Date().getTime(), users[0]);
        await shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, 1, 1, users[0]);
      });

      it(`should remove the rest orders`, async () => {
        await shouldBehaveLikeBoomflowRemoveObsoleteData(boomflow, 100, 31, users[0]);
      });
    });
  });
});