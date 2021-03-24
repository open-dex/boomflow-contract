const { BN, expectEvent, expectRevert, singletons } = require('@openzeppelin/test-helpers');

const POW_10_18 = new BN('10').pow(new BN('18'))

const Boomflow = artifacts.require("Boomflow");
const ERC777 = artifacts.require("TokenBase");
const CRCL = artifacts.require("CRCL");

const {
  CRCLDeposit,
  shouldBehaveLikeCRCLDirectDeposit,
  shouldBehaveLikeCRCLPauseAndResume,
  shouldBehaveLikeCRCLForceWithdraw,
  shouldBehaveLikeCRCLTransferFor,
  shouldBehaveLikeCRCLWithdraw,
  shouldBehaveLikeCRCLWithdrawCrossChain,
  shouldBehaveLikeCRCLTransferFrom,
} = require('./CRCL.behavior');

const {
  jsonToTuple,
  OrderService,
  OPCODE,
} = require('boomflow');

const { expect } = require('chai');

var orderService = new OrderService.OrderService({ dexURL: 'https://api.matchflow.io',  eth: true, });

contract('crcl', (users) => {
    var erc777_1, crcl_1
  
    before(async function () {
        await singletons.ERC1820Registry(users[0]);
    
        await orderService.init({
            name: "Boomflow",   // Contract name
            version: "1.0",     // Contract version
            chainId: 1,         // Chain ID
        })
        
        /** Contract Setup */
        erc777_1 = await ERC777.new("erc777_1", "erc777_1", [], {from: users[0]});
        crcl_1 = await CRCL.new("crcl_1", "crcl_1", 18, erc777_1.address, 30, {from: users[0]});
        /** End Contract Setup */
    });

    context('for crcl admin', function () {
        describe('request sanity', function () {
            it(`should pause and resume`, async () => {
                await shouldBehaveLikeCRCLPauseAndResume(crcl_1, users[0]);
            });
        });
    });

    context('deposit', function () {
        describe('direct deposit', function () {
            it(`should mint and send ERC777`, async () => {
                await shouldBehaveLikeCRCLDirectDeposit(erc777_1, crcl_1, users[0], users[1], users[2], '0');
                await shouldBehaveLikeCRCLDirectDeposit(erc777_1, crcl_1, users[0], users[1], users[2], '1000000');
            });
        });
    });

    context('request', function () {
        describe('transfer for', function () {
            it(`should transfer for multiple accounts`, async () => {
                var request = {
                    userAddress: users[2],
                    currency: "EOS",
                    amounts: [1],
                    recipients: users.slice(3, 4),
                }
                await shouldBehaveLikeCRCLTransferFor(orderService, crcl_1, request, users[0])
            });
        });

        describe('withdraw', function () {
            it(`should withdraw from CRCL to ERC777`, async () => {
                var request = {
                    userAddress: users[2],
                    currency: "EOS",
                    amount : 5,
                    recipient: users[5],
                    isCrosschain: false
                }
                await shouldBehaveLikeCRCLWithdraw(orderService, erc777_1, crcl_1, request, users[0])
            });

            it(`should withdraw crosschain`, async () => {
                var request = {
                    userAddress: users[2],
                    currency: "EOS",
                    amount : 5,
                    recipient: users[6],
                    isCrosschain: true
                }
                await shouldBehaveLikeCRCLWithdrawCrossChain(orderService, erc777_1, crcl_1, request, users[0])
            });
        });
    });
    
    context('as boomflow', function () {
        describe('transfer from', function () {
            it(`should transfer from holder to recipient`, async () => {
                await shouldBehaveLikeCRCLTransferFrom(crcl_1, users[2], users[7], 100, users[0])
            });
        });        
    });
    
    describe('force withdraw', function () {
        it(`should burn and withdraw from CRCL`, async () => {
            await shouldBehaveLikeCRCLForceWithdraw(erc777_1, crcl_1, 0, users[0], users[2], users[3]);
        });

        it(`shouldn't burn because not past defer time`, async () => {
            await shouldBehaveLikeCRCLForceWithdraw(erc777_1, crcl_1, 30, users[0], users[2], users[3]);
        });
    });
});